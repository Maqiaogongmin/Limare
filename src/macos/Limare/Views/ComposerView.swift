import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(StreamingSendPreference.storageKey) private var streamingSendPreference: StreamingSendPreference = .queue
    @State private var isFileTargeted = false
    @State private var isComposerExpanded = false
    @State private var isEditorFocused = false
    @State private var measuredContentHeight: CGFloat = AppLayout.composerDraftMinimumHeight
    /// The highlighted row of the command menu.
    @State private var commandSelection = 0
    /// The draft the user closed the command menu on (Escape); it opens again once the draft changes.
    @State private var commandMenuDismissedDraft: String?

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
        let isPausedOrPausing = appState.chat.isPaused || appState.chat.isPausing
        let queueing = (!isPausedOrPausing && appState.chat.isStreaming) && streamingSendPreference == .queue
        Task { await appState.chat.sendAttachingMentionedImages(queueing: queueing) }
    }

    /// The commands the draft is typing, while the editor has focus. Commands take no
    /// attachments, so the menu stays closed while files are attached.
    private var commandMatches: [ComposerCommand] {
        let draft = appState.chat.draft
        guard isEditorFocused, draft != commandMenuDismissedDraft, appState.chat.pendingAttachments.isEmpty else { return [] }
        return ComposerCommand.matches(forDraft: draft)
    }

    private func handleMenuKey(_ key: ComposerMenuKey) -> Bool {
        let matches = commandMatches
        guard !matches.isEmpty else { return false }
        let index = min(commandSelection, matches.count - 1)
        switch key {
        case .up: commandSelection = (index - 1 + matches.count) % matches.count
        case .down: commandSelection = (index + 1) % matches.count
        case .complete: appState.chat.draft = matches[index].invocation
        case .accept: run(matches[index])
        case .dismiss: commandMenuDismissedDraft = appState.chat.draft
        }
        return true
    }

    private func run(_ command: ComposerCommand) {
        appState.chat.draft = command.invocation
        handleSend()
    }

    var body: some View {
        VStack(spacing: AppSpacing.xSmall) {
            ComposerQueueStatusBanner()

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                if !appState.chat.pendingAttachments.isEmpty {
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
                        onMenuKey: handleMenuKey
                    )
                    .frame(height: visibleDraftHeight)
                    .padding(.horizontal, AppSpacing.xxSmall)
                    .padding(.top, AppSpacing.xxxSmall)

                    if measuredContentHeight > AppLayout.composerDraftMinimumHeight * 1.5 || isComposerExpanded {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
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
                        .padding(.top, AppSpacing.xxxSmall)
                        .padding(.trailing, AppSpacing.xxSmall)
                        .transition(.opacity)
                    }
                }

                // Lower level: Input tools (Left) + Model & Run controls (Right)
                HStack(alignment: .center, spacing: AppSpacing.small) {
                    Button {
                        pickFiles()
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach files")
                    .disabled(appState.voiceInput.state.isActive)

                    ComposerDraftHistoryButton()

                    if appState.voiceInput.state.isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
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
                                    .frame(width: 20, height: 20)
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
                                    .frame(width: 20, height: 20)
                                    .background(Color.accentColor)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Finish recording and transcribe")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.08))
                        .clipShape(Capsule())
                    } else if appState.voiceInput.state.isTranscribing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Transcribing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                    } else {
                        Button {
                            appState.voiceInput.start()
                        } label: {
                            Image(systemName: "mic")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Voice input (dictation)")
                    }

                    if let errorMsg = appState.voiceInput.errorMessage, !appState.voiceInput.state.isActive {
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
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                    }

                    ComposerSubagentControl()

                    Spacer(minLength: AppSpacing.small)

                    ComposerThinkingControl()

                    ComposerModelSelector()

                    ComposerRunControls(canSend: canSend, onSend: handleSend)
                }
                .padding(.horizontal, AppSpacing.xxSmall)
                .padding(.bottom, AppSpacing.xxxSmall)
            }
            .padding(AppSpacing.small)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous)
                    .stroke(isFileTargeted ? Color.accentColor : Color.secondary.opacity(0.16), lineWidth: isFileTargeted ? 2 : 1)
            )
            .dropDestination(for: URL.self) { urls, _ in
                importFiles(urls.map { HostFileSelection.droppedByUser(url: $0) })
                return !urls.isEmpty
            } isTargeted: { targeted in
                isFileTargeted = targeted
            }
            // Opens upward from the composer, over the transcript, as in Claude Code and Codex.
            .overlay(alignment: .topLeading) {
                let matches = commandMatches
                if !matches.isEmpty {
                    ComposerCommandMenu(
                        commands: matches,
                        query: String(appState.chat.draft.dropFirst()),
                        selection: min(commandSelection, matches.count - 1),
                        onHover: { commandSelection = $0 },
                        onChoose: run
                    )
                    .alignmentGuide(.top) { $0[.bottom] + AppSpacing.xSmall }
                }
            }

            Text("Limare can make mistakes. Review tool calls before relying on changes.")
                .font(AppTypography.interfaceCaption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: AppLayout.transcriptMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.chatHorizontal)
        .padding(.top, AppSpacing.small)
        .padding(.bottom, AppSpacing.small)
        .background(Color.clear)
        .onChange(of: appState.chat.draft) { _, newDraft in
            commandSelection = 0
            if newDraft != commandMenuDismissedDraft { commandMenuDismissedDraft = nil }
            if newDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isComposerExpanded = false
                }
                measuredContentHeight = AppLayout.composerDraftMinimumHeight
            }
        }
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
                do { try await appState.chat.addAttachment(from: selection) }
                catch { appState.chat.errorMessage = error.localizedDescription }
            }
        }
    }

    private var hasValidModelSource: Bool {
        if let source = appState.conversations.activeConversation?.effectiveModelSource {
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
        return "Message Limare… (Shift+Return for new line)"
    }

    private var canSend: Bool {
        appState.chat.canSend && hasValidModelSource && !appState.voiceInput.state.isActive
    }

    private func formatRecordingDuration(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { appState.chat.draft },
            set: { appState.chat.draft = $0 }
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
        VStack(alignment: .leading, spacing: 0) {
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
    @State private var isPresented = false

    var body: some View {
        let drafts = appState.chat.archivedDrafts
        if !drafts.isEmpty {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("找回草稿")
            .accessibilityLabel("找回草稿")
            .accessibilityIdentifier("composer.draftHistory")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                ComposerDraftHistoryList(
                    drafts: drafts,
                    onRestore: { id in
                        if appState.chat.restoreArchivedDraft(id) {
                            isPresented = false
                        }
                    },
                    onDelete: { id in
                        appState.chat.deleteArchivedDraft(id)
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

    private var activeConversationID: UUID? {
        appState.conversations.activeConversationID
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
                    .foregroundStyle(isHeld ? Color.orange : Color.secondary)
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
                } else if !appState.chat.isStreaming {
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
            .background(isHeld ? Color.orange.opacity(0.1) : Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
    }
}

private struct ComposerRunControls: View {
    @Environment(AppState.self) private var appState
    @AppStorage(StreamingSendPreference.storageKey) private var streamingSendPreference: StreamingSendPreference = .queue
    let canSend: Bool
    var onSend: (() -> Void)? = nil

    private var isPausing: Bool {
        appState.chat.isPausing
    }

    private var isPaused: Bool {
        appState.chat.isPaused
    }

    private var isStreaming: Bool {
        appState.chat.isStreaming
    }

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            if isStreaming {
                if appState.chat.isResumingFromNewMessage {
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
                        appState.chat.resume()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Resume run")
                    .accessibilityLabel("Resume run")
                } else if isPausing {
                    Button {
                        appState.chat.resume()
                    } label: {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 22, height: 22)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Pausing at next boundary (click to cancel)")
                    .accessibilityLabel("Pausing at next boundary")
                } else {
                    Button {
                        appState.chat.pause()
                    } label: {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(Color.orange.opacity(0.85))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Pause run")
                    .accessibilityLabel("Pause run")
                }

                // Stop control (Red)
                Button {
                    appState.chat.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red)
                        .clipShape(Circle())
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
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                .background(canSend ? Color.accentColor : Color.secondary.opacity(0.15))
                .clipShape(Circle())
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.small) {
                ForEach(appState.chat.pendingAttachments) { att in
                    PendingAttachmentView(attachment: att) {
                        appState.chat.removeAttachment(id: att.id)
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
            Image(systemName: attachment.kind.systemImageName)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }.buttonStyle(.plain)
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
        ModelChoiceCatalog.currentModelSource(conversation: appState.conversations.activeConversation,
                                              modelGroups: appState.modelGroups, providers: appState.providers)
    }

    var body: some View {
        // Its full title when the composer has room, else as wide as the room: a fixed width
        // made a long model name push the composer past a narrow chat column.
        ViewThatFits(in: .horizontal) {
            menu.fixedSize(horizontal: true, vertical: false)
            menu
        }
        .disabled(appState.chat.isStreaming)
        .help(activeModelLabel)
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

    private var menu: some View {
        Menu {
            if !selectableGroups.isEmpty {
                Section("Model Groups") {
                    ForEach(selectableGroups) { group in
                        Button {
                            selectGroup(group.id)
                        } label: {
                            let groupLabel = modelGroupLabel(group)
                            let isSelected: Bool = {
                                if case .group(let gID) = currentModelSource {
                                    return gID == group.id
                                }
                                return false
                            }()
                            if isSelected {
                                Label(groupLabel, systemImage: "checkmark")
                            } else if appState.modelGroups.defaultPrimaryGroupId == group.id {
                                Label(groupLabel, systemImage: "star.fill")
                            } else {
                                Text(groupLabel)
                            }
                        }
                    }
                }
            }

            if !recentEntries.isEmpty {
                Section("Recent Models") {
                    ForEach(recentEntries) { entry in
                        Button {
                            selectDirectModel(providerID: entry.providerID, modelID: entry.model.id)
                        } label: {
                            Text("\(entry.providerName) / \(entry.model.displayName)")
                        }
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
                                    Button {
                                        selectDirectModel(providerID: provider.id, modelID: model.id)
                                    } label: {
                                        let isSelected: Bool = {
                                            if case .direct(let pID, let mID) = currentModelSource {
                                                return pID == provider.id && mID == model.id
                                            }
                                            return false
                                        }()
                                        if isSelected {
                                            Label(model.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(model.displayName)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Configure Providers…") {
                appState.screen = .settingsProviders
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(compactModelLabel)
                    .font(AppTypography.interfaceCaption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
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

    private var compactModelLabel: String {
        ModelChoiceCatalog.shortLabel(for: currentModelSource, modelGroups: appState.modelGroups, providers: appState.providers.providers)
    }

    private func selectGroup(_ groupID: String) {
        if let activeID = appState.conversations.activeConversationID {
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
        guard let activeID = appState.conversations.activeConversationID else { return }
        appState.conversations.setConversationModelSource(id: activeID, source: .direct(providerID: providerID, modelID: modelID))
        let selectedID = ModelGroup.makeEntryId(providerID: providerID, modelID: modelID)
        let otherIDs = recentDirectModelIDs.split(separator: "\n").map(String.init).filter { $0 != selectedID }
        recentDirectModelIDs = ([selectedID] + otherIDs).prefix(5).joined(separator: "\n")
    }
}

private struct ComposerModelBrowser: View {
    @Environment(AppState.self) private var appState
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
                        appState.screen = .settingsProviders
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
