import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("limare.worksurface.width") private var workSurfaceWidth: Double = Double(AppLayout.workSurfaceIdealWidth)
    /// The user message whose undo is being previewed.
    @State private var pendingUndo: UndoRequest?
    /// Read so toggling the experimental switch re-evaluates which message offers retraction.

    var body: some View {
        @Bindable var workSurface = appState.workSurface
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
                if appState.workSurface.isPresented {
                    Menu {
                        ForEach(WorkSurfaceRegistry.builtInDefinitions) { def in
                            Button {
                                appState.addSurface(def.kind)
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
                    appState.workSurface.togglePresented()
                } label: {
                    Label("Work Surface", systemImage: "sidebar.right")
                }
                .accessibilityIdentifier("chat.toolbar.workSurface")
                .accessibilityLabel("Work Surface")
                .help(appState.workSurface.isPresented ? "Hide Work Surface" : "Show Work Surface")
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
            if let conversationID = appState.conversations.activeConversationID {
                ChatRunStatusView(conversationID: conversationID)
                NativeDelegationTaskView(conversationID: conversationID)
            }

            if appState.providers.selectedProvider == nil {
                ChatStatusCallout()
            }

            conversationContent

            if let errorMessage = appState.chat.errorMessage {
                ChatErrorBanner(message: errorMessage)
            }

            RecoveryBannerView()

            UndoPlanBanner()

            if let child = appState.conversations.activeConversation, child.isNativeDelegationChild {
                NativeChildInteractionView(conversationID: child.id)
            } else {
                ComposerView()
            }
        }
    }

    private var activeTitle: String {
        if let conversation = appState.conversations.activeConversation {
            if let project = appState.conversations.project(for: conversation) {
                return "\(project.name) / \(conversation.title)"
            }
            return conversation.title
        }
        return "Conversation"
    }

    @ViewBuilder
    private var conversationContent: some View {
        if appState.chat.messages.isEmpty {
            EmptyConversationView()
        } else {
            let conversationID = appState.conversations.activeConversationID
            MessageListView(
                messages: appState.chat.messages,
                retractableMessageID: appState.chat.retractableUserMessageID,
                onRetract: { pendingUndo = UndoRequest(messageID: $0) },
                compactionMarkers: appState.conversations.activeConversation?.compactionMarkers ?? [],
                compaction: conversationID.flatMap { appState.conversationRuns.compactions[$0] }
            )
            .id(appState.conversations.activeConversationID)
        }
    }
}

private struct ChatStatusCallout: View {
    @Environment(AppState.self) private var appState

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
                appState.screen = .settingsProviders
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

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Start a conversation")
            } icon: {
                LimareGlyph(size: 64)
            }
            .font(.title3.weight(.medium))
        } description: {
            if let activeConv = appState.conversations.activeConversation,
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
                appState.chat.errorMessage = nil
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
    @Binding var width: Double
    /// The detail column in window coordinates: right of the sidebar, or the whole window.
    let detailFrame: CGRect

    @State private var isHovering = false
    @State private var isDragging = false
    /// Where the detail column began when the drag started; the sidebar's width while it shows.
    @State private var leadingAtDragStart: CGFloat = 0

    var body: some View {
        let isActive = isHovering || isDragging
        ZStack {
            Rectangle()
                .fill(isActive ? Color.accentColor.opacity(0.7) : .clear)
                .frame(width: 2)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .animation(.easeOut(duration: 0.12), value: isActive)
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
                    if !isDragging {
                        isDragging = true
                        leadingAtDragStart = detailFrame.minX > 1
                            ? detailFrame.minX
                            // The sidebar is hidden; if the panel hid it, it comes back on the way.
                            : (appState.workSurface.coverage == .window ? AppLayout.sidebarIdealWidth : 0)
                    }
                    follow(pointerX: value.location.x)
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovering { NSCursor.pop() }
                }
        )
        .onDisappear {
            if isHovering || isDragging { NSCursor.pop() }
        }
        .accessibilityHidden(true)
    }

    private func follow(pointerX x: CGFloat) {
        let workSurface = appState.workSurface
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
