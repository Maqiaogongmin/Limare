import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage(StreamingSendPreference.storageKey) private var streamingSendPreference: StreamingSendPreference = .queue
    @State private var isFileTargeted = false
    @State private var isComposerExpanded = false
    @State private var isEditorFocused = false
    @State private var measuredContentHeight: CGFloat = AppLayout.composerDraftMinimumHeight
    /// The highlighted row of the command menu.
    @State private var commandSelection = 0
    /// The draft the user closed the command menu on (Escape); it opens again once the draft changes.
    @State private var commandMenuDismissedDraft: String?
    /// Bumped to make the editor first responder (Focus Composer).
    @State private var focusToken = 0
    /// The highlighted row of the @ mention menu.
    @State private var mentionSelection = 0
    /// A new conversation centres the composer in a narrower column, without the disclaimer.
    var isEmptyState = false
    /// A narrow chat: the composer gives the page's side margin back to its controls.
    var isCompact = false
    /// The draft the user closed the mention menu on (Escape); kept apart from the command menu's.
    @State private var mentionMenuDismissedDraft: String?

    private var currentMaxDraftHeight: CGFloat {
        isComposerExpanded
            ? AppLayout.composerDraftExpandedMaximumHeight
            : AppLayout.composerDraftNormalMaximumHeight
    }

    private var visibleDraftHeight: CGFloat {
        min(max(measuredContentHeight, AppLayout.composerDraftMinimumHeight), currentMaxDraftHeight)
    }

    private func handleSend() {
        guard canSend else { return }
        // Queue or steer is decided now, by what the user saw when pressing send.
        // When the run is paused or pausing, normal send is treated as a direct steer that auto-resumes the run.
        let isPausedOrPausing = window.chat.isPaused || window.chat.isPausing
        let queueing = (!isPausedOrPausing && window.chat.isStreaming) && streamingSendPreference == .queue
        Task { await window.chat.sendAttachingMentionedImages(queueing: queueing) }
    }

    /// The commands the draft is typing, while the editor has focus. Commands take no
    /// attachments, so the menu stays closed while files are attached.
    private var commandMatches: [ComposerCommand] {
        let draft = window.chat.draft
        guard isEditorFocused, draft != commandMenuDismissedDraft, window.chat.pendingAttachments.isEmpty else { return [] }
        return ComposerCommand.matches(forDraft: draft)
    }

    /// The `@` token at the end of the draft, while the editor has focus.
    private var mentionQuery: ComposerMentionQuery? {
        let draft = window.chat.draft
        guard isEditorFocused, draft != mentionMenuDismissedDraft else { return nil }
        return ComposerMentionParser.query(in: draft)
    }

    /// The folder the conversation's tools work in, as the tool cards resolve it.
    private var mentionWorkspaceURL: URL? {
        window.conversationID.map {
            appState.conversations.effectiveWorkingDirectory(for: $0)
        } ?? appState.workspace.url
    }

    private func mentionMatches(for query: ComposerMentionQuery) -> [ComposerMentionCandidate] {
        guard let workspaceURL = mentionWorkspaceURL else { return [] }
        return ComposerMentionProvider.candidates(
            workspaceURL: workspaceURL,
            directoryPart: query.directoryPart,
            namePrefix: query.namePrefix
        )
    }

    private func runMention(_ candidate: ComposerMentionCandidate) {
        guard let query = mentionQuery else { return }
        window.chat.draft = ComposerMentionParser.insertion(of: candidate, into: window.chat.draft, query: query)
    }

    private func handleMenuKey(_ key: ComposerMenuKey) -> Bool {
        if let query = mentionQuery {
            let mentions = mentionMatches(for: query)
            if !mentions.isEmpty {
                let index = min(mentionSelection, mentions.count - 1)
                switch key {
                case .up: mentionSelection = (index - 1 + mentions.count) % mentions.count
                case .down: mentionSelection = (index + 1) % mentions.count
                case .accept, .complete: runMention(mentions[index])
                case .dismiss: mentionMenuDismissedDraft = window.chat.draft
                }
                return true
            }
        }
        let matches = commandMatches
        guard !matches.isEmpty else { return false }
        let index = min(commandSelection, matches.count - 1)
        switch key {
        case .up: commandSelection = (index - 1 + matches.count) % matches.count
        case .down: commandSelection = (index + 1) % matches.count
        case .complete: window.chat.draft = matches[index].invocation
        case .accept: run(matches[index])
        case .dismiss: commandMenuDismissedDraft = window.chat.draft
        }
        return true
    }

    private func run(_ command: ComposerCommand) {
        window.chat.draft = command.invocation
        handleSend()
    }

    var body: some View {
        VStack(spacing: AppSpacing.xSmall) {
            ComposerQueueStatusBanner()

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                if !window.chat.pendingAttachments.isEmpty {
                    ComposerPendingAttachmentsView()
                }

                // Upper level: multiline input with expand/collapse button
                HStack(alignment: .top, spacing: AppSpacing.xxSmall) {
                    ComposerDraftEditor(
                        text: draftBinding,
                        placeholder: placeholderText,
                        onSend: handleSend,
                        onFocusChange: { isEditorFocused = $0 },
                        onContentHeightChange: { height in
                            measuredContentHeight = height
                        },
                        onFilesDropped: { urls in
                            importFiles(urls.map { HostFileSelection.droppedByUser(url: $0) })
                        },
                        onMenuKey: handleMenuKey,
                        focusToken: focusToken
                    )
                    .frame(height: visibleDraftHeight)

                    if measuredContentHeight > AppLayout.composerDraftMinimumHeight * 1.5 || isComposerExpanded {
                        Button {
                            withAnimation(AppMotion.resolved(AppMotion.layout)) {
                                isComposerExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isComposerExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppColors.textMuted)
                                .frame(width: 22, height: 22)
                                .background(AppColors.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(isComposerExpanded ? "Collapse Composer" : "Expand Composer")
                        .transition(.opacity)
                    }
                }

                // Lower level: Input tools (Left) + Model & Run controls (Right). The ghost
                // buttons carry their own air, so they sit close.
                HStack(alignment: .center, spacing: AppSpacing.xxxSmall) {
                    Button {
                        pickFiles()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(GhostIconButtonStyle())
                    .help("Attach files")
                    .accessibilityLabel("Attachments")
                    .disabled(isDictatingHere)

                    ComposerDraftHistoryButton()

                    if isDictatingHere && appState.voiceInput.state.isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(AppColors.statusError)
                                .frame(width: 8, height: 8)
                            Text("Recording \(formatRecordingDuration(appState.voiceInput.elapsedSeconds))")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.primary)

                            Button {
                                appState.voiceInput.cancel()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Cancel recording")

                            Button {
                                appState.voiceInput.finish()
                            } label: {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Finish recording and transcribe")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppColors.statusError.opacity(0.08))
                        .clipShape(Capsule())
                    } else if isDictatingHere && appState.voiceInput.state.isTranscribing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Transcribing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppColors.surfaceInteractive)
                        .clipShape(Capsule())
                    } else {
                        Button {
                            appState.voiceInput.setChatStore(window.chat)
                            appState.voiceInput.start()
                        } label: {
                            Image(systemName: "mic")
                        }
                        .buttonStyle(GhostIconButtonStyle())
                        .help("Voice input (dictation)")
                        .accessibilityLabel("Microphone")
                    }

                    if appState.voiceInput.isTarget(window.chat), let errorMsg = appState.voiceInput.errorMessage, !appState.voiceInput.state.isActive {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                            Text(errorMsg)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(.secondary)
                            if appState.voiceInput.isPermissionDenied {
                                Button("Open Settings") {
                                    PrivacySettingsOpener.openMicrophoneSettings()
                                }
                                .font(.caption2.bold())
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                            Button {
                                appState.voiceInput.clearError()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss error")
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AppColors.statusWarning.opacity(0.1))
                        .clipShape(Capsule())
                    }

                    ComposerSubagentControl()

                    // No minimum: the buttons and pills on either side carry their own air.
                    Spacer(minLength: 0)

                    ComposerThinkingControl(isCompact: isCompact)

                    ContextUsageIndicator(conversationID: window.conversationID)

                    ComposerModelSelector()
                        .layoutPriority(1)

                    ComposerRunControls(canSend: canSend, onSend: handleSend)
                }
                .padding(.top, (isEmptyState ? AppSpacing.emptyStateDraftToolbarGap : AppSpacing.composerDraftToolbarGap) - AppSpacing.xSmall)
            }
            .padding(.top, AppSpacing.standard)
            .padding(.bottom, AppSpacing.medium)
            .padding(.horizontal, AppSpacing.standard)
            // A new conversation's composer is the page's centre: a fuller card.
            .frame(minHeight: isEmptyState ? AppLayout.emptyStateComposerMinimumHeight : nil, alignment: .top)
            // A matte white card on the canvas: a crisp 1pt edge marks it, and only a tight
            // shadow where it meets the page, no diffuse halo.
            .background(
                RoundedRectangle(cornerRadius: AppRadius.composerCard, style: .continuous)
                    .fill(AppColors.raisedSurface)
                    .shadow(color: .black.opacity(0.025), radius: 2, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.composerCard, style: .continuous)
                    .strokeBorder(isFileTargeted ? Color.accentColor : AppColors.composerStroke, lineWidth: isFileTargeted ? 2 : 1)
            )
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls.map { HostFileSelection.droppedByUser(url: $0) })
                return !urls.isEmpty
            } isTargeted: { targeted in
                isFileTargeted = targeted
            }
            // Opens upward from the composer, over the transcript, as in Claude Code and Codex.
            // The guide sits on a container: SwiftUI ignores an alignment guide set inside an
            // `if` branch of the overlay, which put the menu over the composer.
            .overlay(alignment: .topLeading) {
                let mentions = mentionQuery.map(mentionMatches(for:)) ?? []
                let matches = mentions.isEmpty ? commandMatches : []
                VStack(spacing: 0) {
                    if !mentions.isEmpty {
                        ComposerMentionMenu(
                            candidates: mentions,
                            selection: min(mentionSelection, mentions.count - 1),
                            onHover: { mentionSelection = $0 },
                            onChoose: runMention
                        )
                    } else if !matches.isEmpty {
                        ComposerCommandMenu(
                            commands: matches,
                            query: String(window.chat.draft.dropFirst()),
                            selection: min(commandSelection, matches.count - 1),
                            onHover: { commandSelection = $0 },
                            onChoose: run
                        )
                    }
                }
                .alignmentGuide(.top) { $0[.bottom] + AppSpacing.xSmall }
            }

        }
        .frame(maxWidth: isEmptyState ? AppLayout.emptyStateMaximumWidth : AppLayout.transcriptMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isCompact ? AppSpacing.standard : AppSpacing.chatHorizontal)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, isEmptyState ? 0 : AppSpacing.composerBottom)
        .background(Color.clear)
        // A window that opens, or a conversation that is switched to, starts in the composer,
        // not in the first field AppKit finds (the sidebar's search).
        .onAppear { focusEditor() }
        .onChange(of: window.conversationID) { _, _ in focusEditor() }
        .onChange(of: window.composerFocusRequest) { _, _ in
            serveFocusRequest()
        }
        // An idle conversation shows what its next request would use; a run writes its own.
        .task(id: contextPreviewTrigger) {
            guard let trigger = contextPreviewTrigger, !trigger.isBusy else { return }
            appState.conversationRuns.refreshContextUsagePreview(conversationID: trigger.conversationID, modelSource: trigger.modelSource)
        }
        .onChange(of: window.chat.draft) { _, newDraft in
            commandSelection = 0
            mentionSelection = 0
            if newDraft != commandMenuDismissedDraft { commandMenuDismissedDraft = nil }
            if newDraft != mentionMenuDismissedDraft { mentionMenuDismissedDraft = nil }
            if newDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(AppMotion.resolved(AppMotion.layout)) {
                    isComposerExpanded = false
                }
                measuredContentHeight = AppLayout.composerDraftMinimumHeight
            }
        }
    }

    private struct ContextPreviewTrigger: Equatable {
        let conversationID: UUID
        let modelSource: ConversationModelSource
        let messageCount: Int
        let isBusy: Bool
    }

    private func serveFocusRequest() {
        guard window.composerFocusServed != window.composerFocusRequest else { return }
        focusEditor()
    }

    private func focusEditor() {
        window.composerFocusServed = window.composerFocusRequest
        focusToken += 1
    }

    private var contextPreviewTrigger: ContextPreviewTrigger? {
        guard let conversationID = window.conversationID,
              let modelSource = ModelChoiceCatalog.currentModelSource(conversation: window.conversation,
                                                                      modelGroups: appState.modelGroups, providers: appState.providers)
        else { return nil }
        let runs = appState.conversationRuns
        let isBusy = !runs.canStartRun(conversationID: conversationID) || runs.compactions[conversationID]?.isRunning == true
        // Not read during a run, so streamed tokens do not re-evaluate the composer.
        return ContextPreviewTrigger(
            conversationID: conversationID,
            modelSource: modelSource,
            messageCount: isBusy ? -1 : runs.conversationMessages(for: conversationID).count,
            isBusy: isBusy
        )
    }

    @MainActor
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            importFiles(panel.urls.map { HostFileSelection.openPanelSelection(url: $0) })
        }
    }

    @MainActor
    private func importFiles(_ selections: [HostFileSelection]) {
        Task { @MainActor in
            // Preserve the user's picker order and retain already committed
            // files if a later selection fails.
            for selection in selections {
                do { try await window.chat.addAttachment(from: selection) }
                catch { window.chat.errorMessage = error.localizedDescription }
            }
        }
    }

    private var hasValidModelSource: Bool {
        if let source = window.conversation?.effectiveModelSource {
            switch source {
            case .group(let groupID):
                return hasAvailableChatModel(in: groupID)
            case .direct(let providerID, let modelID):
                return isChatEligible(providerID: providerID, modelID: modelID)
            }
        }
        if let primaryID = appState.modelGroups.defaultPrimaryGroupId {
            return hasAvailableChatModel(in: primaryID)
        }
        guard let provider = appState.providers.selectedProvider else { return false }
        return isChatEligible(providerID: provider.id, modelID: provider.selectedModelID)
    }

    private func hasAvailableChatModel(in groupID: String) -> Bool {
        guard let group = appState.modelGroups.group(for: groupID) else { return false }
        return !appState.modelGroups.availableEntries(for: group, providers: appState.providers.providers).isEmpty
    }

    private func isChatEligible(providerID: UUID, modelID: String) -> Bool {
        let entryID = ModelGroup.makeEntryId(providerID: providerID, modelID: modelID)
        let eligibility = ModelGroupStore.evaluateMemberEligibility(entryId: entryID, providers: appState.providers.providers)
        return eligibility.isChatEligible || eligibility.unavailableReason == "Removed by provider"
    }

    private var placeholderText: String {
        if !hasValidModelSource {
            return "Choose an available chat model below…"
        }
        return "Ask anything, @ to mention files or tools…"
    }

    private var canSend: Bool {
        window.chat.canSend && hasValidModelSource && !isDictatingHere
    }

    /// Dictation is going into this window's composer. The microphone is one, so dictation
    /// started in another window shows there only.
    private var isDictatingHere: Bool {
        appState.voiceInput.isTarget(window.chat) && appState.voiceInput.state.isActive
    }

    private func formatRecordingDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { window.chat.draft },
            set: { window.chat.draft = $0 }
        )
    }
}

/// The commands matching what follows "/" in the composer. The highlighted row runs on Return
/// or a click, Tab completes it, Escape closes the menu.
private struct ComposerCommandMenu: View {
    let commands: [ComposerCommand]
    let query: String
    let selection: Int
    let onHover: (Int) -> Void
    let onChoose: (ComposerCommand) -> Void

    var body: some View {
        ComposerMenuScroller(selection: selection) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                HStack(spacing: AppSpacing.medium) {
                    highlightedName(command.invocation)
                        .font(.body)
                    Text(command.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.vertical, AppSpacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.modal, style: .continuous)
                        .fill(index == selection ? Color.secondary.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
                .onHover { if $0 { onHover(index) } }
                // A tap, not a button: the editor keeps focus, so the menu stays open under the click.
                .onTapGesture { onChoose(command) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(index == selection ? .isSelected : [])
                .accessibilityAction { onChoose(command) }
                .id(index)
            }
        }
        .padding(AppSpacing.xxSmall)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityIdentifier("composer.commandMenu")
    }

    /// The typed part of the name in bold, as Claude Code shows it.
    private func highlightedName(_ name: String) -> Text {
        let typed = "/" + query
        guard !query.isEmpty, let range = name.range(of: typed, options: [.caseInsensitive, .anchored])
                ?? name.range(of: query, options: .caseInsensitive) else { return Text(name) }
        return Text(name[..<range.lowerBound]) + Text(name[range]).bold() + Text(name[range.upperBound...])
    }
}

/// Opens the conversation's archived drafts — retracted messages and drafts that were replaced
/// or left behind — to bring one back into the composer. Hidden while the archive is empty.
private struct ComposerDraftHistoryButton: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var isPresented = false

    var body: some View {
        let drafts = window.chat.archivedDrafts
        if !drafts.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(GhostIconButtonStyle())
            .help("找回草稿")
            .accessibilityLabel("找回草稿")
            .accessibilityIdentifier("composer.draftHistory")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ComposerDraftHistoryList(
                    drafts: drafts,
                    onRestore: { id in
                        if window.chat.restoreArchivedDraft(id) {
                            isPresented = false
                        }
                    },
                    onDelete: { id in
                        window.chat.deleteArchivedDraft(id)
                    }
                )
            }
        }
    }
}

private struct ComposerDraftHistoryList: View {
    let drafts: [ArchivedDraft]
    let onRestore: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("找回草稿")
                .font(.headline)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(drafts) { draft in
                        row(for: draft)
                        if draft.id != drafts.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 340)
    }

    private func row(for draft: ArchivedDraft) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.small) {
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text(draft.text.isEmpty ? "（仅附件）" : draft.text)
                    .font(AppTypography.interfaceCaption)
                    .lineLimit(2)
                    .foregroundStyle(Color.primary)
                HStack(spacing: AppSpacing.xSmall) {
                    Text(draft.origin == .retractedMessage ? "撤回的消息" : "未发送的草稿")
                    Text(draft.createdAt, style: .relative)
                    if !draft.attachments.isEmpty {
                        Label("\(draft.attachments.count)", systemImage: "paperclip")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: AppSpacing.small)
            Button("恢复") { onRestore(draft.id) }
                .controlSize(.small)
            Button {
                onDelete(draft.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("删除这份草稿")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }
}

private struct ComposerQueueStatusBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    private var activeConversationID: UUID? {
        window.conversationID
    }

    private var queuedCount: Int {
        guard let id = activeConversationID else { return 0 }
        return appState.conversationRuns.queuedInputCount(for: id)
    }

    private var isHeld: Bool {
        guard let id = activeConversationID else { return false }
        return appState.conversationRuns.isQueueHeld(for: id)
    }

    var body: some View {
        if let convID = activeConversationID, queuedCount > 0 {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: isHeld ? "pause.circle.fill" : "clock.arrow.circlepath")
                    .foregroundStyle(isHeld ? AppColors.statusWarning : Color.secondary)
                    .font(.system(size: 12))

                Text(isHeld
                    ? "\(queuedCount) queued (paused after stop/error)"
                    : "\(queuedCount) queued for next run"
                )
                .font(.caption)
                .foregroundStyle(isHeld ? Color.primary : Color.secondary)

                Spacer()

                if isHeld {
                    Button("Resume Queue") {
                        appState.conversationRuns.resumeQueue(conversationID: convID)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Button("Clear") {
                        appState.conversationRuns.clearQueue(conversationID: convID)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if !window.chat.isStreaming {
                    Button("Run Queue") {
                        appState.conversationRuns.resumeQueue(conversationID: convID)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    Button("Clear") {
                        appState.conversationRuns.clearQueue(conversationID: convID)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, 6)
            .background(isHeld ? AppColors.statusWarning.opacity(0.1) : AppColors.surfaceInteractive)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
    }
}

private struct ComposerRunControls: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage(StreamingSendPreference.storageKey) private var streamingSendPreference: StreamingSendPreference = .queue
    let canSend: Bool
    var onSend: (() -> Void)? = nil

    private var isPausing: Bool {
        window.chat.isPausing
    }

    private var isPaused: Bool {
        window.chat.isPaused
    }

    private var isStreaming: Bool {
        window.chat.isStreaming
    }

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            if isStreaming {
                if window.chat.isResumingFromNewMessage {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("New message received · resuming")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                } else if isPausing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Pausing…")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppColors.statusWarning)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppColors.statusWarning.opacity(0.12))
                    .clipShape(Capsule())
                } else if isPaused {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(AppColors.statusWarning)
                            .frame(width: 5, height: 5)
                        Text("Paused")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppColors.statusWarning.opacity(0.1))
                    .clipShape(Capsule())
                }

                // Pause / Resume control
                if isPaused {
                    Button {
                        window.chat.resume()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: AppControlHeight.runButton, height: AppControlHeight.runButton)
                            .background(Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Resume run")
                    .accessibilityLabel("Resume run")
                } else if isPausing {
                    Button {
                        window.chat.resume()
                    } label: {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: AppControlHeight.runButton, height: AppControlHeight.runButton)
                            .background(AppColors.statusWarning.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Pausing at next boundary (click to cancel)")
                    .accessibilityLabel("Pausing at next boundary")
                } else {
                    // Pause and stop are neutral: colour stays for states, and stop, filled,
                    // is still the strongest control in the row.
                    Button {
                        window.chat.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(AppColors.textPrimary)
                            .frame(width: AppControlHeight.runButton, height: AppControlHeight.runButton)
                            .background(AppColors.surfaceInteractive)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Pause run")
                    .accessibilityLabel("Pause run")
                }

                Button {
                    window.chat.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppColors.surfacePrimary)
                        .frame(width: AppControlHeight.runButton, height: AppControlHeight.runButton)
                        .background(AppColors.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Stop current run")
                .accessibilityLabel("Stop current run")
                .accessibilityIdentifier("chat.composer.stop")
            }

            // Always present Send Button
            sendButton
        }
    }

    private var sendButtonHelpText: String {
        if !isStreaming {
            return "Send message (Return or ⌘Return)"
        }
        if isPaused || isPausing {
            return "Send message and resume run"
        }
        switch streamingSendPreference {
        case .queue:
            return "Queue message to run after current turn"
        case .steer:
            return "Add instruction to current turn"
        }
    }

    private var sendButtonAccessibilityLabel: String {
        if !isStreaming {
            return "Send message"
        }
        if isPaused || isPausing {
            return "Send message and resume"
        }
        switch streamingSendPreference {
        case .queue:
            return "Queue message"
        case .steer:
            return "Steer run"
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        Button {
            onSend?()
        } label: {
            // A faint tile until there is something to send, so the card always ends on it, then
            // a charcoal one, the strongest mark in the composer.
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSend ? AppColors.sendGlyph : Color.primary.opacity(0.35))
                .frame(width: AppControlHeight.runButton, height: AppControlHeight.runButton)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous)
                        .fill(canSend ? AppColors.sendFill : Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.runButton, style: .continuous))
                .animation(AppMotion.resolved(AppMotion.quick), value: canSend)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
        .help(sendButtonHelpText)
        .accessibilityLabel(sendButtonAccessibilityLabel)
        .accessibilityIdentifier("chat.composer.send")
    }
}

private struct ComposerPendingAttachmentsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.small) {
                ForEach(window.chat.pendingAttachments) { att in
                    PendingAttachmentView(attachment: att) {
                        window.chat.removeAttachment(id: att.id)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xxSmall)
            .padding(.vertical, AppSpacing.xxSmall)
        }
    }
}

private struct PendingAttachmentView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        if attachment.kind == .image {
            imageThumbnail
        } else {
            fileChip
        }
    }

    private var imageThumbnail: some View {
        ZStack(alignment: .topTrailing) {
            let url = try? appState.attachments.fileURL(for: attachment)
            if let url, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 52, height: 52)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    )
            }

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
    }

    private var fileChip: some View {
        HStack(spacing: 8) {
            Button {
                window.previewAttachment(attachment)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: attachment.kind.systemImageName)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(attachment.filename)
            .accessibilityLabel("预览 \(attachment.filename)")
            .accessibilityIdentifier("composer.attachmentPreview")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除附件")
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 240)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
    }
}

struct ComposerModelSelector: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.composer.recentDirectModels") private var recentDirectModelIDs = ""
    @State private var isShowingModelBrowser = false

    private var selectableGroups: [ModelGroup] {
        ModelChoiceCatalog.selectableGroups(modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    private var visibleModelEntries: [ModelPickerEntry] {
        ModelChoiceCatalog.visibleModelEntries(providers: appState.providers.providers, current: currentModelSource)
    }

    private var recentEntries: [ModelPickerEntry] {
        let entries = visibleModelEntries
        return recentDirectModelIDs.split(separator: "\n").prefix(5).compactMap { id in
            entries.first(where: { $0.id == id })
        }
    }

    private var currentModelSource: ConversationModelSource? {
        ModelChoiceCatalog.currentModelSource(conversation: window.conversation,
                                              modelGroups: appState.modelGroups, providers: appState.providers)
    }

    var body: some View {
        // Its full title when the composer has room, else as wide as the room: a fixed width
        // made a long model name push the composer past a narrow chat column.
        // A group shows the model it would use now ("chat · DeepSeek V4.1 Flash"). Short of room
        // the group's name goes first, then the icon and the chevron: the model is what the
        // user needs to read, and it truncates only when nothing else is left to give up.
        ViewThatFits(in: .horizontal) {
            menu(label: compactModelLabel).fixedSize(horizontal: true, vertical: false)
            menu(label: modelName).fixedSize(horizontal: true, vertical: false)
            menu(label: modelName, showsIcon: false).fixedSize(horizontal: true, vertical: false)
            menu(label: modelName, showsIcon: false, showsChevron: false).fixedSize(horizontal: true, vertical: false)
            menu(label: modelName, showsIcon: false, showsChevron: false, truncates: true)
        }
        .disabled(window.chat.isStreaming)
        .help(modelHelp)
        .accessibilityLabel(activeModelLabel)
        .sheet(isPresented: $isShowingModelBrowser) {
            ComposerModelBrowser(
                entries: visibleModelEntries,
                selectedSource: currentModelSource
            ) { entry in
                selectDirectModel(providerID: entry.providerID, modelID: entry.model.id)
                isShowingModelBrowser = false
            }
        }
    }

    private func menu(label: String, showsIcon: Bool = true, showsChevron: Bool = true, truncates: Bool = false) -> some View {
        Menu {
            if !selectableGroups.isEmpty {
                Section("Model Groups") {
                    ForEach(selectableGroups) { group in
                        // A Toggle draws the menu's own checkmark on the current choice.
                        Toggle(modelGroupLabel(group), isOn: Binding(
                            get: {
                                if case .group(let gID) = currentModelSource { return gID == group.id }
                                return false
                            },
                            set: { _ in selectGroup(group.id) }
                        ))
                    }
                }
            }

            if !recentEntries.isEmpty {
                Section("Recent Models") {
                    ForEach(recentEntries) { entry in
                        Toggle("\(entry.providerName) / \(entry.model.displayName)", isOn: Binding(
                            get: { isCurrentDirect(providerID: entry.providerID, modelID: entry.model.id) },
                            set: { _ in selectDirectModel(providerID: entry.providerID, modelID: entry.model.id) }
                        ))
                    }
                }
            }

            if !visibleModelEntries.isEmpty {
                Button("Find a Model…", systemImage: "magnifyingglass") {
                    isShowingModelBrowser = true
                }
            }

            if !visibleModelEntries.isEmpty {
                Section("Providers & Models") {
                    ForEach(appState.providers.providers) { provider in
                        let visibleModels = provider.models.filter { model in
                            let entryID = ModelGroup.makeEntryId(providerID: provider.id, modelID: model.id)
                            guard ModelGroupStore.evaluateMemberEligibility(
                                entryId: entryID,
                                providers: appState.providers.providers
                            ).isChatEligible else { return false }
                            if !model.isHidden && !model.discovery.isAbsent { return true }
                            if case .direct(let pID, let mID) = currentModelSource {
                                return pID == provider.id && mID == model.id
                            }
                            return false
                        }
                        if !visibleModels.isEmpty {
                            Menu(provider.name) {
                                ForEach(visibleModels) { model in
                                    Toggle(model.displayName, isOn: Binding(
                                        get: { isCurrentDirect(providerID: provider.id, modelID: model.id) },
                                        set: { _ in selectDirectModel(providerID: provider.id, modelID: model.id) }
                                    ))
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Configure Providers…") {
                window.screen = .settingsProviders
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                if showsIcon {
                    Image(systemName: iconName)
                        .font(.system(size: 11))
                }

                // The last resort fills whatever width it is given; the others keep to the cap.
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: truncates ? nil : AppLayout.composerModelLabelMaximumWidth, alignment: .leading)

                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .composerPill()
        }
        // A plain button style keeps the label's own quiet colour (see the thinking pill).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var iconName: String {
        if case .group = currentModelSource {
            return "square.stack.3d.up"
        }
        return "cpu"
    }

    private var activeModelLabel: String {
        ModelChoiceCatalog.label(for: currentModelSource, modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    /// The group or model name alone.
    private var sourceName: String {
        ModelChoiceCatalog.shortLabel(for: currentModelSource, modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    private var groupSummary: (short: String, long: String)? {
        guard case .group(let groupID) = currentModelSource else { return nil }
        return ModelChoiceCatalog.groupModelSummary(groupID: groupID, modelGroups: appState.modelGroups,
                                                    providers: appState.providers.providers)
    }

    /// The model itself: a group's current model, or the direct model's name.
    private var modelName: String {
        groupSummary?.short ?? sourceName
    }

    private var compactModelLabel: String {
        guard let summary = groupSummary else { return sourceName }
        return "\(sourceName) · \(summary.short)"
    }

    private var modelHelp: String {
        groupSummary?.long ?? activeModelLabel
    }

    private func isCurrentDirect(providerID: UUID, modelID: String) -> Bool {
        if case .direct(let pID, let mID) = currentModelSource { return pID == providerID && mID == modelID }
        return false
    }

    private func selectGroup(_ groupID: String) {
        if let activeID = window.conversationID {
            appState.conversations.setConversationModelSource(id: activeID, source: .group(groupID: groupID))
        }
    }

    private func modelGroupLabel(_ group: ModelGroup) -> String {
        var uses: [String] = []
        if appState.modelGroups.defaultPrimaryGroupId == group.id { uses.append("Chat default") }
        if appState.modelGroups.defaultSubGroupId == group.id { uses.append("Helper") }
        if appState.modelGroups.visionGroupId == group.id { uses.append("Images") }
        if appState.modelGroups.voiceInputGroupId == group.id { uses.append("Voice input") }
        if appState.modelGroups.voiceOutputGroupId == group.id { uses.append("Voice output") }
        guard !uses.isEmpty else { return group.name }
        return "\(group.name) · \(uses.joined(separator: ", "))"
    }

    private func selectDirectModel(providerID: UUID, modelID: String) {
        guard let activeID = window.conversationID else { return }
        appState.conversations.setConversationModelSource(id: activeID, source: .direct(providerID: providerID, modelID: modelID))
        let selectedID = ModelGroup.makeEntryId(providerID: providerID, modelID: modelID)
        let otherIDs = recentDirectModelIDs.split(separator: "\n").map(String.init).filter { $0 != selectedID }
        recentDirectModelIDs = ([selectedID] + otherIDs).prefix(5).joined(separator: "\n")
    }
}

private struct ComposerModelBrowser: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    let entries: [ModelPickerEntry]
    let selectedSource: ConversationModelSource?
    let onSelect: (ModelPickerEntry) -> Void

    private var filteredEntries: [ModelPickerEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.providerName.localizedCaseInsensitiveContains(query)
                || $0.model.displayName.localizedCaseInsensitiveContains(query)
                || $0.model.id.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose Model")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppSpacing.standard)

            TextField("Search providers or models", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .padding(.horizontal, AppSpacing.standard)
                .padding(.bottom, AppSpacing.small)

            Divider()

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No Models Available", systemImage: "cpu")
                } description: {
                    Text("Add a provider or make a model visible to select it here.")
                } actions: {
                    Button("Configure Providers…") {
                        dismiss()
                        window.screen = .settingsProviders
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        HStack(spacing: AppSpacing.small) {
                            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                                Text(entry.model.displayName)
                                    .font(.body.weight(.medium))
                                Text("\(entry.providerName) · \(entry.model.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if case .direct(let providerID, let modelID) = selectedSource,
                               providerID == entry.providerID, modelID == entry.model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 360, idealWidth: 520, minHeight: 360, idealHeight: 520)
        .onAppear { isSearchFocused = true }
    }
}
