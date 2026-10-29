import SwiftUI
import AppKit

/// One window. It takes a WindowSession when it appears, tells the app when it becomes key, and
/// gives the session back when it closes.
struct WindowRootView: View {
    @Environment(AppState.self) private var appState
    @State private var session: WindowSession?

    var body: some View {
        if let session {
            RootView()
                .environment(session)
                .background(WindowLifecycleObserver(
                    onAttach: { window in
                        session.hostWindow = window
                        // No rule under the title bar; the toolbar's own scroll edge still
                        // keeps scrolled text off the title.
                        window.titlebarSeparatorStyle = .none
                    },
                    onBecameKey: { appState.windowBecameKey(session) },
                    onClose: { appState.windowClosed(session) }
                ))
        } else {
            Color.clear
                .onAppear { session = appState.openWindowSession() }
        }
    }
}

/// Reports the hosting window, its becoming key and its closing.
private struct WindowLifecycleObserver: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void
    let onBecameKey: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onAttach = onAttach
        view.onBecameKey = onBecameKey
        view.onClose = onClose
    }

    final class ObserverView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        var onBecameKey: (() -> Void)?
        var onClose: (() -> Void)?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.onAttach?(window) }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecameKey?() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            })
            if window.isKeyWindow {
                DispatchQueue.main.async { [weak self] in self?.onBecameKey?() }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The sidebar's visibility before the Work Surface expanded, restored when it stops.
    @State private var visibilityBeforeExpanding: NavigationSplitViewVisibility?

    var body: some View {
        @Bindable var window = window
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                if window.screen.isSettings {
                    SettingsSidebarView(selection: $window.screen)
                } else {
                    SidebarView()
                }
            }
            .modifier(FloatingSidebarPanel())
            .navigationSplitViewColumnWidth(
                min: AppLayout.sidebarMinimumWidth,
                ideal: AppLayout.sidebarIdealWidth,
                max: AppLayout.sidebarMaximumWidth
            )
            // The one toggle: it stays in the title bar when the sidebar is collapsed, so the
            // detail column adds none of its own (a second one appeared beside it).
            .toolbar { sidebarToggle(placement: .automatic) }
            // The system toggle sits on a round backing; this one is a bare icon like the others.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch window.screen {
                case .chat:
                    ChatView()
                case .scheduled:
                    SchedulesWorkspaceView()
                        .safeAreaInset(edge: .bottom) {
                            ApprovalElsewhereNotice(excluding: nil)
                                .padding(AppSpacing.small)
                        }
                default:
                    SettingsDetailView(screen: window.screen)
                        .safeAreaInset(edge: .bottom) {
                            ApprovalElsewhereNotice(excluding: nil)
                                .padding(AppSpacing.small)
                        }
                }
            }
        }
        .overlay {
            if window.screen == .scheduled, let mode = window.scheduledPanel.editing {
                ScheduledEditorModal(mode: mode)
                    .id(mode.id)
                    .transition(.opacity)
            }
        }
        .animation(AppMotion.resolved(AppMotion.standard), value: window.scheduledPanel.editing?.id)
        .sheet(item: activeSheet) { item in
            switch item {
            case .permission(let approval):
                PermissionApprovalView(approval: approval)
            case .mcpCredential(let credRequest):
                MCPCredentialPromptView(request: credRequest)
            }
        }
        .sheet(isPresented: Binding(get: { window.worktreeDetails != nil },
                                    set: { if !$0 { window.worktreeDetails = nil } })) {
            if let id = window.worktreeDetails { WorktreeDetailsView(conversationID: id) }
        }
        .confirmationDialog(worktreeRemovalTitle, isPresented: Binding(get: { window.worktreeRemovalPrompt != nil },
                                                                       set: { if !$0 { window.worktreeRemovalPrompt = nil } }),
                            titleVisibility: .visible, presenting: window.worktreeRemovalPrompt) { prompt in
            Button(prompt.conversationIDs.count == 1 ? "Delete Worktree" : "Delete Worktrees", role: .destructive) {
                Task { await appState.finishWorktreeRemoval(prompt, keepingFolders: false) }
            }
            Button(prompt.conversationIDs.count == 1 ? "Keep Worktree Folder" : "Keep Worktree Folders") {
                Task { await appState.finishWorktreeRemoval(prompt, keepingFolders: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            if prompt.conversationIDs.count == 1 {
                Text("The worktree holds uncommitted changes or new files that exist nowhere else. A kept folder and its branch stay on disk.")
            } else {
                Text("Of \(prompt.conversationIDs.count) worktrees, \(prompt.unsavedCount) hold uncommitted changes or new files that exist nowhere else. Kept folders and their branches stay on disk.")
            }
        }
        .environment(\.font, AppTypography.interface)
        .onChange(of: workSurfaceFillsWindow) { _, fills in
            if fills {
                visibilityBeforeExpanding = columnVisibility
                withAnimation(AppMotion.resolved(AppMotion.panel)) { columnVisibility = .detailOnly }
            } else if let previous = visibilityBeforeExpanding {
                visibilityBeforeExpanding = nil
                withAnimation(AppMotion.resolved(AppMotion.panel)) { columnVisibility = previous }
            }
        }
    }

    @ToolbarContentBuilder
    private func sidebarToggle(placement: ToolbarItemPlacement) -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: placement) { sidebarToggleButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { sidebarToggleButton }
        }
    }

    private var sidebarToggleButton: some View {
        let isHidden = columnVisibility == .detailOnly
        return Button {
            withAnimation(AppMotion.resolved(AppMotion.panel)) {
                columnVisibility = isHidden ? .all : .detailOnly
            }
        } label: {
            Label(isHidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(GhostIconButtonStyle(size: AppControlHeight.composerButton, iconSize: 15))
        .help(isHidden ? "Show Sidebar" : "Hide Sidebar")
    }

    private var workSurfaceFillsWindow: Bool {
        window.screen == .chat && window.workSurface.isPresented && window.workSurface.coverage == .window
    }

    private enum ActiveSheet: Identifiable {
        case permission(PendingApproval)
        case mcpCredential(MCPCredentialRequest)

        var id: String {
            switch self {
            case .permission(let p): return "perm-\(p.id)"
            case .mcpCredential(let c): return "mcp-cred-\(c.id)"
            }
        }
    }

    private var worktreeRemovalTitle: String {
        window.worktreeRemovalPrompt?.deletesConversations == true
            ? String(localized: "Delete the conversation and its worktree?")
            : String(localized: "Remove the worktree?")
    }

    /// A request that belongs to no conversation, when this window is the one to present it: a
    /// request reaches every window, but only one shows it (`AppState.sheetWindowID`). Approvals
    /// a conversation waits on are shown in that conversation (`ConversationApprovalArea`).
    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                let sheet: ActiveSheet
                if let permission = appState.permissions.pendingApproval, permission.conversationID == nil {
                    sheet = .permission(permission)
                } else if let cred = appState.mcp.pendingCredentialRequest {
                    sheet = .mcpCredential(cred)
                } else {
                    return nil
                }
                return appState.sheetWindowID(for: sheet.id, conversationID: nil) == window.id ? sheet : nil
            },
            set: { newValue in
                if newValue == nil {
                    if let perm = appState.permissions.pendingApproval, perm.conversationID == nil {
                        appState.permissions.resolvePendingApproval(id: perm.id, approved: false)
                    }
                    if let cred = appState.mcp.pendingCredentialRequest {
                        appState.mcp.resolveCredentialRequest(id: cred.id, credential: nil)
                    }
                }
            }
        )
    }
}

private struct PermissionApprovalView: View {
    @Environment(AppState.self) private var appState
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: approval.isHighRisk ? "exclamationmark.triangle.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(approval.isHighRisk ? AppColors.statusError : AppColors.statusWarning)
                Text("Approval Required")
                    .font(.title2.weight(.semibold))
            }

            Text(approval.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    HStack {
                        Text("Tool:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(approval.toolName)
                            .font(.caption.monospaced())
                    }

                    if let title = approval.conversationTitle, !title.isEmpty {
                        HStack(alignment: .top) {
                            Text("Conversation:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(title)
                                .font(.caption)
                        }
                    }

                    if !approval.affectedPaths.isEmpty {
                        HStack(alignment: .top) {
                            Text("Paths:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(approval.affectedPaths.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if let command = approval.command, !command.isEmpty {
                        HStack(alignment: .top) {
                            Text("Command:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if approval.requestsNetwork {
                        HStack {
                            Text("Network:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Label("May access external network", systemImage: "network")
                                .font(.caption)
                                .foregroundStyle(AppColors.statusWarning)
                        }
                    }

                    if !approval.environmentKeys.isEmpty {
                        HStack(alignment: .top) {
                            Text("Env Keys:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text("\(approval.environmentKeys.joined(separator: ", ")) (values hidden)")
                                .font(.caption.monospaced())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.xxSmall)
            } label: {
                Text("Request Details")
                    .font(.caption.weight(.medium))
            }

            HStack {
                Spacer()
                Button("Deny", role: .cancel) {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: false)
                }
                Button("Allow Once") {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(minWidth: AppLayout.approvalMinimumWidth, idealWidth: AppLayout.approvalIdealWidth)
        .interactiveDismissDisabled()
    }
}
