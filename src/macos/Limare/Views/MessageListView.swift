import SwiftUI

struct MessageListView: View {
    let messages: [ChatMessage]
    /// The user message offering the retract action, if any.
    var retractableMessageID: UUID? = nil
    var onRetract: @MainActor (UUID) -> Void = { _ in }
    /// Finished Compact commands, each shown as a line after the message that was last when it ran.
    var compactionMarkers: [CompactionMarker] = []
    /// The Compact command in progress or just failed, shown as a line at the end.
    var compaction: ManualCompaction? = nil
    /// The conversation's run is working or paused: its last turn folds the steps before the
    /// current one.
    var isRunActive = false
    @State private var coordinator = ScrollFollowCoordinator()
    /// The last turn's fold while the reader is away from the bottom, so nothing they are
    /// reading or selecting moves into the fold under them.
    @State private var frozenFold: TranscriptTurnGrouping.FrozenFold?
    /// Scroll-driven state lives outside this view's dependencies: only the navigator reads it,
    /// so scrolling never re-evaluates the transcript rows.
    @State private var viewport = TranscriptViewportState()
    /// Changing it rebuilds the scroll view, as switching conversations does.
    @State private var layoutGeneration = 0
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        // Derived once per transcript change; rows receive plain values and skip re-rendering
        // whenever their own row is unchanged.
        let entries = TranscriptTurnGrouping.project(messages, isRunActive: isRunActive, frozenFold: frozenFold)
        let navigatorEntries = UserMessageNavigatorModel.entries(from: messages)
        let markersByEntry = CompactionMarkerPlacement.markersByEntry(compactionMarkers, entries: entries)
        let trailingCompaction = compaction.flatMap { $0.isFinished ? nil : $0 }
        return ScrollViewReader { proxy in
            ScrollView {
                // A plain stack, as Enchanted's transcript: every row has its real height, so the
                // offset can never land in space a lazy stack only estimated (the 2026-10 white
                // screen). Rows are equatable and their renderings cached, so streaming updates
                // cost the same; opening the longest conversations costs ~0.3 s more.
                VStack(spacing: AppSpacing.large) {
                    ForEach(entries) { entry in
                        TranscriptEntryView(
                            entry: entry,
                            isRetractable: entry.message.id == retractableMessageID,
                            onRetract: { onRetract(entry.message.id) },
                            onSelectionBecameActive: {
                                coordinator.textSelectionBecameActive()
                            },
                            onCollapse: {
                                proxy.scrollTo(entry.id, anchor: .top)
                                DispatchQueue.main.async {
                                    proxy.scrollTo(entry.id, anchor: .top)
                                }
                            }
                        )
                        .equatable()
                        .id(entry.id)

                        ForEach(markersByEntry[entry.id] ?? [], id: \.date) { marker in
                            CompactionStatusLine(state: .finished(tokensBefore: marker.tokensBefore, tokensAfter: marker.tokensAfter))
                        }
                    }
                    if let trailingCompaction {
                        CompactionStatusLine(state: trailingCompaction)
                            .id(Self.compactionStatusID)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: AppLayout.transcriptMaximumWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppSpacing.chatHorizontal)
            }
            // Margins, not padding: a scroll to a row (the tail as it grows, a jump to a message)
            // stops inside them, where padding would be scrolled past. Clear of the top fade, and
            // of the composer below by more than its fade, so the last message's buttons never
            // sit against the composer's edge.
            .contentMargins(.top, AppLayout.transcriptTopClear + AppLayout.transcriptTopFade + AppSpacing.xxSmall, for: .scrollContent)
            .contentMargins(.bottom, AppSpacing.chatVertical + AppSpacing.large, for: .scrollContent)
            // Opens on the latest message and stays there as the transcript grows, but a short
            // conversation reads from the top like any chat; one `.bottom` anchor for every role
            // pinned "你好" to the bottom of an empty window. A reader who left the bottom keeps
            // their place while the run adds below them.
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(coordinator.isFollowingTail ? .bottom : .top, for: .sizeChanges)
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.1) { visibleIDs in
                if let active = UserMessageNavigatorModel.activeEntryID(visibleIDs: visibleIDs, messages: messages) {
                    viewport.activeUserMessageID = active
                }
            }
            // Blank detection needs "any part of a row is on screen": at the 10% threshold above,
            // a row taller than ten viewports is never visible although it fills the screen.
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.0001) { visibleIDs in
                viewport.rowsOnScreen = visibleIDs
                if let last = visibleIDs.last { viewport.lastOnScreenEntryID = last }
                scheduleBlankViewportCheck(entryIDs: entries.map(\.id))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewport.height = height
            }
            .overlay(alignment: .leading) {
                if navigatorEntries.count >= UserMessageNavigatorModel.minimumEntryCount {
                    TranscriptNavigatorOverlay(entries: navigatorEntries, viewport: viewport) { id in
                        jumpToUserMessage(id, proxy: proxy)
                    }
                    .padding(.leading, AppSpacing.xxxSmall)
                }
            }
            .onScrollGeometryChange(for: TranscriptViewportState.Geometry.self) { geometry in
                .init(offset: geometry.contentOffset.y, content: geometry.contentSize.height, container: geometry.containerSize.height)
            } action: { _, value in
                viewport.geometry = value
                if viewport.rowsOnScreen.isEmpty {
                    scheduleBlankViewportCheck(entryIDs: entries.map(\.id))
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height - (geometry.contentOffset.y + geometry.containerSize.height)
                return distanceFromBottom <= 48
            } action: { _, isNear in
                coordinator.updateViewportProximity(isNearBottom: isNear)
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                let isUserActivePhase = (newPhase == .interacting || newPhase == .tracking)
                let wasUserPhase = (oldPhase == .interacting || oldPhase == .tracking || oldPhase == .decelerating)

                if isUserActivePhase && (oldPhase == .idle || oldPhase == .animating || oldPhase == .decelerating) {
                    coordinator.userScrollInteractionBegan()
                } else if wasUserPhase && newPhase == .idle {
                    coordinator.userScrollInteractionEnded(isNearBottom: coordinator.isNearBottom)
                }
            }
            .onAppear {
                coordinator.recordUserMessageID(messages.last(where: { $0.role == .user })?.id)
                if let target = viewport.rebuildTarget {
                    // Rebuilt after a blank viewport while the user was reading earlier rows.
                    viewport.rebuildTarget = nil
                    proxy.scrollTo(target, anchor: .top)
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                } else {
                    scrollToBottom(proxy: proxy, entryID: entries.last?.id)
                }
            }
            .onChange(of: scrollChangeToken) {
                if coordinator.shouldScrollOnMessageUpdate(messages: messages) {
                    scrollToBottom(proxy: proxy, entryID: entries.last?.id)
                }
            }
            .onChange(of: coordinator.isFollowingTail) { _, isFollowing in
                frozenFold = isFollowing ? nil : TranscriptTurnGrouping.lastTurnFold(of: entries)
            }
            .onChange(of: trailingCompaction) { _, status in
                // The line appears at the end: keep it in view when the user is at the bottom.
                guard status != nil, coordinator.isFollowingTail else { return }
                proxy.scrollTo(Self.compactionStatusID, anchor: .bottom)
            }
            .id(layoutGeneration)
        }
    }

    /// Safety net, kept with its log after the plain stack and unanimated scrolling removed the
    /// known cause. A non-empty transcript whose viewport shows no part of any row is never a
    /// valid state. With the lazy stack it was seen right after a send and when a finished turn
    /// folded into one row (2026-10-07), the two moments that scrolled with animation; scrolling
    /// to a row did not help, switching conversations (a rebuild) did. So recovery rebuilds the
    /// scroll view and returns to the bottom, or to the row the user was reading.
    ///
    /// Only a state that lasts is acted on: layout transitions, scroll animations and the first
    /// layout pass empty the visible set briefly, and every visibility or geometry change
    /// restarts the wait. At most three rebuilds a minute, so a state a rebuild cannot fix does
    /// not keep rebuilding.
    private func scheduleBlankViewportCheck(entryIDs: [UUID]) {
        viewport.blankCheckGeneration &+= 1
        guard viewport.rowsOnScreen.isEmpty, !entryIDs.isEmpty else { return }
        let generation = viewport.blankCheckGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard viewport.blankCheckGeneration == generation, viewport.rowsOnScreen.isEmpty,
                  !coordinator.isUserScrollInteractionActive,
                  viewport.geometry.content > 0, viewport.geometry.container > 0 else { return }
            let geometry = viewport.geometry
            let now = Date()
            viewport.recentRebuilds.removeAll { now.timeIntervalSince($0) > 60 }
            let canRebuild = viewport.recentRebuilds.count < 3
            appState.logs.error("Transcript", "Viewport showed no rows for 0.75 s (offset \(Int(geometry.offset)), content \(Int(geometry.content)), viewport \(Int(geometry.container)), \(entryIDs.count) rows, following \(coordinator.isFollowingTail)); \(canRebuild ? "rebuilding the transcript view" : "not rebuilding: three rebuilds in the last minute").")
            guard canRebuild else { return }
            viewport.recentRebuilds.append(now)
            viewport.rebuildTarget = coordinator.isFollowingTail ? nil : viewport.lastOnScreenEntryID.flatMap { id in entryIDs.contains(id) ? id : nil }
            viewport.rowsOnScreen = []
            layoutGeneration &+= 1
        }
    }

    private func jumpToUserMessage(_ id: UUID, proxy: ScrollViewProxy) {
        coordinator.userScrolledAway()
        viewport.activeUserMessageID = id
        withAnimation(AppMotion.resolved(AppMotion.panel)) {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    /// The trailing Compact status line's scroll identity.
    private static let compactionStatusID = UUID()

    /// Never animated (Enchanted scrolls the same way): an animated scroll that runs while rows are
    /// added or a turn folds into one row ends on an offset computed for the old layout. The
    /// target is the last entry: the last message may sit inside a fold without an id of its own.
    private func scrollToBottom(proxy: ScrollViewProxy, entryID: UUID?) {
        guard let targetID = entryID else { return }
        proxy.scrollTo(targetID, anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo(targetID, anchor: .bottom)
        }
    }

    private var scrollChangeToken: String {
        guard let last = messages.last else { return "empty" }
        let toolState = last.toolCalls.map {
            "\($0.id.uuidString):\($0.state.rawValue):\($0.output.utf8.count)"
        }.joined(separator: "|")
        let reasoningCount = last.reasoningContent?.utf8.count ?? 0
        return "\(messages.count):\(last.id.uuidString):\(last.state.rawValue):\(last.content.utf8.count):\(reasoningCount):\(toolState)"
    }
}

/// Places each finished compaction after the entry holding the message it follows; one whose
/// message was folded into a turn's history follows that turn.
enum CompactionMarkerPlacement {
    static func markersByEntry(_ markers: [CompactionMarker], entries: [TranscriptTurnGrouping.Entry]) -> [UUID: [CompactionMarker]] {
        guard !markers.isEmpty else { return [:] }
        var entryForMessage: [UUID: UUID] = [:]
        for entry in entries {
            entryForMessage[entry.message.id] = entry.id
            for row in entry.history ?? [] { entryForMessage[row.id] = entry.id }
        }
        var result: [UUID: [CompactionMarker]] = [:]
        for marker in markers {
            guard let entryID = entryForMessage[marker.afterMessageID] else { continue }
            result[entryID, default: []].append(marker)
        }
        return result
    }
}

/// The Compact command in the transcript, as Claude Code and Codex show theirs: one quiet line,
/// no card and nothing to dismiss.
private struct CompactionStatusLine: View {
    let state: ManualCompaction

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            switch state {
            case .running(let since):
                ProgressView().controlSize(.mini)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("Compacting conversation… \(max(0, Int(context.date.timeIntervalSince(since))))s")
                        .monospacedDigit()
                }
            case .finished(let before, let after):
                let saved = max(0, before - after)
                Text("Conversation compacted · \(Self.tokens(saved)) tokens saved")
                    .help("The model now reads a summary of the conversation up to here (about \(Self.tokens(before)) → \(Self.tokens(after)) tokens). The transcript is unchanged.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.statusError)
                Text("Compact failed: \(message)")
                    .textSelection(.enabled)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

/// One transcript entry: an optional collapsed execution history above its row.
private struct TranscriptEntryView: View, Equatable {
    let entry: TranscriptTurnGrouping.Entry
    let isRetractable: Bool
    let onRetract: @MainActor () -> Void
    let onSelectionBecameActive: @MainActor () -> Void
    let onCollapse: @MainActor () -> Void

    nonisolated static func == (lhs: TranscriptEntryView, rhs: TranscriptEntryView) -> Bool {
        lhs.entry == rhs.entry && lhs.isRetractable == rhs.isRetractable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            if entry.startsAssistantTurn {
                AssistantSpeakerHeader()
            }
            turnBody
        }
    }

    private var turnBody: some View {
        let message = entry.message
        return VStack(alignment: .leading, spacing: AppSpacing.large) {
            if let history = entry.history {
                DisclosureGroup {
                    if entry.row.hidesReasoning, let reasoning = message.reasoningContent, !reasoning.isEmpty {
                        ReasoningDisclosureView(reasoning: reasoning, state: message.state, hasVisibleOutput: ReasoningDisclosureView.hasVisibleOutput(content: message.content, toolCalls: message.toolCalls))
                    }
                    VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                        ForEach(history) { item in
                            MessageRow(row: item)
                                .equatable()
                        }
                    }
                    .environment(\.isInExecutionFold, true)
                } label: {
                    ExecutionHistoryLabel(count: history.count, unsuccessfulCount: entry.unsuccessfulCount)
                }
                if !entry.pinnedToolCalls.isEmpty {
                    FoldedChangeNotices(toolCalls: entry.pinnedToolCalls)
                }
                // What the user answered is their own words, so it stays out of the fold.
                ForEach(entry.answeredQuestionCalls) { toolCall in
                    AnsweredQuestionsView(toolCall: toolCall)
                }
            }
            MessageRow(
                row: entry.row,
                showsRetract: isRetractable,
                onRetract: onRetract,
                onSelectionBecameActive: onSelectionBecameActive,
                onCollapse: onCollapse
            )
            .equatable()
        }
    }
}

/// The one speaker line of an assistant turn, above everything the turn shows.
private struct AssistantSpeakerHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            AssistantAvatarView(
                image: appState.soul.cachedAvatarImage,
                size: 20
            )
            Text(appState.soul.effectiveDisplayName)
                .font(AppTypography.interfaceSubheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, AppSpacing.xxxSmall)
    }
}

/// A fold's title; tool calls inside it that did not succeed stay counted outside it.
private struct ExecutionHistoryLabel: View {
    let count: Int
    let unsuccessfulCount: Int

    /// A section label, quieter than the answer below it: secondary colour, one size under the
    /// interface text, whatever the conversation size is.
    var body: some View {
        Group {
            if unsuccessfulCount > 0 {
                Text("Execution · \(count) records\(Text(" · \(unsuccessfulCount) unsuccessful").foregroundColor(AppColors.statusWarning))")
            } else {
                Text("Execution · \(count) records")
            }
        }
        .font(AppTypography.interfaceSubheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// Folded tool calls that failed after changing files keep their card, and its undo, outside
/// the fold. Reads the undo journal itself, so the equatable entry above never hides a change.
private struct FoldedChangeNotices: View {
    let toolCalls: [ToolCallRecord]
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        let noticed = toolCalls.filter { ToolCallCard.changeNotice(for: $0, appState: appState, window: window) != nil }
        if !noticed.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                ForEach(noticed) { toolCall in
                    ToolCallCard(toolCall: toolCall)
                }
            }
        }
    }
}

/// Equatable on its row value only: the callbacks capture stable owners (scroll proxy, follow
/// coordinator), so an unchanged row skips its body when the transcript re-renders.
private struct MessageRow: View, Equatable {
    let row: TranscriptRow
    var showsRetract = false
    var onRetract: (@MainActor () -> Void)? = nil
    var onSelectionBecameActive: (@MainActor () -> Void)? = nil
    var onCollapse: (@MainActor () -> Void)? = nil

    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.row == rhs.row && lhs.showsRetract == rhs.showsRetract
    }

    private var message: ChatMessage { row.message }
    private var hidesReasoning: Bool { row.hidesReasoning }
    private var retractAction: (@MainActor () -> Void)? {
        guard showsRetract else { return nil }
        return onRetract
    }
    @State private var isHovered = false

    var body: some View {
        let presentation = row.presentation

        return HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: AppLayout.messageGutterMinimumWidth)

                VStack(alignment: .trailing, spacing: AppSpacing.xxSmall) {
                    if let scheduled = scheduledMessage {
                        ScheduledMessageBadge(parsed: scheduled)
                    }
                    messageBubble(presentation: presentation)
                    UserMessageActionBar(
                        message: message,
                        isVisible: isHovered,
                        onRetract: retractAction
                    )
                }
                // Bubble, gap and bar are one hover region. Hovering only what draws (the bubble
                // and the bar's glyphs) hid the bar as the pointer crossed the gap toward it, and
                // a hidden bar takes no hits, so it never came back.
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovered = hovering
                }
                // The action bar shows on hover only, and a hidden bar is out of the
                // accessibility tree; the message itself offers undo to accessibility clients.
                .accessibilityActions {
                    if let retractAction {
                        Button("Undo This Message", action: retractAction)
                    }
                }
            } else {
                // A reply takes the column's whole width, as in other chat apps; only the user's
                // own messages keep a gutter, on their leading side. A trailing gutter here left
                // a narrow chat a dozen characters to a line.
                messageBubble(presentation: presentation)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func messageBubble(presentation: AssistantTurnPresentation) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            if !hidesReasoning, message.role == .assistant, let reasoning = message.reasoningContent, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReasoningDisclosureView(reasoning: reasoning, state: message.state, hasVisibleOutput: ReasoningDisclosureView.hasVisibleOutput(content: message.content, toolCalls: message.toolCalls))
                    .padding(.bottom, presentation.showsPrimaryProse ? AppSpacing.xxSmall : 0)
            }

            messageContent(presentation: presentation)

            if !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    ForEach(message.toolCalls) { toolCall in
                        if toolCall.name == "delegate_task" {
                            AgentRunGroupView(toolCall: toolCall)
                        } else {
                            ToolCallCard(toolCall: toolCall)
                        }
                    }
                }
                .padding(.top, AppSpacing.xxSmall)
            }

            if !row.deliveredArtifactIDs.isEmpty {
                DeliveredFilesView(artifactIDs: row.deliveredArtifactIDs)
                    .padding(.top, AppSpacing.xxSmall)
            }

            let speakerPayload = presentation.showsSpeakerAction
                ? presentation.authorizedSpeakerPayload.flatMap { VoiceTextSanitizer.sanitize($0).isEmpty ? nil : $0 }
                : nil
            if row.turnCopyPayload != nil || speakerPayload != nil {
                HStack(spacing: AppSpacing.small) {
                    if let payload = row.turnCopyPayload {
                        TurnCopyButton(payload: payload)
                    }
                    if let speakerPayload {
                        SpeakerButton(messageID: message.id, spokenPayload: speakerPayload)
                    }
                }
                .padding(.top, AppSpacing.xxSmall)
            }
        }
        .modifier(UserBubbleChrome(isUser: message.role == .user))
        // After the chrome: the bubble hugs its text and only a longer message reaches this
        // width and wraps.
        .frame(
            maxWidth: message.role == .user ? AppLayout.userMessageMaximumWidth : AppLayout.transcriptMaximumWidth,
            alignment: message.role == .user ? .trailing : .leading
        )
        .contextMenu {
            if message.role == .assistant {
                // Same eligibility authority as the inline TurnCopyButton (`row.turnCopyPayload`,
                // derived from `authorizedTurnCopyPayload`): never inferred from payload non-emptiness.
                if let payload = row.turnCopyPayload {
                    Button {
                        MessageClipboard.copy(text: payload)
                    } label: {
                        Label("Copy Response", systemImage: "doc.on.doc")
                    }
                }
            } else if message.role == .user {
                if MessageCopyPayloadResolver.canCopy(message: message) {
                    Button {
                        MessageClipboard.copyMessage(message)
                    } label: {
                        Label("Copy Message", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageContent(presentation: AssistantTurnPresentation) -> some View {
        switch message.role {
        case .user:
            userMessageContent
        case .assistant:
            assistantMessageContent(presentation: presentation)
        }
    }

    @ViewBuilder
    private var userMessageContent: some View {
        if !message.attachments.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ForEach(message.attachments) { att in
                    MessageAttachmentThumbnailView(attachment: att)
                }
                if !message.content.isEmpty {
                    userTextContent
                }
            }
        } else if !message.content.isEmpty {
            userTextContent
        }
    }

    /// A message a scheduled run sent: its header line becomes the badge above the bubble.
    private var scheduledMessage: ScheduledMessage.Parsed? {
        message.role == .user ? ScheduledMessage.parse(message.content) : nil
    }

    @ViewBuilder
    private var userTextContent: some View {
        UserMessageTextView(content: scheduledMessage?.body ?? message.content, onCollapse: onCollapse)
    }

    @ViewBuilder
    private func assistantMessageContent(presentation: AssistantTurnPresentation) -> some View {
        if !message.attachments.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ForEach(message.attachments) { att in
                    MessageAttachmentThumbnailView(attachment: att)
                }
                if presentation.showsPrimaryProse && !message.content.isEmpty {
                    assistantTextContent
                }
            }
        } else if presentation.showsPrimaryProse {
            assistantTextContent
        }
    }

    /// The runtime's own words in a reply that never came; a reply that went on afterwards
    /// is the model's again.
    private var runtimeNotice: ChatMessage.RuntimeNotice? {
        switch message.state {
        case .failed, .interrupted:
            message.runtimeNotice ?? (message.content.isEmpty && message.state == .interrupted ? .interrupted : nil)
        case .complete, .streaming:
            nil
        }
    }

    @ViewBuilder
    private var assistantTextContent: some View {
        if message.content.isEmpty && message.state == .streaming {
            HStack(spacing: AppSpacing.small) {
                ProgressView()
                    .controlSize(.small)
                ProviderWaitLabel()
            }
            .padding(.vertical, AppSpacing.xxSmall)
        } else if let notice = runtimeNotice {
            RuntimeNoticeLabel(notice: notice, text: ChatMessage.RuntimeNotice.displayText(for: message.content.isEmpty ? ChatMessage.RuntimeNotice.interruptedText : message.content))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LimareMarkdownView(
                source: message.content,
                profile: .chat(isStreaming: message.state == .streaming, messageId: message.id.uuidString),
                onSelectionBecameActive: onSelectionBecameActive
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A user message collapses when its rendered height passes the collapsed maximum; the 1pt
/// tolerance keeps a message that just fits from flipping on rounding.
enum UserMessageCollapse {
    static func isCollapsible(measuredHeight: CGFloat, collapsedMaximum: CGFloat) -> Bool {
        measuredHeight > collapsedMaximum + 1
    }
}

private struct UserMessageTextView: View {
    let content: String
    var onCollapse: (@MainActor () -> Void)? = nil
    @State private var isExpanded = false
    /// The rendered message's natural height, measured before the collapsed clamp.
    @State private var measuredHeight: CGFloat = 0

    private var isCollapsible: Bool {
        UserMessageCollapse.isCollapsible(measuredHeight: measuredHeight, collapsedMaximum: collapsedMaxHeight)
    }

    private let collapsedMaxHeight: CGFloat = AppLayout.userMessageCollapsedMaximumHeight
    private let expandedMaxHeight: CGFloat = AppLayout.userMessageExpandedMaximumHeight
    private let fadeHeight: CGFloat = AppLayout.userMessageCollapseFadeHeight

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            if isCollapsible && isExpanded {
                ScrollView(.vertical) {
                    LimareMarkdownView(source: content, profile: .typed)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.trailing, 2)
                }
                .frame(maxHeight: expandedMaxHeight)
            } else {
                // Rendered like the assistant's replies, so a table or list the user sent reads
                // as one. Whether it collapses depends on its rendered height, not its length:
                // the natural height is measured before the clamp, and a collapsed message
                // fades out at the collapsed height.
                LimareMarkdownView(source: content, profile: .typed)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(height - measuredHeight) > 1 { measuredHeight = height }
                    }
                    .frame(maxHeight: isCollapsible ? collapsedMaxHeight : nil, alignment: .top)
                    .mask {
                        if isCollapsible {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: max(0, 1 - fadeHeight / collapsedMaxHeight)),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        } else {
                            Rectangle()
                        }
                    }
            }

            if isCollapsible {
                HStack(spacing: AppSpacing.small) {
                    Button {
                        if isExpanded {
                            onCollapse?()
                            isExpanded = false
                        } else {
                            isExpanded = true
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "Show less" : "Show more")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(AppTypography.interfaceCaption2.weight(.medium))
                        .foregroundStyle(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if isExpanded {
                        Text("\(content.count) chars")
                            .font(AppTypography.interfaceCaption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

/// "🕒 Scheduled Task · <name> · HH:mm" over a message a scheduled run sent, in place of the
/// `[Scheduled task …]` line the message carries for the model.
private struct ScheduledMessageBadge: View {
    let parsed: ScheduledMessage.Parsed

    var body: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
            Text("Scheduled Task · \(parsed.taskName) · \(parsed.time)")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color.primary.opacity(0.6))
        .padding(.horizontal, AppSpacing.xSmall)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript.scheduledBadge")
    }
}

/// A user's message: a white card with a hairline edge and a faint contact shadow on the
/// canvas. A reply has no chrome.
private struct UserBubbleChrome: ViewModifier {
    let isUser: Bool

    func body(content: Content) -> some View {
        if isUser {
            let shape = RoundedRectangle(cornerRadius: AppRadius.bubble, style: .continuous)
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    shape
                        .fill(AppColors.userBubble)
                        .shadow(color: .black.opacity(0.02), radius: 2, x: 0, y: 1)
                )
                .overlay(shape.stroke(AppColors.cardStroke, lineWidth: 1))
        } else {
            content
        }
    }
}

/// A reply the runtime wrote, not the model ("Request failed.", "Stopped."): a small status
/// line, not prose.
private struct RuntimeNoticeLabel: View {
    let notice: ChatMessage.RuntimeNotice
    let text: String

    private var icon: String {
        switch notice {
        case .failed: "exclamationmark.circle"
        case .stopped: "stop.circle"
        case .interrupted: "bolt.slash"
        }
    }

    var body: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .fill(AppColors.noticeFill)
        )
        .help(text)
    }
}

/// Hover-revealed actions beneath the bottom-right corner of a user bubble. The row always
/// reserves its height so revealing it never shifts the transcript.
private struct UserMessageActionBar: View {
    let message: ChatMessage
    let isVisible: Bool
    /// Present only on the retractable last user message.
    var onRetract: (@MainActor () -> Void)? = nil

    private enum Action: Hashable { case retract, copy }
    /// The bar's buttons are focus stops only where the system makes buttons focusable (Full
    /// Keyboard Access); a focused button shows the bar instead of leaving an invisible stop.
    @FocusState private var focusedAction: Action?

    private var isShown: Bool { isVisible || focusedAction != nil }

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            if let onRetract {
                Button(action: onRetract) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(BubbleActionButtonStyle())
                .focused($focusedAction, equals: .retract)
                .help("Undo This Message")
                .accessibilityLabel("Undo This Message")
                .accessibilityIdentifier("transcript.retractLastMessage")
            }
            if MessageCopyPayloadResolver.canCopy(message: message) {
                CopyMessageButton(message: message)
                    .focused($focusedAction, equals: .copy)
            }
        }
        .frame(height: 14)
        .opacity(isShown ? 1 : 0)
        .animation(AppMotion.resolved(AppMotion.standard), value: isShown)
        .allowsHitTesting(isShown)
    }
}

private struct CopyMessageButton: View {
    let message: ChatMessage
    @State private var isCopied = false

    var body: some View {
        Button {
            if MessageClipboard.copyMessage(message) {
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isCopied = false
                }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 14, height: 14)
        }
        .buttonStyle(BubbleActionButtonStyle())
        .help("Copy Message")
    }
}

/// The icons under a user bubble: faint at rest, near full ink under the pointer.
private struct BubbleActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BubbleActionBody(configuration: configuration)
    }

    private struct BubbleActionBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering || configuration.isPressed ? AppColors.bubbleActionHover : AppColors.bubbleActionIdle)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
        }
    }
}

private struct TurnCopyButton: View {
    let payload: String
    @State private var isCopied = false

    var body: some View {
        Button {
            if MessageClipboard.copy(text: payload) {
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    isCopied = false
                }
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(isCopied ? Color.accentColor : Color.secondary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help("Copy Response")
    }
}

/// Beside the spinner while the model has not answered yet: which model, for how long, and,
/// after a failed attempt, that it is being retried and why, as Claude Code's and Codex's
/// status lines do. A slow provider then reads as slow rather than stuck.
private struct ProviderWaitLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        if let conversationID = window.conversationID,
           let wait = appState.conversationRuns.providerWaits[conversationID] {
            TimelineView(.periodic(from: wait.since, by: 1)) { context in
                Text(Self.text(for: wait, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    static func text(for wait: ProviderWait, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(wait.since)))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
        guard let reason = wait.retryReason else {
            return String(localized: "Waiting for \(wait.modelID) · \(elapsed)")
        }
        return String(localized: "\(wait.modelID): \(describe(reason)), retrying (attempt \(wait.attempt)) · \(elapsed)")
    }

    /// The retry reason as recorded ("http:524", "urlError:-1005", "rateLimited"…), in words.
    private static func describe(_ reason: String) -> String {
        if reason.hasPrefix("http:") { return "HTTP \(reason.dropFirst(5))" }
        if reason.hasPrefix("urlError:") { return "network error \(reason.dropFirst(9))" }
        return reason
    }
}

/// The files a row delivered, as cards that preview them in the Files surface. A file that can
/// no longer be resolved (expired or removed) is left out.
private struct DeliveredFilesView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let artifactIDs: [UUID]

    var body: some View {
        if let store = appState.artifacts, let conversationID = window.conversationID {
            let descriptors = artifactIDs.compactMap {
                try? store.resolveDescriptor(artifactID: $0, conversationID: conversationID)
            }
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                ForEach(descriptors) { descriptor in
                    FileArtifactCard(artifact: descriptor, artifactStore: store)
                }
            }
        }
    }
}

private struct MessageAttachmentThumbnailView: View {
    let attachment: ChatAttachment
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        let url = try? appState.attachments.fileURL(for: attachment)
        if attachment.kind == .image, let url, let nsImage = NSImage(contentsOf: url) {
            let imgW = max(nsImage.size.width, 1)
            let imgH = max(nsImage.size.height, 1)
            let scale = min(320.0 / imgW, 240.0 / imgH, 1.0)
            let thumbWidth = max(imgW * scale, 48)
            let thumbHeight = max(imgH * scale, 48)

            Button {
                window.previewAttachment(attachment)
            } label: {
                // At most the thumbnail size, narrower when the chat column is: a fixed width
                // made the row wider than a narrow column, and the transcript widened with it.
                Color.clear
                    .aspectRatio(thumbWidth / thumbHeight, contentMode: .fit)
                    .frame(maxWidth: thumbWidth)
                    .overlay {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .stroke(AppColors.separator, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Preview image in Files Surface")
        } else {
            FileArtifactCard(attachment: attachment, attachmentStore: appState.attachments)
        }
    }
}

private struct SpeakerButton: View {
    let messageID: UUID
    let spokenPayload: String
    @Environment(AppState.self) private var appState

    private var state: VoiceOutputState { appState.voiceOutput.state }
    private var isActive: Bool { state.activeMessageID == messageID }

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Button {
                appState.voiceOutput.toggle(messageID: messageID, text: spokenPayload)
            } label: {
                if isActive && state.isPreparing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else if isActive {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)
            .help(helpText)

            if isActive && !state.isPreparing {
                Button {
                    appState.voiceOutput.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Stop reading")
            }

            if case .failed(let failedID, let message) = state, failedID == messageID {
                VoiceErrorCapsule(message: message, onDismiss: { appState.voiceOutput.clearError() })
            }
        }
    }

    private var helpText: String {
        if isActive {
            switch state {
            case .preparing:
                return String(localized: "Preparing voice output… (click to cancel)")
            case .playing(_, let engineLabel):
                return String(localized: "Pause reading · \(engineLabel)")
            case .paused(_, let engineLabel):
                return String(localized: "Resume reading · \(engineLabel)")
            case .idle, .failed:
                break
            }
        }
        return String(localized: "Read aloud")
    }
}




/// Everything a transcript row renders from, derived once per transcript change from the
/// canonical messages through the existing authorities (`AssistantTurnProjector`,
/// `AssistantTurnResolver.authorizedTurnCopyPayload`). Rows never see the whole transcript.
struct TranscriptRow: Identifiable, Equatable, Sendable {
    let message: ChatMessage
    let presentation: AssistantTurnPresentation
    /// The authorized Copy Response payload; `nil` when this row offers no turn copy.
    let turnCopyPayload: String?
    let hidesReasoning: Bool
    /// Files this row shows as cards: its own tools' deliverables, or for a finished turn's
    /// final answer, the whole turn's (see `TurnDeliverables`).
    let deliveredArtifactIDs: [UUID]
    var id: UUID { message.id }

    init(
        message: ChatMessage,
        in messages: [ChatMessage],
        hidesReasoning: Bool = false,
        deliveredArtifactIDs: [UUID]? = nil
    ) {
        self.message = message
        self.deliveredArtifactIDs = deliveredArtifactIDs ?? TurnDeliverables.artifactIDs(in: [message])
        self.presentation = AssistantTurnProjector.project(message: message, allMessages: messages)
        self.turnCopyPayload = message.role == .assistant
            ? AssistantTurnResolver.authorizedTurnCopyPayload(for: message.id, in: messages)
            : nil
        self.hidesReasoning = hidesReasoning
    }
}

/// Presentation projection only: canonical message history and copy/read-aloud semantics remain unchanged.
///
/// A turn is the assistant messages between two user messages. Its earlier steps fold under one
/// disclosure once it ends in a finished answer, while it runs (all but the current step), before
/// a message the user sent while it worked, and once it ended any other way (failed, stopped,
/// interrupted), its last message staying in view; only a stream with no run behind it shows
/// each message on its own.
enum TranscriptTurnGrouping {
    struct Entry: Identifiable, Equatable, Sendable {
        /// A folding turn's first message, so the entry keeps its identity, and its fold's
        /// open state, from the first step to the answer.
        let id: UUID
        let row: TranscriptRow
        let history: [TranscriptRow]?
        /// The first entry of an assistant turn, which carries the turn's one speaker line.
        let startsAssistantTurn: Bool
        /// Folded tool calls that did not succeed, counted on the fold's title.
        let unsuccessfulCount: Int
        /// Folded tool calls whose failure may have left file changes, shown outside the fold.
        let pinnedToolCalls: [ToolCallRecord]
        /// Folded question calls the user resolved, in order; their questions and answers show
        /// outside the fold.
        let answeredQuestionCalls: [ToolCallRecord]
        var message: ChatMessage { row.message }
    }

    /// Where the last turn's fold stood when the reader left the bottom of the transcript.
    struct FrozenFold: Equatable, Sendable {
        let anchorID: UUID
        let foldedCount: Int
    }

    static func project(_ messages: [ChatMessage], isRunActive: Bool = false, frozenFold: FrozenFold? = nil) -> [Entry] {
        var result: [Entry] = []
        var turn: [ChatMessage] = []
        func plain(_ message: ChatMessage, startsTurn: Bool) -> Entry {
            Entry(
                id: message.id,
                row: TranscriptRow(message: message, in: messages),
                history: nil,
                startsAssistantTurn: startsTurn,
                unsuccessfulCount: 0,
                pinnedToolCalls: [],
                answeredQuestionCalls: []
            )
        }
        /// The turn's first `rowIndex` messages folded above the message at `rowIndex`, which
        /// shows the whole turn's files.
        func folded(rowIndex: Int, hidesReasoning: Bool) -> Entry {
            let history = Array(turn[..<rowIndex])
            let calls = history.flatMap(\.toolCalls)
            return Entry(
                id: turn[0].id,
                row: TranscriptRow(
                    message: turn[rowIndex],
                    in: messages,
                    hidesReasoning: hidesReasoning,
                    deliveredArtifactIDs: TurnDeliverables.artifactIDs(in: turn)
                ),
                history: history.map { TranscriptRow(message: $0, in: messages, deliveredArtifactIDs: []) },
                startsAssistantTurn: true,
                unsuccessfulCount: calls.filter { isUnsuccessful($0.state) }.count,
                pinnedToolCalls: calls.filter { mayHaveLeftChanges($0.state) },
                answeredQuestionCalls: calls.filter { $0.questionResolution != nil }
            )
        }
        func flush(isLast: Bool, endsAtSteer: Bool) {
            guard let final = turn.last else { return }
            let isFinished = final.state == .complete && final.toolCalls.isEmpty
                && !final.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let frozenFold, frozenFold.anchorID == turn[0].id {
                let rowIndex = min(frozenFold.foldedCount, turn.count - 1)
                if rowIndex > 0 {
                    result.append(folded(rowIndex: rowIndex, hidesReasoning: isFinished && rowIndex == turn.count - 1))
                    result.append(contentsOf: turn[(rowIndex + 1)...].map { plain($0, startsTurn: false) })
                } else {
                    result.append(contentsOf: turn.enumerated().map { plain($1, startsTurn: $0 == 0) })
                }
            } else if isFinished {
                let hasDetails = turn.count > 1 || !(final.reasoningContent ?? "").isEmpty
                result.append(hasDetails ? folded(rowIndex: turn.count - 1, hidesReasoning: true) : plain(final, startsTurn: true))
            } else if turn.count > 1, (isLast && isRunActive) || endsAtSteer || final.state != .streaming {
                result.append(folded(rowIndex: turn.count - 1, hidesReasoning: false))
            } else {
                result.append(contentsOf: turn.enumerated().map { plain($1, startsTurn: $0 == 0) })
            }
            turn.removeAll(keepingCapacity: true)
        }
        for message in messages {
            if message.role == .user {
                flush(isLast: false, endsAtSteer: message.sentWhileWorking)
                result.append(plain(message, startsTurn: false))
            } else {
                turn.append(message)
            }
        }
        flush(isLast: true, endsAtSteer: false)
        return result
    }

    /// The last turn's current fold, to keep while the reader is away from the bottom; `nil` when
    /// the transcript ends with a user message.
    static func lastTurnFold(of entries: [Entry]) -> FrozenFold? {
        guard let last = entries.last, last.message.role == .assistant,
              let start = entries.last(where: \.startsAssistantTurn) else { return nil }
        return FrozenFold(anchorID: start.id, foldedCount: start.history?.count ?? 0)
    }

    static func isUnsuccessful(_ state: ToolExecutionState) -> Bool {
        switch state {
        case .failed, .timedOut, .cancelled, .denied, .interrupted: return true
        case .queued, .awaitingApproval, .running, .completed: return false
        }
    }

    /// The end states `ToolCallChangeTruth` checks for file changes.
    static func mayHaveLeftChanges(_ state: ToolExecutionState) -> Bool {
        switch state {
        case .failed, .timedOut, .cancelled, .interrupted: return true
        case .queued, .awaitingApproval, .running, .completed, .denied: return false
        }
    }
}

/// Scroll-driven transcript state. Held by `MessageListView` but read only by the navigator.
@MainActor
@Observable
final class TranscriptViewportState {
    var activeUserMessageID: UUID?
    var height: CGFloat = 0
    /// Not observed by any view: bookkeeping for blank-viewport recovery.
    /// Rows with any part on screen, and the last such row.
    @ObservationIgnored var rowsOnScreen: [UUID] = []
    @ObservationIgnored var lastOnScreenEntryID: UUID?
    @ObservationIgnored var blankCheckGeneration = 0
    @ObservationIgnored var recentRebuilds: [Date] = []
    @ObservationIgnored var rebuildTarget: UUID?
    @ObservationIgnored var geometry = Geometry(offset: 0, content: 0, container: 0)

    struct Geometry: Equatable {
        let offset: CGFloat
        let content: CGFloat
        let container: CGFloat
    }
}

private struct TranscriptNavigatorOverlay: View {
    let entries: [UserMessageNavigatorModel.Entry]
    let viewport: TranscriptViewportState
    let onSelect: (UUID) -> Void

    var body: some View {
        UserMessageNavigator(
            entries: entries,
            activeID: viewport.activeUserMessageID ?? entries.last?.id,
            availableHeight: max(viewport.height - 2 * AppSpacing.chatVertical, 0),
            onSelect: onSelect
        )
    }
}
