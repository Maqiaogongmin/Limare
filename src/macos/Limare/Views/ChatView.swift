import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.worksurface.width") private var workSurfaceWidth: Double = Double(AppLayout.workSurfaceIdealWidth)
    /// The user message whose undo is being previewed.
    @State private var pendingUndo: UndoRequest?
    /// Read so toggling the experimental switch re-evaluates which message offers retraction.

    var body: some View {
        @Bindable var workSurface = window.workSurface
        GeometryReader { geometry in
            // Covered (by the expand button or by dragging the panel's edge over the chat), or
            // a split cannot fit both panes: the Work Surface takes the whole width. Its own
            // header and the toolbar return to Chat without moving or resizing the window.
            let coversChat = workSurface.isPresented
                && (workSurface.isExpanded
                    || geometry.size.width < AppLayout.chatMinimumWidth + AppLayout.workSurfaceMinimumWidth)
            HStack(spacing: 0) {
                if !coversChat {
                    chatColumn
                        .frame(minWidth: AppLayout.chatMinimumWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // One view in every layout, so a drag on its edge carries on while the chat
                // and the sidebar step aside.
                if workSurface.isPresented {
                    let minWS = Double(AppLayout.workSurfaceMinimumWidth)
                    let maxWS = max(minWS, Double(geometry.size.width) - Double(AppLayout.chatMinimumWidth))
                    let clampedWSWidth = min(maxWS, max(minWS, workSurfaceWidth))

                    WorkSurfaceView()
                        .frame(width: coversChat ? nil : CGFloat(clampedWSWidth))
                        .frame(maxWidth: coversChat ? .infinity : nil, maxHeight: .infinity)
                        .overlay(alignment: .leading) {
                            WorkSurfaceEdgeHandle(
                                width: $workSurfaceWidth,
                                detailFrame: geometry.frame(in: .global)
                            )
                            .offset(x: coversChat ? 0 : -4)
                        }
                }
            }
        }
        // Links clicked in messages open in the Work Surface browser; ⌘-click opens them in the
        // default browser.
        .environment(\.openURL, OpenURLAction { url in
            let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            appState.openMessageLink(url, inDefaultBrowser: commandHeld)
            return .handled
        })
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if window.workSurface.isPresented {
                    Menu {
                        ForEach(WorkSurfaceRegistry.builtInDefinitions) { def in
                            Button {
                                window.addSurface(def.kind)
                            } label: {
                                Label(def.title, systemImage: def.systemImage)
                            }
                        }
                    } label: {
                        Label("Add Surface", systemImage: "plus")
                    }
                    .help("Add Surface (Browser, Files)")
                }

                Button {
                    window.workSurface.togglePresented()
                } label: {
                    Label("Work Surface", systemImage: "sidebar.right")
                }
                .accessibilityIdentifier("chat.toolbar.workSurface")
                .accessibilityLabel("Work Surface")
                .help(window.workSurface.isPresented ? "Hide Work Surface" : "Show Work Surface")
            }
        }
        .navigationTitle(activeTitle)
        .sheet(item: $pendingUndo) { request in
            UndoMessageSheet(messageID: request.messageID)
                .environment(appState)
        }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            if let conversationID = window.conversationID {
                ChatRunStatusView(conversationID: conversationID)
                NativeDelegationTaskView(conversationID: conversationID)
            }

            if appState.providers.selectedProvider == nil {
                ChatStatusCallout()
            }

            conversationContent

            if let errorMessage = window.chat.errorMessage {
                ChatErrorBanner(message: errorMessage)
            }

            RecoveryBannerView()

            UndoPlanBanner()

            ConversationApprovalArea()

            if let child = window.conversation, child.isNativeDelegationChild {
                NativeChildInteractionView(conversationID: child.id)
            } else {
                ComposerView()
            }
        }
    }

    private var activeTitle: String {
        if let conversation = window.conversation {
            if let project = appState.conversations.project(for: conversation) {
                return "\(project.name) / \(conversation.title)"
            }
            return conversation.title
        }
        return "Conversation"
    }

    @ViewBuilder
    private var conversationContent: some View {
        if window.chat.messages.isEmpty {
            EmptyConversationView()
        } else {
            let conversationID = window.conversationID
            MessageListView(
                messages: window.chat.messages,
                retractableMessageID: window.chat.retractableUserMessageID,
                onRetract: { pendingUndo = UndoRequest(messageID: $0) },
                compactionMarkers: window.conversation?.compactionMarkers ?? [],
                compaction: conversationID.flatMap { appState.conversationRuns.compactions[$0] }
            )
            .id(window.conversationID)
        }
    }
}

private struct ChatStatusCallout: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "bolt.badge.clock")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Connect a model to start.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary)

            Spacer()

            Button("Configure Provider") {
                window.screen = .settingsProviders
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.small)
        .background(Color.orange.opacity(0.10))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.orange.opacity(0.20)),
            alignment: .bottom
        )
    }
}

private struct EmptyConversationView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Start a conversation")
            } icon: {
                LimareGlyph(size: 64)
            }
            .font(.title3.weight(.medium))
        } description: {
            if let activeConv = window.conversation,
               let project = appState.conversations.project(for: activeConv) {
                if let folder = activeConv.workspace ?? project.workspace {
                    Text("Harness tools are active in \(folder.name). Every file edit and terminal command stays visible here.")
                        .font(.subheadline)
                } else {
                    Text("Project tools are active. Every file edit and terminal command stays visible here.")
                        .font(.subheadline)
                }
            } else {
                Text("Desktop harness tools are active. Type a message below to begin.")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChatErrorBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppColors.statusError)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .lineLimit(3)

            Spacer()

            Button {
                window.chat.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.xxSmall)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, AppSpacing.chatHorizontal)
        .padding(.vertical, AppSpacing.xSmall)
        .background(AppColors.statusError.opacity(0.08))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AppColors.statusError.opacity(0.2)),
            alignment: .bottom
        )
    }
}

/// The Work Surface's leading edge. Dragging it sets the panel's width; dragged on past half the
/// chat's minimum width, the panel covers the chat, and past the middle of the sidebar, the whole
/// window. Dragging back undoes each step. The panel follows the pointer, so the edge stays under it.
private struct WorkSurfaceEdgeHandle: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @Binding var width: Double
    /// The detail column in window coordinates: right of the sidebar, or the whole window.
    let detailFrame: CGRect

    @State private var isHovering = false
    @State private var isDragging = false
    /// Where the detail column began when the drag started; the sidebar's width while it shows.
    @State private var leadingAtDragStart: CGFloat = 0
    /// What Escape puts back.
    @State private var widthAtDragStart: Double?
    @State private var coverageAtDragStart: WorkSurfaceStore.Coverage?
    /// Escape ended the drag; the rest of the gesture is ignored until the button comes up.
    @State private var didCancelDrag = false
    @State private var escapeMonitor: Any?
    @FocusState private var isFocused: Bool

    private enum KeyboardStep {
        static let regular = 8.0
        static let large = 32.0
        static let accessibility = 16.0
    }

    var body: some View {
        let isActive = isHovering || isDragging || isFocused
        ZStack {
            Rectangle()
                .fill(isActive ? Color.accentColor.opacity(0.7) : .clear)
                .frame(width: 2)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .animation(AppMotion.resolved(AppMotion.quickOut), value: isActive)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    guard !didCancelDrag else { return }
                    if !isDragging {
                        guard abs(value.translation.width) >= AppLayout.workSurfaceDragDeadZone else { return }
                        isDragging = true
                        widthAtDragStart = width
                        coverageAtDragStart = window.workSurface.coverage
                        leadingAtDragStart = detailFrame.minX > 1
                            ? detailFrame.minX
                            // The sidebar is hidden; if the panel hid it, it comes back on the way.
                            : (window.workSurface.coverage == .window ? AppLayout.sidebarIdealWidth : 0)
                        installEscapeMonitor()
                    }
                    follow(pointerX: value.location.x)
                }
                .onEnded { _ in
                    removeEscapeMonitor()
                    didCancelDrag = false
                    guard isDragging else { return }
                    isDragging = false
                    if !isHovering { NSCursor.pop() }
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                width = WorkSurfaceStore.clampedPanelWidth(
                    Double(AppLayout.workSurfaceIdealWidth),
                    windowWidth: Double(detailFrame.maxX),
                    sidebarWidth: Double(currentLeading)
                )
                window.workSurface.coverage = .none
            }
        )
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down) { press in
            let step = press.modifiers.contains(.shift) ? KeyboardStep.large : KeyboardStep.regular
            switch press.key {
            case .leftArrow: adjust(by: step)
            case .rightArrow: adjust(by: -step)
            default: return .ignored
            }
            return .handled
        }
        .onDisappear {
            removeEscapeMonitor()
            if isHovering || isDragging { NSCursor.pop() }
        }
        .accessibilityElement()
        .accessibilityLabel("Work Surface 宽度")
        .accessibilityValue("\(Int(width)) 点")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: KeyboardStep.accessibility)
            case .decrement: adjust(by: -KeyboardStep.accessibility)
            @unknown default: break
            }
        }
    }

    /// The sidebar's width as laid out now (0 while it is hidden).
    private var currentLeading: CGFloat {
        detailFrame.minX > 1 ? detailFrame.minX : 0
    }

    /// Widens the panel by `delta` points (the edge moves left), within the room beside the chat.
    private func adjust(by delta: Double) {
        width = WorkSurfaceStore.clampedPanelWidth(
            width + delta,
            windowWidth: Double(detailFrame.maxX),
            sidebarWidth: Double(currentLeading)
        )
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            if let widthAtDragStart { width = widthAtDragStart }
            if let coverageAtDragStart { window.workSurface.coverage = coverageAtDragStart }
            didCancelDrag = true
            isDragging = false
            if !isHovering { NSCursor.pop() }
            removeEscapeMonitor()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func follow(pointerX x: CGFloat) {
        let workSurface = window.workSurface
        let target = WorkSurfaceStore.edgeDrag(
            pointerX: Double(x),
            sidebarWidth: Double(leadingAtDragStart),
            windowWidth: Double(detailFrame.maxX),
            chatMinimum: Double(AppLayout.chatMinimumWidth),
            panelMinimum: Double(AppLayout.workSurfaceMinimumWidth)
        )
        if let newWidth = target.width { width = newWidth }
        if workSurface.coverage != target.coverage {
            workSurface.coverage = target.coverage
        }
    }
}
