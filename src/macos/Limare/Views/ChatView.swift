import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.worksurface.width") private var workSurfaceWidth: Double = Double(AppLayout.workSurfaceIdealWidth)
    /// The user message whose undo is being previewed.
    @State private var pendingUndo: UndoRequest?
    /// Where the Work Surface sheet sits, for the breadcrumb to stop short of it. An object this
    /// body never reads from, so a sheet that moves re-renders the breadcrumb, not the chat.
    @State private var titleBar = TitleBarLayout()
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

                    // Up into the title bar, level with the sidebar's top, unless it covers a
                    // window whose sidebar is hidden: its tabs would run under the traffic lights.
                    let risesIntoTitleBar = !coversChat || geometry.frame(in: .global).minX > 1

                    WorkSurfaceView()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [titleBar] in
                            titleBar.workSurfaceFrame = $0
                        }
                        .onDisappear { [titleBar] in titleBar.workSurfaceFrame = nil }
                        // A sheet inset on the canvas: clear of the window's edges, and of the
                        // chat's edge when it covers the chat.
                        .padding(.top, risesIntoTitleBar ? AppSpacing.workSurfaceTopInset : AppSpacing.workSurfaceInset)
                        .padding(.bottom, AppSpacing.workSurfaceInset)
                        .padding(.trailing, AppSpacing.workSurfaceInset)
                        .padding(.leading, coversChat ? AppSpacing.workSurfaceInset : 0)
                        .ignoresSafeArea(.container, edges: risesIntoTitleBar ? .top : [])
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
            // One canvas under the chat and around the Work Surface sheet, up under the title bar.
            .background(AppColors.canvas.ignoresSafeArea())
        }
        // Links clicked in messages open in the Work Surface browser; ⌘-click opens them in the
        // default browser.
        .environment(\.openURL, OpenURLAction { url in
            let commandHeld = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
            appState.openMessageLink(url, inDefaultBrowser: commandHeld)
            return .handled
        })
        .toolbar { chatToolbar }
        // No band or rule under the title bar; the canvas and the sidebar run up under it.
        // The transcript is clipped below it instead (`conversationContent`).
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The window's own title stays for the Window menu and accessibility; the title bar
        // shows `breadcrumb` in its place, and nothing for a new conversation, which the
        // sidebar already names.
        .toolbar(removing: .title)
        .navigationTitle(activeTitle)
        .sheet(item: $pendingUndo) { request in
            UndoMessageSheet(messageID: request.messageID)
                .environment(appState)
        }
    }

    /// Toolbar buttons are bare icons, without the system's round backing.
    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { breadcrumb }
                .sharedBackgroundVisibility(.hidden)
            // Keeps the buttons at the trailing edge when the title is removed.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { breadcrumb }
            ToolbarItemGroup(placement: .primaryAction) { toolbarButtons }
        }
    }

    /// The conversation's title, after its project's name in a quieter weight and colour.
    @ViewBuilder
    private var breadcrumb: some View {
        if let conversation = window.conversation, !window.chat.messages.isEmpty {
            let prefix = appState.conversations.project(for: conversation).map {
                Text(verbatim: "\($0.name) / ").font(.system(size: 13)).foregroundStyle(Color.secondary)
            } ?? Text(verbatim: "")
            let title = Text(verbatim: conversation.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.primary)
            TitleBreadcrumb(text: Text("\(prefix)\(title)"), titleBar: titleBar)
        }
    }

    /// The Work Surface button, while the panel is hidden; an open panel carries its own add
    /// and hide buttons in its tab strip.
    @ViewBuilder
    private var toolbarButtons: some View {
        if !window.workSurface.isPresented {
            Button {
                window.workSurface.togglePresented()
            } label: {
                Label("Work Surface", systemImage: "sidebar.right")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(GhostIconButtonStyle(size: AppControlHeight.composerButton, iconSize: 15))
            .accessibilityIdentifier("chat.toolbar.workSurface")
            .accessibilityLabel("Work Surface")
            .help("Show Work Surface")
        }
    }

    /// A new conversation gathers its greeting and the composer around
    /// `emptyStateCenterFraction` of the height; the first message settles the composer at
    /// the bottom under the transcript. The composer is the same view in both, so it moves.
    private var chatColumn: some View {
        let isEmpty = window.chat.messages.isEmpty
        return GeometryReader { proxy in
            let isCompact = proxy.size.width < AppLayout.emptyStateCompactWidth
            VStack(spacing: 0) {
                if let conversationID = window.conversationID {
                    ChatRunStatusView(conversationID: conversationID)
                    NativeDelegationTaskView(conversationID: conversationID)
                }

                if appState.providers.selectedProvider == nil {
                    ChatStatusCallout()
                }

                if isEmpty {
                    Spacer(minLength: AppSpacing.large)
                    EmptyConversationView(isCompact: isCompact)
                } else {
                    conversationContent
                }

                if let errorMessage = window.chat.errorMessage {
                    ChatErrorBanner(message: errorMessage)
                }

                RecoveryBannerView()

                UndoPlanBanner()

                ConversationApprovalArea(questionMaximumHeight: proxy.size.height * 0.6)

                if let child = window.conversation, child.isNativeDelegationChild {
                    NativeChildInteractionView(conversationID: child.id)
                } else {
                    ComposerView(isEmptyState: isEmpty, isCompact: isCompact)
                }

                if isEmpty {
                    Spacer(minLength: AppSpacing.large)
                    // Equal spacers would centre the group; this puts its centre higher.
                    Color.clear
                        .frame(height: max(0, proxy.size.height * (1 - 2 * AppLayout.emptyStateCenterFraction)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(AppColors.canvas.ignoresSafeArea())
        .animation(AppMotion.resolved(AppMotion.composerSettle), value: isEmpty)
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

    private var conversationContent: some View {
        let conversationID = window.conversationID
        return MessageListView(
            messages: window.chat.messages,
            retractableMessageID: window.chat.retractableUserMessageID,
            onRetract: { pendingUndo = UndoRequest(messageID: $0) },
            compactionMarkers: window.conversation?.compactionMarkers ?? [],
            compaction: conversationID.flatMap { appState.conversationRuns.compactions[$0] },
            isRunActive: conversationID.map {
                appState.conversationRuns.isRunning(conversationID: $0) || appState.conversationRuns.isPaused(conversationID: $0)
            } ?? false
        )
        .id(window.conversationID)
        // Ends under the title bar, which has no backing of its own, and above the composer:
        // lines fade out at both edges instead of being cut through. At the top a clear band
        // comes first, so a line scrolled to the edge is gone, not left as half a ghost. The
        // transcript's own vertical padding is wider than the fades, so its first and last
        // lines rest clear.
        .clipped()
        .mask(
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: AppLayout.transcriptTopClear)
                // Eased in (opacity ≈ t²): a line half inside the fade stays near invisible
                // until it is almost clear of it, instead of showing its lower half.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0.06), location: 0.25),
                        .init(color: .black.opacity(0.25), location: 0.5),
                        .init(color: .black.opacity(0.56), location: 0.75),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: AppLayout.transcriptTopFade)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: AppLayout.scrollEdgeFade)
            }
        )
    }
}

/// The Work Surface sheet's frame in window coordinates, while it is shown.
@MainActor
@Observable
private final class TitleBarLayout {
    var workSurfaceFrame: CGRect?
}

/// The breadcrumb in the title bar, stopping short of the Work Surface sheet where the sheet
/// shares the title bar's height with it, hidden where the sheet covers where it starts.
///
/// The full title, hidden, sets the toolbar item's width, and the shown title is truncated over
/// it. The toolbar centres its item's content, so a breadcrumb that narrowed itself would move
/// right by half of what it gave up, read less room from its new place and narrow again, never
/// settling, and it would keep the whole window rendering.
private struct TitleBreadcrumb: View {
    let text: Text
    let titleBar: TitleBarLayout
    @State private var frame: CGRect?

    var body: some View {
        text
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                let width = room
                text
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: width, alignment: .leading)
                    .opacity(width == 0 ? 0 : 1)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }

    /// Up to the sheet, less a margin; none when that leaves too little; unlimited when the
    /// sheet is elsewhere.
    private var room: CGFloat? {
        guard let sheet = titleBar.workSurfaceFrame, let frame,
              sheet.minY < frame.maxY, sheet.maxX > frame.minX else { return nil }
        let room = sheet.minX - frame.minX - AppSpacing.medium
        return room < AppSpacing.xLarge ? 0 : room
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
        .background(AppColors.statusWarning.opacity(0.10))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(AppColors.statusWarning.opacity(0.20)),
            alignment: .bottom
        )
    }
}

/// The greeting above a new conversation's composer, quiet so the composer leads: the mark, a
/// faint flat stamp, and one grey line, a size smaller in a narrow chat.
private struct EmptyConversationView: View {
    let isCompact: Bool

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            // The glyph's ink is 53% of its square's height, so a 52pt square draws a mark
            // 28pt tall; the negative padding trims the empty band above and below it.
            LimareGlyph(size: 52)
                .foregroundStyle(Color.primary.opacity(0.35))
                .padding(.vertical, -12)
            Text("What shall we build today?")
                .font(.system(size: isCompact ? 17 : 19, weight: .regular))
                .tracking(-0.2)
                .foregroundStyle(Color.primary.opacity(0.46))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, isCompact ? AppSpacing.standard : AppSpacing.chatHorizontal)
        // With the composer's own 8pt above its card, 30pt between the line and the card.
        .padding(.bottom, AppSpacing.emptyStateGreetingGap - AppSpacing.small)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
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
        // Reached by Tab under keyboard navigation only: a click or drag must not leave the
        // edge focused, or its line stays lit after the pointer has gone.
        .focusable(interactions: .activate)
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
