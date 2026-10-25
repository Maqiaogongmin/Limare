import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    private(set) var outcomeHandoffsByConversation: [UUID: OutcomeHandoff] = [:]
    private enum InteractiveSendMode {
        case steerOrSend
        case queue
    }

    var draft = ""
    private(set) var pendingAttachments: [ChatAttachment] = []
    /// True while a send is importing the images its text @-mentions; sending is unavailable.
    private(set) var isAttachingMentionedImages = false
    fileprivate(set) var messages: [ChatMessage] = []
    var errorMessage: String?

    private(set) var runCoordinator: ConversationRunCoordinator
    @ObservationIgnored private var runSubscription: ConversationRunSubscription?
    /// The admission path every send goes through; Remote shares this instance.
    @ObservationIgnored let interaction: ConversationInteractionService
    @ObservationIgnored private(set) var draftArchive: DraftArchiveStore?
    /// File restore for undo. Nil in contexts without the change journal.
    @ObservationIgnored private(set) var undo: UndoCoordinator?
    /// The archived draft the composer was last filled from. Sending consumes it; while the
    /// composer still holds exactly its content, that content is not archived a second time.
    private(set) var restoredDraftID: UUID?
    /// The conversation whose composer content `draft` and `pendingAttachments` hold.
    @ObservationIgnored private var composerConversationID: UUID?
    /// Composer content that could not be written to the draft archive when its conversation
    /// was left. It stays in memory, keeps its attachments referenced, and goes back into the
    /// composer when that conversation is selected again.
    @ObservationIgnored private var unarchivedComposers: [UUID: (draft: ArchivedDraft, restoredDraftID: UUID?)] = [:]

    /// True while this composer holds an unsent draft of the conversation that could not be archived.
    func holdsUnarchivedComposer(for conversationID: UUID) -> Bool {
        unarchivedComposers[conversationID] != nil
    }
    private var standaloneConversationID = UUID()
    /// Set for the store behind a window: it shows the conversation it last loaded, whatever the
    /// app-wide selection says, so each window keeps its own conversation. Otherwise (tests,
    /// before any window opens) it follows `ConversationStore.activeConversationID`.
    @ObservationIgnored private(set) var isWindowBound = false
    private var boundConversationID: UUID?
    /// The conversation `loadConversation` last loaded; nil once the window closed.
    @ObservationIgnored private(set) var lastLoadedConversationID: UUID?

    /// The conversation this store shows and acts on.
    var viewedConversationID: UUID? {
        isWindowBound ? boundConversationID : conversationStore?.activeConversationID
    }

    var viewedConversation: ConversationRecord? {
        guard let id = viewedConversationID else { return nil }
        return conversationStore?.conversations.first(where: { $0.id == id })
    }

    /// Binds the store to a window, starting from the conversation it shows now.
    func bindToWindow() {
        guard !isWindowBound else { return }
        boundConversationID = conversationStore?.activeConversationID
        isWindowBound = true
    }
    private var manualStreamingForTesting: Bool?

    var isStreaming: Bool {
        if let manual = manualStreamingForTesting { return manual }
        guard let id = viewedConversationID else {
            return runCoordinator.isActive(conversationID: standaloneConversationID)
        }
        return runCoordinator.isActive(conversationID: id)
    }

    var isPausing: Bool {
        guard let id = viewedConversationID else {
            return runCoordinator.isPausing(conversationID: standaloneConversationID)
        }
        return runCoordinator.isPausing(conversationID: id)
    }

    var isPaused: Bool {
        guard let id = viewedConversationID else {
            return runCoordinator.isPaused(conversationID: standaloneConversationID)
        }
        return runCoordinator.isPaused(conversationID: id)
    }

    var isResumingFromNewMessage: Bool {
        guard let id = viewedConversationID else {
            return runCoordinator.isResumingFromNewMessage(conversationID: standaloneConversationID)
        }
        return runCoordinator.isResumingFromNewMessage(conversationID: id)
    }

    func pause() {
        let convID = viewedConversationID ?? standaloneConversationID
        runCoordinator.pause(conversationID: convID)
    }

    func resume() {
        let convID = viewedConversationID ?? standaloneConversationID
        runCoordinator.resume(conversationID: convID)
    }

    func setStreamingForTesting(_ value: Bool) {
        self.manualStreamingForTesting = value
    }

    private let providers: ProviderStore
    private let workspace: WorkspaceStore
    private let client: any ProviderClient
    private let toolExecutor: ToolExecutor
    private let logs: DebugLogStore
    private let loopConfiguration: AgentLoopConfiguration
    private let skills: SkillStore?
    private(set) var conversation: [ChatRequestMessage] = []
    private let mcp: MCPStore?
    private let memory: MemoryStore?
    private let soul: SoulStore?
    private let modelGroups: ModelGroupStore?
    private let attachmentStore: AttachmentStore
    private let representationResolver: RepresentationResolver
    public let visionGroupResolver: VisionGroupResolver
    private weak var conversationStore: ConversationStore?
    private let titleGenerator: ConversationTitleGenerator?
    private let runtimeModelRegistry: RuntimeModelRegistry?
    private let browserSessionStore: BrowserSessionStore?
    private let hookCoordinator: HookSessionCoordinator?
    private let loopEngine: AgentLoopEngine

    init(
        providers: ProviderStore,
        workspace: WorkspaceStore,
        toolExecutor: ToolExecutor,
        client: any ProviderClient = OpenAICompatibleClient(),
        logs: DebugLogStore,
        skills: SkillStore? = nil,
        mcp: MCPStore? = nil,
        memory: MemoryStore? = nil,
        soul: SoulStore? = nil,
        modelGroups: ModelGroupStore? = nil,
        attachmentStore: AttachmentStore = AttachmentStore(),
        visionGroupResolver: VisionGroupResolver? = nil,
        representationResolver: RepresentationResolver = RepresentationResolver(),
        titleGenerator: ConversationTitleGenerator? = nil,
        runtimeModelRegistry: RuntimeModelRegistry? = nil,
        browserSessionStore: BrowserSessionStore? = nil,
        hookCoordinator: HookSessionCoordinator? = nil,
        recoveryStore: RuntimeRecoveryStore? = nil,
        loopEngine: AgentLoopEngine? = nil,
        contextLifecycle: ContextLifecycle? = nil,
        runtimeEvents: RuntimeEventStore? = nil,
        loopConfiguration: AgentLoopConfiguration = .standard,
        runCoordinator: ConversationRunCoordinator? = nil
    ) {
        self.providers = providers
        self.workspace = workspace
        self.toolExecutor = toolExecutor
        self.client = client
        self.logs = logs
        self.skills = skills
        self.mcp = mcp
        self.memory = memory
        self.soul = soul
        self.modelGroups = modelGroups
        self.attachmentStore = attachmentStore
        self.representationResolver = representationResolver
        self.titleGenerator = titleGenerator
        self.runtimeModelRegistry = runtimeModelRegistry
        self.browserSessionStore = browserSessionStore
        self.hookCoordinator = hookCoordinator
        let engine = loopEngine ?? AgentLoopEngine(client: client, logs: logs)
        self.loopEngine = engine
        self.loopConfiguration = loopConfiguration

        let resolver = visionGroupResolver ?? VisionGroupResolver(
            modelGroups: modelGroups,
            providers: providers,
            client: client,
            logs: logs
        )
        self.visionGroupResolver = resolver
        toolExecutor.setVisionGroupResolver(resolver)

        let coordinator = runCoordinator ?? ConversationRunCoordinator(
            conversationStore: nil,
            recoveryStore: recoveryStore,
            providers: providers,
            workspace: workspace,
            toolExecutor: toolExecutor,
            client: client,
            logs: logs,
            skills: skills,
            mcp: mcp,
            memory: memory,
            soul: soul,
            modelGroups: modelGroups,
            attachmentStore: attachmentStore,
            visionGroupResolver: resolver,
            titleGenerator: titleGenerator,
            runtimeModelRegistry: runtimeModelRegistry,
            browserSessionStore: browserSessionStore,
            hookCoordinator: hookCoordinator,
            loopEngine: engine,
            contextLifecycle: contextLifecycle,
            runtimeEvents: runtimeEvents,
            loopConfiguration: loopConfiguration
        )
        self.runCoordinator = coordinator
        self.interaction = ConversationInteractionService(
            runs: coordinator,
            userQuestions: toolExecutor.userQuestions,
            providers: providers,
            modelGroups: modelGroups,
            visionGroupResolver: resolver,
            logs: logs
        )
        attachRunCoordinatorListeners()
    }

    /// A store for another window. It shares this store's runs and dependencies; the transcript
    /// mirror and the composer are its own.
    func makeWindowCompanion() -> ChatStore {
        let companion = ChatStore(
            providers: providers,
            workspace: workspace,
            toolExecutor: toolExecutor,
            client: client,
            logs: logs,
            skills: skills,
            mcp: mcp,
            memory: memory,
            soul: soul,
            modelGroups: modelGroups,
            attachmentStore: attachmentStore,
            visionGroupResolver: visionGroupResolver,
            representationResolver: representationResolver,
            titleGenerator: titleGenerator,
            runtimeModelRegistry: runtimeModelRegistry,
            browserSessionStore: browserSessionStore,
            hookCoordinator: hookCoordinator,
            loopEngine: loopEngine,
            loopConfiguration: loopConfiguration,
            runCoordinator: runCoordinator
        )
        if let conversationStore { companion.setConversationStore(conversationStore) }
        if let draftArchive { companion.setDraftArchive(draftArchive) }
        if let undo { companion.setUndoCoordinator(undo) }
        companion.bindToWindow()
        return companion
    }

    /// The window closed. Its composer content is archived as a draft of its conversation, as
    /// when the window moves to another conversation; a companion also stops mirroring runs.
    func closeWindow(releasingRuns: Bool) {
        switchComposer(to: nil)
        lastLoadedConversationID = nil
        if releasingRuns {
            runSubscription?.cancel()
            runSubscription = nil
        }
    }

    func setConversationStore(_ store: ConversationStore) {
        self.conversationStore = store
        self.runCoordinator.setConversationStore(store)
        interaction.setConversationStore(store)
    }

    func setDraftArchive(_ archive: DraftArchiveStore) {
        self.draftArchive = archive
    }

    func setUndoCoordinator(_ undo: UndoCoordinator) {
        self.undo = undo
    }

    func setRunCoordinator(_ coordinator: ConversationRunCoordinator) {
        self.runCoordinator = coordinator
        interaction.setRunCoordinator(coordinator)
        if let store = conversationStore {
            self.runCoordinator.setConversationStore(store)
        }
        attachRunCoordinatorListeners()
    }

    private func attachRunCoordinatorListeners() {
        runSubscription?.cancel()
        runSubscription = runCoordinator.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case .outcomeHandoff(let conversationID, let handoff):
                outcomeHandoffsByConversation[conversationID] = handoff
            case .providerHistoryUpdated(let conversationID, let history):
                guard isViewing(conversationID: conversationID) else { return }
                conversation = history
            case .runFinished(let conversationID, _, let status, let error):
                guard isViewing(conversationID: conversationID) else { return }
                refreshVisibleRunMessages(conversationID: conversationID)
                if status == .failed, let error {
                    errorMessage = error
                }
            case .reasoningDelta(let conversationID, _, _), .textDelta(let conversationID, _, _):
                scheduleStreamedTextRefresh(conversationID: conversationID)
            default:
                refreshVisibleRunMessages(conversationID: event.conversationID)
            }
        }
    }

    /// Streamed text reaches the transcript at most once a frame of a 30 fps cap (Ink, Claude
    /// Code's renderer, caps its frames the same way), not once a token. Every refresh lays out
    /// the whole transcript: in a long run with its execution history open that took 5–9 ms, and
    /// a provider streaming 100+ tokens a second left scrolling no frames (2026-10-22).
    @ObservationIgnored private var streamedTextRefresh: Task<Void, Never>?
    static let streamedTextRefreshInterval: Duration = .milliseconds(33)

    private func scheduleStreamedTextRefresh(conversationID: UUID) {
        guard isViewing(conversationID: conversationID), streamedTextRefresh == nil else { return }
        streamedTextRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamedTextRefreshInterval)
            guard !Task.isCancelled, let self else { return }
            self.streamedTextRefresh = nil
            self.refreshVisibleRunMessages(conversationID: conversationID)
        }
    }

    /// ConversationRunCoordinator owns the authoritative message records while
    /// a run is active. Mirroring that list preserves stable tool-record IDs in
    /// the visible ChatStore instead of recreating parallel UI-only records.
    private func refreshVisibleRunMessages(conversationID: UUID) {
        guard isViewing(conversationID: conversationID) else { return }
        // Any other change shows the text streamed so far with it.
        streamedTextRefresh?.cancel()
        streamedTextRefresh = nil
        if let runMessages = runCoordinator.activeRunMessages(for: conversationID) {
            messages = runMessages
        } else if let convMessages = conversationStore?.conversations.first(where: { $0.id == conversationID })?.messages {
            messages = convMessages
        }
    }

    private func isViewing(conversationID: UUID) -> Bool {
        if let activeID = viewedConversationID {
            return activeID == conversationID
        }
        return conversationID == standaloneConversationID
    }

    var requiresImageInput: Bool {
        pendingAttachments.contains(where: { $0.kind == .image })
            || messages.contains(where: { $0.attachments.contains(where: { $0.kind == .image }) })
    }

    /// Consumes a host file only when the picker/drop boundary has already
    /// paired its exact source identity with an invocation admission.
    func addAttachment(from selection: HostFileSelection) async throws {
        guard pendingAttachments.count < AttachmentStore.maxPendingAttachments else {
            throw AttachmentStoreError.maxPendingAttachmentsExceeded(AttachmentStore.maxPendingAttachments)
        }
        let attachment = try await importAttachment(from: selection, conversationID: viewedConversationID ?? standaloneConversationID)
        do {
            try validatePendingTotal(adding: attachment)
        } catch {
            attachmentStore.deleteAttachment(attachment)
            throw error
        }
        pendingAttachments.append(attachment)
        logs.info("Chat", "Added attachment '\(attachment.filename)' (\(attachment.byteCount) bytes).")
    }

    /// Stores a file the owner uploaded through Remote Access as an attachment, through the same
    /// import (image normalization, size limits) as a file picked on the Mac. Not added to this composer.
    func importRemoteUpload(at url: URL, conversationID: UUID?) async throws -> ChatAttachment {
        try await importAttachment(from: .uploadedByOwner(url: url), conversationID: conversationID ?? UUID())
    }

    /// Stores a host file as an attachment without adding it to the composer.
    private func importAttachment(from selection: HostFileSelection, conversationID: UUID) async throws -> ChatAttachment {
        let source = URL(fileURLWithPath: selection.source.locator)
        let classification = AttachmentClassifier.classify(url: source)
        let attachment: ChatAttachment
        if classification.kind == .image,
           ["image/jpeg", "image/png"].contains(classification.mimeType) {
            let requirement = RepresentationRequirement(
                acceptedMIMETypes: ["image/jpeg", "image/png"],
                budget: ConversionBudget(maxInputBytes: AttachmentStore.maxSourceImageBytes),
                requiredProfile: ChatImageRepresentationProfile.normalizedV1
            )
            let result = await representationResolver.resolveDirectUse(
                ref: selection.source,
                requirement: requirement,
                requestingConversationID: conversationID,
                hostFileAdmission: selection.admission
            )
            guard case .directUse(let direct, _) = result else {
                throw ConversionExecutionError(reason: result.attempt.failureReason ?? "Image import could not establish the required representation.", cleanupStatus: result.cleanupStatus)
            }
            attachment = try attachmentStore.commitNormalizedImage(direct, originalFilename: source.lastPathComponent)
        } else {
            // Existing non-JPEG/PNG image formats remain on the compatibility
            // path, which delegates to the same normalization kernel.
            attachment = try attachmentStore.saveFile(url: source)
        }
        return attachment
    }

    // MARK: - @-mentioned images

    /// Image files the text names as `@/absolute/path` or `@~/path` (Claude Code's @-mention).
    /// A mention runs to the end of its line and is shortened at spaces until it names an
    /// existing file, so file names with spaces and text after the path both work.
    static func mentionedImageFiles(in text: String) -> [URL] {
        var result: [URL] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var searchStart = line.startIndex
            while let at = line[searchStart...].firstIndex(of: "@") {
                defer { searchStart = line.index(after: at) }
                if at > line.startIndex, !line[line.index(before: at)].isWhitespace { continue }
                let rest = line[line.index(after: at)...]
                guard rest.hasPrefix("/") || rest.hasPrefix("~/") else { continue }
                var candidate = String(rest).trimmingCharacters(in: .whitespaces)
                while !candidate.isEmpty {
                    let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                        if AttachmentClassifier.classify(url: url).kind == .image, !result.contains(url) { result.append(url) }
                        break
                    }
                    guard let space = candidate.lastIndex(where: \.isWhitespace) else { break }
                    candidate = String(candidate[..<space]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return result
    }

    /// Sends the composer content after attaching the images it names with `@<path>`, through
    /// the same intake as the file picker, so the model receives the image instead of a path it
    /// has to open itself. When neither the model nor a Vision Group takes images, the path stays
    /// text, as typed.
    ///
    /// The send belongs to the conversation, text and attachments the composer held when the user
    /// pressed send. If any of them changed while the images were being imported, nothing is sent
    /// and the imported copies are discarded.
    func sendAttachingMentionedImages(queueing: Bool) async {
        guard canSend else { return }
        let mode: InteractiveSendMode = queueing ? .queue : .steerOrSend
        let mentioned = Self.mentionedImageFiles(in: draft)
        if mentioned.isEmpty {
            submit(mode: mode, outcomeDeclaration: nil)
            return
        }
        let conversationID = viewedConversationID ?? standaloneConversationID
        if let source = interaction.modelSource(for: viewedConversationID),
           let refusal = interaction.imageInputRefusal(for: source) {
            logs.info("Chat", "Mentioned images stay as paths: \(refusal)")
            submit(mode: mode, outcomeDeclaration: nil)
            return
        }

        let composerID = composerConversationID
        let text = draft
        let attachmentIDs = pendingAttachments.map(\.id)
        isAttachingMentionedImages = true
        var imported: [ChatAttachment] = []
        for url in mentioned {
            do {
                imported.append(try await importAttachment(from: .typedByUser(url: url), conversationID: conversationID))
            } catch {
                logs.error("Chat", "Could not attach the mentioned image '\(url.lastPathComponent)': \(error.localizedDescription)")
            }
        }
        isAttachingMentionedImages = false

        let composerUnchanged = (viewedConversationID ?? standaloneConversationID) == conversationID
            && composerConversationID == composerID
            && draft == text
            && pendingAttachments.map(\.id) == attachmentIDs
        guard composerUnchanged else {
            imported.forEach { attachmentStore.deleteAttachment($0) }
            logs.info("Chat", "The composer changed while mentioned images were imported; nothing was sent.")
            if isViewing(conversationID: conversationID) {
                errorMessage = "附加图片期间输入内容有变化，未发送。请确认后再发送。"
            }
            return
        }
        for (index, attachment) in imported.enumerated() {
            do {
                guard pendingAttachments.count < AttachmentStore.maxPendingAttachments else {
                    throw AttachmentStoreError.maxPendingAttachmentsExceeded(AttachmentStore.maxPendingAttachments)
                }
                try validatePendingTotal(adding: attachment)
                pendingAttachments.append(attachment)
                logs.info("Chat", "Added attachment '\(attachment.filename)' (\(attachment.byteCount) bytes).")
            } catch {
                imported[index...].forEach { attachmentStore.deleteAttachment($0) }
                errorMessage = "图片未能附加：\(error.localizedDescription)"
                return
            }
        }
        submit(mode: mode, outcomeDeclaration: nil)
    }

    func addAttachment(_ attachment: ChatAttachment) throws {
        guard pendingAttachments.count < AttachmentStore.maxPendingAttachments else {
            throw AttachmentStoreError.maxPendingAttachmentsExceeded(AttachmentStore.maxPendingAttachments)
        }
        try validatePendingTotal(adding: attachment)
        pendingAttachments.append(attachment)
        logs.info("Chat", "Added attachment '\(attachment.filename)' (\(attachment.byteCount) bytes).")
    }

    func removeAttachment(id: UUID) {
        if let index = pendingAttachments.firstIndex(where: { $0.id == id }) {
            let removed = pendingAttachments.remove(at: index)
            if !isAttachmentReferenced(removed.id) {
                attachmentStore.deleteAttachment(removed)
            }
            logs.info("Chat", "Removed pending attachment '\(removed.filename)'.")
        }
    }

    func clearPendingAttachments() {
        let removed = pendingAttachments
        pendingAttachments.removeAll()
        for att in removed where !isAttachmentReferenced(att.id) {
            attachmentStore.deleteAttachment(att)
        }
    }

    func loadConversation(_ record: ConversationRecord) {
        if isWindowBound { boundConversationID = record.id }
        lastLoadedConversationID = record.id
        if let runMsgs = runCoordinator.activeRunMessages(for: record.id) {
            messages = runMsgs
        } else {
            messages = record.messages
        }
        errorMessage = nil
        // Reselecting or reloading the conversation the composer belongs to leaves its content alone.
        if composerConversationID != record.id {
            switchComposer(to: record.id)
        }
        rebuildRequestHistory(conversationID: record.id)
    }

    /// Moves the composer to another conversation. Its content is only cleared once it is safe:
    /// archived, already identical to an archived draft, or held in memory after a failed
    /// archive write (with the failure shown to the user).
    private func switchComposer(to nextConversationID: UUID?) {
        if draftArchive != nil, let previous = composerConversationID,
           let composerDraft = archivableComposerDraft() {
            do {
                try draftArchive?.archive(composerDraft, conversationID: previous)
            } catch {
                logs.error("Chat", "Failed to archive the composer draft of conversation '\(previous)': \(error.localizedDescription)")
                unarchivedComposers[previous] = (composerDraft, restoredDraftID)
                // The pending attachments now belong to the in-memory draft; nothing is deleted.
                pendingAttachments.removeAll()
                draft = ""
                restoredDraftID = nil
                errorMessage = "上一个会话的输入内容未能保存为草稿（\(error.localizedDescription)）。内容已暂存，回到那个会话时会放回输入框；退出 Limare 前请先处理。"
                composerConversationID = nextConversationID
                restoreUnarchivedComposer(for: nextConversationID)
                return
            }
            pendingAttachments.removeAll()
        }
        draft = ""
        clearPendingAttachments()
        restoredDraftID = nil
        composerConversationID = nextConversationID
        restoreUnarchivedComposer(for: nextConversationID)
    }

    private func restoreUnarchivedComposer(for conversationID: UUID?) {
        guard let conversationID, let held = unarchivedComposers.removeValue(forKey: conversationID) else { return }
        draft = held.draft.text
        pendingAttachments = held.draft.attachments
        restoredDraftID = held.restoredDraftID
    }

    /// Replaces the composer text on behalf of the app (for example a prepared handoff
    /// instruction). Content the user typed is archived first instead of being overwritten.
    @discardableResult
    func replaceComposerText(_ text: String) -> Bool {
        if let archive = draftArchive,
           let conversationID = composerConversationID ?? viewedConversationID,
           let composerDraft = archivableComposerDraft() {
            do {
                try archive.archive(composerDraft, conversationID: conversationID)
            } catch {
                errorMessage = "无法保存当前输入内容，未替换：\(error.localizedDescription)"
                return false
            }
            pendingAttachments.removeAll()
            restoredDraftID = nil
        }
        draft = text
        return true
    }

    /// Rebuilds the provider request history from the visible transcript.
    private func rebuildRequestHistory(conversationID: UUID) {
        conversation.removeAll()

        let systemMessage = ChatRequestMessage(role: "system", content: authoritativeInitialSystemPrompt(for: conversationID))
        conversation.append(systemMessage)

        for msg in messages {
            switch msg.role {
            case .user:
                if msg.attachments.isEmpty {
                    conversation.append(ChatRequestMessage(role: "user", content: msg.requestText))
                } else {
                    var parts: [ChatContentPart] = []
                    if !msg.content.isEmpty {
                        parts.append(.text(msg.requestText))
                    }
                    for att in msg.attachments {
                        parts.append(.attachment(att))
                    }
                    if parts.isEmpty {
                        conversation.append(ChatRequestMessage(role: "user", content: msg.content))
                    } else {
                        conversation.append(ChatRequestMessage(role: "user", content: .parts(parts)))
                    }
                }
            case .assistant:
                let providerCalls = msg.toolCalls.map { tc in
                    ProviderToolCall(
                        id: tc.providerCallID,
                        function: .init(name: tc.name, arguments: tc.input)
                    )
                }
                conversation.append(
                    .assistant(
                        content: msg.content,
                        reasoningContent: msg.reasoningContent,
                        toolCalls: providerCalls,
                        responsesReasoningEcho: msg.responsesReasoningEcho, nativeProtocolMetadata: msg.nativeProtocolMetadata
                    )
                )
                for tc in msg.toolCalls where !tc.output.isEmpty {
                    conversation.append(.tool(callID: tc.providerCallID, content: tc.output))
                }
            }
        }
    }

    var canSend: Bool {
        guard !isAttachingMentionedImages else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
    }

    func send() {
        submit(mode: .steerOrSend, outcomeDeclaration: nil)
    }

    /// Explicit outcome-aware run entry.
    ///
    /// Requires an idle conversation and an admitted run. An explicit outcome declaration is
    /// never silently downgraded to a steer, a queue entry, or an ordinary send: if the run
    /// cannot start, this returns `false` and no message is committed.
    @discardableResult
    func sendOutcomeRun(declaration: OutcomeRunDeclaration) -> Bool {
        let conversationID = viewedConversationID ?? standaloneConversationID
        guard canSend, runCoordinator.canStartRun(conversationID: conversationID) else { return false }
        return submit(mode: .steerOrSend, outcomeDeclaration: declaration)
    }

    /// Records a verification result against the active run of a conversation.
    /// Returns false if no active non-terminal run exists, or if the declaration rejects the result.
    @discardableResult
    func recordVerificationResult(conversationID: UUID, result: VerificationResult) -> Bool {
        guard let activeRun = runCoordinator.run(for: conversationID), !activeRun.status.isTerminal else { return false }
        return runCoordinator.recordVerificationResult(runID: activeRun.id, result: result)
    }

    /// Records a verification result against the current active conversation run.
    @discardableResult
    func recordVerificationResult(result: VerificationResult) -> Bool {
        let conversationID = viewedConversationID ?? standaloneConversationID
        return recordVerificationResult(conversationID: conversationID, result: result)
    }

    /// Records an atomic mechanical verification result and evidence receipt pair against the active run of a conversation.
    /// Returns false if no active non-terminal run exists, or if atomic admission rejects the pair.
    @discardableResult
    func recordMechanicalVerification(conversationID: UUID, result: VerificationResult, receipt: EvidenceReceipt) -> Bool {
        guard let activeRun = runCoordinator.run(for: conversationID), !activeRun.status.isTerminal else { return false }
        return runCoordinator.recordMechanicalVerification(runID: activeRun.id, verificationResult: result, evidenceReceipt: receipt)
    }

    /// Records an atomic mechanical verification result and evidence receipt pair against the current active conversation run.
    @discardableResult
    func recordMechanicalVerification(result: VerificationResult, receipt: EvidenceReceipt) -> Bool {
        let conversationID = viewedConversationID ?? standaloneConversationID
        return recordMechanicalVerification(conversationID: conversationID, result: result, receipt: receipt)
    }

    /// Records an atomic semantic verification result and specialist receipt pair against the active run of a conversation.
    /// Returns false if no active non-terminal run exists, or if atomic admission rejects the pair (EC-C01).
    @discardableResult
    func recordSemanticVerification(
        conversationID: UUID,
        result: VerificationResult,
        receipt: EvidenceReceipt,
        artifactStore: ArtifactStore? = nil
    ) -> Bool {
        guard let activeRun = runCoordinator.run(for: conversationID), !activeRun.status.isTerminal else { return false }
        return runCoordinator.recordSemanticVerification(
            runID: activeRun.id,
            verificationResult: result,
            specialistReceipt: receipt,
            artifactStore: artifactStore
        )
    }

    /// Records an atomic semantic verification result and specialist receipt pair against the current active conversation run (EC-C01).
    @discardableResult
    func recordSemanticVerification(
        result: VerificationResult,
        receipt: EvidenceReceipt,
        artifactStore: ArtifactStore? = nil
    ) -> Bool {
        let conversationID = viewedConversationID ?? standaloneConversationID
        return recordSemanticVerification(
            conversationID: conversationID,
            result: result,
            receipt: receipt,
            artifactStore: artifactStore
        )
    }

    func queue() {
        submit(mode: .queue, outcomeDeclaration: nil)
    }

    /// Admits an interactive input. Returns `true` only when the input was either attached to a
    /// live run (ordinary steer/queue) or durably admitted and handed to `startRun`.
    /// An explicit outcome declaration is never downgraded into steer/queue.
    @discardableResult
    private func submit(mode: InteractiveSendMode, outcomeDeclaration: OutcomeRunDeclaration?) -> Bool {
        guard viewedConversation?.isNativeDelegationChild != true else {
            errorMessage = "Native Child history 由独立运行维护；请从父会话发送 steer 或 continue。"
            return false
        }
        guard canSend else { return false }
        errorMessage = nil

        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = pendingAttachments
        let targetConversationID = viewedConversationID ?? standaloneConversationID
        let input = ConversationInteractionService.Input(
            conversationID: targetConversationID,
            text: draft,
            attachments: attachmentsToSend,
            mode: mode == .queue ? .queue : .steerOrSend,
            outcomeDeclaration: outcomeDeclaration,
            // The in-memory transcript stands in only when there is no ConversationStore at all.
            unpersistedTranscript: conversationStore == nil ? messages : nil
        )

        switch interaction.submit(input) {
        case .steered, .queued, .compacting:
            clearSentComposer()
            return true
        case .started:
            showAdmittedInput(conversationID: targetConversationID, prompt: prompt, attachments: attachmentsToSend)
            return true
        case .committedNotStarted:
            showAdmittedInput(conversationID: targetConversationID, prompt: prompt, attachments: attachmentsToSend)
            // A run that failed while starting has already reported its own error.
            if outcomeDeclaration != nil && errorMessage == nil {
                errorMessage = "The explicit outcome run was not admitted because this conversation is busy."
            }
            return false
        case .refused(let refusal):
            errorMessage = Self.message(for: refusal)
            return false
        }
    }

    /// The input is durable: show it, clear the composer, and extend the cached provider request
    /// history the way a reload would build it.
    private func showAdmittedInput(conversationID: UUID, prompt: String, attachments: [ChatAttachment]) {
        messages = runCoordinator.conversationMessages(for: conversationID)
        clearSentComposer()

        let systemMessage = ChatRequestMessage(role: "system", content: authoritativeInitialSystemPrompt(for: conversationID))
        if conversation.isEmpty {
            conversation.append(systemMessage)
        } else {
            conversation[0] = systemMessage
        }

        if !attachments.isEmpty {
            var parts: [ChatContentPart] = []
            if !prompt.isEmpty {
                parts.append(.text(prompt))
            }
            for att in attachments {
                parts.append(.attachment(att))
            }
            conversation.append(ChatRequestMessage(role: "user", content: .parts(parts)))
        } else {
            conversation.append(ChatRequestMessage(role: "user", content: prompt))
        }
    }

    /// Starts the Compact command on the active conversation (see
    /// `ConversationInteractionService.compact`). Refused while a run works on it.
    @discardableResult
    func compactConversation() -> Bool {
        let conversationID = viewedConversationID ?? standaloneConversationID
        if case .refused(let refusal) = interaction.compact(conversationID: conversationID) {
            errorMessage = Self.message(for: refusal)
            return false
        }
        errorMessage = nil
        return true
    }

    private func clearSentComposer() {
        draft = ""
        pendingAttachments.removeAll()
        consumeRestoredDraft()
    }

    static func message(for refusal: ConversationInteractionService.Refusal) -> String? {
        refusal.errorDescription
    }

    private func validatePendingTotal(adding attachment: ChatAttachment) throws {
        let total = pendingAttachments.reduce(Int64(attachment.byteCount)) { $0 + Int64($1.byteCount) }
        guard total <= AttachmentStore.maxAttachmentsPerMessageBytes else {
            throw AttachmentStoreError.totalSizeExceeded(total, maxBytes: AttachmentStore.maxAttachmentsPerMessageBytes)
        }
    }

    func stop() {
        let convID = viewedConversationID ?? standaloneConversationID
        runCoordinator.stop(conversationID: convID)
    }

    func waitForStreaming() async {
        if let convID = viewedConversationID {
            await runCoordinator.waitForRun(conversationID: convID)
        } else {
            await runCoordinator.waitForRun(conversationID: standaloneConversationID)
        }
    }

    func clear() {
        if isStreaming {
            return
        }
        let archived = draftArchive?.referencedAttachmentIDs ?? []
        for msg in messages {
            for att in msg.attachments where !archived.contains(att.id) {
                attachmentStore.deleteAttachment(att)
            }
        }
        let conversationID = viewedConversationID ?? standaloneConversationID
        runCoordinator.discardInteractiveInputs(conversationID: conversationID)
        clearPendingAttachments()
        messages.removeAll()
        conversation.removeAll()
        errorMessage = nil
        browserSessionStore?.resetSession(ownedBy: conversationID)
        runCoordinator.resetForConversationBoundary(leaving: conversationID)
        runCoordinator.computerUseAppAuthorization?.forget(conversationID: conversationID)
        runCoordinator.subagents?.conversationCleared(conversationID)
        if let convStore = conversationStore, let activeID = viewedConversationID {
            convStore.updateConversationMessages(id: activeID, messages: [])
            if let hookCoordinator {
                let effectiveURL = convStore.effectiveWorkingDirectory(for: activeID)
                Task {
                    _ = await hookCoordinator.onSessionStart(conversationID: activeID, source: "clear", model: nil, workspaceURL: effectiveURL)
                }
            }
        }
        logs.info("Chat", "Cleared current conversation messages.")
    }

    // MARK: - Retracting the Last User Message

    /// The user message that can be retracted right now, if any: the last one, while no run,
    /// queued input or child task is pending. Mirrors the coordinator's authoritative check.
    var retractableUserMessageID: UUID? {
        guard draftArchive != nil, !isStreaming,
              let conversationID = viewedConversationID,
              let candidate = messages.last(where: \.isUserPrompt),
              undo?.openPlan(for: conversationID) == nil,
              runCoordinator.retractionRefusal(conversationID: conversationID, messageID: candidate.id) == nil else {
            return nil
        }
        return candidate.id
    }

    // MARK: - Undo (files and message)

    enum UndoOutcome: Equatable {
        /// Files (if any) restored and the message retracted.
        case completed
        /// Conflicts or missing backups block the file restore; nothing changed.
        case blocked
        /// Some files could not be restored; the open plan waits for a decision.
        case partiallyFailed
        /// Files are restored but the message could not be retracted; the plan stays open.
        case retractionPending
        /// Refused before anything changed (see `errorMessage`).
        case refused
    }

    /// What undoing the message would do to files. Nil when undo is unavailable.
    func undoPreview(for messageID: UUID, includeLeftovers: Bool = false) -> UndoPreview? {
        guard let undo, let conversationID = viewedConversationID else { return nil }
        return undo.preview(conversationID: conversationID, messageID: messageID, includeLeftovers: includeLeftovers)
    }

    /// The unfinished undo of the active conversation. Offered even with the switch off, so an
    /// undo interrupted before the switch was turned off can still be finished or cancelled.
    var openUndoPlan: UndoRestorePlan? {
        guard let conversationID = viewedConversationID else { return nil }
        return undo?.openPlan(for: conversationID)
    }

    /// Undoes the last user message: restores the files its turn changed (when `restoreFiles`),
    /// then retracts the message. Files are restored first so a failure never leaves the
    /// message gone while its changes stay unreviewable.
    @discardableResult
    func undoLastUserMessage(_ messageID: UUID, restoreFiles: Bool, includeLeftovers: Bool = false, optionalPaths: Set<String> = []) -> UndoOutcome {
        guard let conversationID = viewedConversationID else { return .refused }
        if let refusal = runCoordinator.retractionRefusal(conversationID: conversationID, messageID: messageID) {
            errorMessage = Self.retractionMessage(for: refusal)
            return .refused
        }
        guard restoreFiles, let undo else {
            return retractLastUserMessage(messageID) ? .completed : .refused
        }
        guard undo.openPlan(for: conversationID) == nil else {
            errorMessage = undo.admissionHoldReason(conversationID: conversationID)
            return .refused
        }
        let preview = undo.preview(conversationID: conversationID, messageID: messageID, includeLeftovers: includeLeftovers)
        if preview.isBlocked {
            errorMessage = preview.missingBackups.isEmpty ? "有文件在之后被修改过，不能安全恢复。" : "部分备份已被清理，只能撤回消息。"
            return .blocked
        }
        guard preview.hasFileChanges else {
            return retractLastUserMessage(messageID) ? .completed : .refused
        }
        guard !preview.willRestore.isEmpty || !optionalPaths.isEmpty else {
            return retractLastUserMessage(messageID) ? .completed : .refused
        }
        let plan: UndoRestorePlan
        do {
            plan = try undo.restore(preview, selectedOptionalPaths: optionalPaths)
        } catch {
            errorMessage = (undo.openPlan(for: conversationID) == nil ? "无法开始恢复文件：" : "恢复已暂停：") + error.localizedDescription
            return undo.openPlan(for: conversationID) == nil ? .refused : .partiallyFailed
        }
        return finishUndo(plan)
    }

    /// Resolves the open undo of the active conversation: retry the failed steps (or, once the
    /// files are restored, the message retraction), keep what was restored and retract, or
    /// cancel — stop here, keep the message, leave every file as it now is.
    @discardableResult
    func resolveOpenUndo(_ action: UndoCoordinator.ResolveAction) -> UndoOutcome {
        guard let undo, let plan = openUndoPlan else { return .refused }
        if plan.phase == .filesRestored, action != .cancel {
            return finishUndo(plan)
        }
        let resolved: UndoRestorePlan
        do {
            guard let result = try undo.resolve(plan.id, action: action) else { return .refused }
            resolved = result
        } catch {
            errorMessage = error.localizedDescription
            return plan.phase == .filesRestored ? .retractionPending : .partiallyFailed
        }
        if resolved.phase == .cancelled {
            errorMessage = nil
            return .refused
        }
        return finishUndo(resolved)
    }

    private func finishUndo(_ plan: UndoRestorePlan) -> UndoOutcome {
        switch plan.phase {
        case .partiallyFailed:
            errorMessage = "有 \(plan.failedSteps.count) 个文件未能恢复。"
            return .partiallyFailed
        case .filesRestored:
            let stillPresent = conversationStore?.conversations.first(where: { $0.id == plan.conversationID })?
                .messages.contains(where: { $0.id == plan.messageID }) ?? false
            // The retraction may already be committed (a closing that could not be saved).
            guard !stillPresent || retractLastUserMessage(plan.messageID, allowingOpenUndoPlan: plan.id) else {
                return .retractionPending
            }
            do {
                try undo?.complete(plan.id)
            } catch {
                errorMessage = "消息已撤回，但撤销记录未能保存：\(error.localizedDescription)"
                return .retractionPending
            }
            return .completed
        default:
            return .refused
        }
    }

    /// Startup: commits the message retraction of an undo whose files were restored before the
    /// app stopped. The message goes to the draft archive; the composer is not touched.
    func commitPendingUndoRetraction(_ plan: UndoRestorePlan) {
        guard let undo, let archive = draftArchive else { return }
        let transcript = conversationStore?.conversations.first(where: { $0.id == plan.conversationID })?.messages ?? []
        guard let target = transcript.last(where: { $0.id == plan.messageID }) else {
            // Already retracted before the stop.
            do { try undo.complete(plan.id) } catch { logs.error("Chat", "Could not close undo plan '\(plan.id)': \(error.localizedDescription)") }
            return
        }
        let retracted = ArchivedDraft(text: target.content, attachments: target.attachments, origin: .retractedMessage, sourceMessageID: target.id)
        do {
            try archive.archive(retracted, conversationID: plan.conversationID)
        } catch {
            logs.error("Chat", "Undo retraction after restart could not archive the message: \(error.localizedDescription)")
            return
        }
        do {
            _ = try runCoordinator.retractLastUserMessage(conversationID: plan.conversationID, messageID: plan.messageID)
        } catch {
            _ = try? archive.remove(draftID: retracted.id, conversationID: plan.conversationID)
            logs.error("Chat", "Undo retraction after restart failed: \(error.localizedDescription)")
            return
        }
        do { try undo.complete(plan.id) } catch { logs.error("Chat", "Could not close undo plan '\(plan.id)': \(error.localizedDescription)") }
    }

    /// Removes the last user message and every reply after it, and puts the message back in the
    /// composer. The message is archived before anything else changes, and whatever the composer
    /// held is archived rather than overwritten, so no step can lose user text. Workspace changes
    /// made by the retracted turn stay as they are.
    @discardableResult
    func retractLastUserMessage(_ messageID: UUID) -> Bool {
        retractLastUserMessage(messageID, allowingOpenUndoPlan: nil)
    }

    private func retractLastUserMessage(_ messageID: UUID, allowingOpenUndoPlan planID: UUID?) -> Bool {
        guard let archive = draftArchive,
              let conversationID = viewedConversationID else { return false }
        if let open = undo?.openPlan(for: conversationID), open.id != planID {
            errorMessage = undo?.admissionHoldReason(conversationID: conversationID)
            return false
        }
        if let refusal = runCoordinator.retractionRefusal(conversationID: conversationID, messageID: messageID) {
            errorMessage = Self.retractionMessage(for: refusal)
            return false
        }
        guard let target = conversationStore?.conversations
            .first(where: { $0.id == conversationID })?.messages
            .last(where: { $0.id == messageID }) else { return false }

        let retracted = ArchivedDraft(text: target.content, attachments: target.attachments, origin: .retractedMessage, sourceMessageID: target.id)
        var archivedIDs: [UUID] = []
        do {
            try archive.archive(retracted, conversationID: conversationID)
            archivedIDs.append(retracted.id)
            if let composerDraft = archivableComposerDraft() {
                try archive.archive(composerDraft, conversationID: conversationID)
                archivedIDs.append(composerDraft.id)
            }
            CrashInjection.point("retract.afterArchive")
            _ = try runCoordinator.retractLastUserMessage(conversationID: conversationID, messageID: messageID)
        } catch {
            for id in archivedIDs {
                _ = try? archive.remove(draftID: id, conversationID: conversationID)
            }
            if let refusal = error as? ConversationRunCoordinator.RetractionRefusal {
                errorMessage = Self.retractionMessage(for: refusal)
            } else {
                errorMessage = "撤回失败：\(error.localizedDescription)"
            }
            return false
        }

        messages = conversationStore?.conversations.first(where: { $0.id == conversationID })?.messages ?? []
        rebuildRequestHistory(conversationID: conversationID)
        outcomeHandoffsByConversation[conversationID] = nil
        errorMessage = nil
        draft = target.content
        pendingAttachments = target.attachments
        restoredDraftID = retracted.id
        composerConversationID = conversationID
        return true
    }

    static func retractionMessage(for refusal: ConversationRunCoordinator.RetractionRefusal) -> String {
        switch refusal {
        case .conversationNotFound: "找不到这个会话。"
        case .nativeChildConversation: "子任务会话由其运行维护，不能撤回。"
        case .notLastUserMessage: "只能撤回最后一条消息。"
        case .runActive: "运行尚未结束，不能撤回。"
        case .pendingInputs: "还有排队或插入的消息未处理，不能撤回。"
        case .childTasksActive: "子任务尚未结束，不能撤回。"
        case .stopHooksRunning: "Stop Hook 仍在执行，结束后才能撤回。"
        }
    }

    // MARK: - Draft Archive

    var archivedDrafts: [ArchivedDraft] {
        guard let conversationID = viewedConversationID else { return [] }
        return draftArchive?.drafts(for: conversationID) ?? []
    }

    /// Fills the composer from an archived draft, archiving the composer's current content first.
    /// The draft stays archived until the composer content is sent.
    @discardableResult
    func restoreArchivedDraft(_ draftID: UUID) -> Bool {
        guard let archive = draftArchive, let conversationID = viewedConversationID,
              let entry = archive.draft(id: draftID, conversationID: conversationID) else { return false }
        if let composerDraft = archivableComposerDraft() {
            do {
                try archive.archive(composerDraft, conversationID: conversationID)
            } catch {
                errorMessage = "无法保存当前草稿：\(error.localizedDescription)"
                return false
            }
        }
        let available = entry.attachments.filter { attachment in
            (try? attachmentStore.fileURL(for: attachment)).map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        draft = entry.text
        pendingAttachments = available
        restoredDraftID = entry.id
        composerConversationID = conversationID
        let missing = entry.attachments.count - available.count
        errorMessage = missing > 0 ? "有 \(missing) 个附件已不存在，其余内容已恢复。" : nil
        return true
    }

    func deleteArchivedDraft(_ draftID: UUID) {
        guard let archive = draftArchive, let conversationID = viewedConversationID else { return }
        do {
            guard let removed = try archive.remove(draftID: draftID, conversationID: conversationID) else { return }
            if restoredDraftID == draftID { restoredDraftID = nil }
            releaseAttachments(of: [removed])
        } catch {
            errorMessage = "无法删除草稿：\(error.localizedDescription)"
        }
    }

    /// Drops a deleted conversation's archive and the attachments only it referenced.
    func discardArchivedDrafts(conversationID: UUID) {
        guard let archive = draftArchive else { return }
        releaseAttachments(of: archive.removeAll(conversationID: conversationID))
    }

    /// The composer's content as a draft worth keeping: non-empty, and not merely the unchanged
    /// content of the archived draft it was restored from.
    private func archivableComposerDraft() -> ArchivedDraft? {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty else { return nil }
        if let restoredDraftID,
           let conversationID = composerConversationID ?? viewedConversationID,
           let source = draftArchive?.draft(id: restoredDraftID, conversationID: conversationID),
           source.matches(text: draft, attachments: pendingAttachments) {
            return nil
        }
        return ArchivedDraft(text: draft, attachments: pendingAttachments, origin: .composerDraft)
    }

    /// Sending the composer content uses up the archived draft it was restored from.
    private func consumeRestoredDraft() {
        guard let draftID = restoredDraftID else { return }
        restoredDraftID = nil
        guard let archive = draftArchive,
              let conversationID = composerConversationID ?? viewedConversationID,
              let removed = try? archive.remove(draftID: draftID, conversationID: conversationID) else { return }
        releaseAttachments(of: [removed])
    }

    /// Deletes the attachment files of discarded drafts that nothing else refers to.
    private func releaseAttachments(of drafts: [ArchivedDraft]) {
        for attachment in drafts.flatMap(\.attachments) where !isAttachmentReferenced(attachment.id) {
            attachmentStore.deleteAttachment(attachment)
        }
    }

    private func isAttachmentReferenced(_ id: UUID) -> Bool {
        func contains(_ list: [ChatAttachment]) -> Bool { list.contains { $0.id == id } }
        if contains(pendingAttachments) { return true }
        if unarchivedComposers.values.contains(where: { contains($0.draft.attachments) }) { return true }
        if draftArchive?.referencedAttachmentIDs.contains(id) == true { return true }
        if runCoordinator.queuedInputs.values.joined().contains(where: { contains($0.message.attachments) }) { return true }
        if messages.contains(where: { contains($0.attachments) }) { return true }
        return conversationStore?.conversations.contains { $0.messages.contains { contains($0.attachments) } } == true
    }

    func markLastStreamingMessageFailed(fallback: String) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant && $0.state == .streaming }) else { return }
        messages[index].state = .failed
        if messages[index].content.isEmpty, messages[index].toolCalls.isEmpty {
            messages[index].content = fallback
        }
    }

    private func authoritativeInitialSystemPrompt(for conversationID: UUID) -> String {
        let effectiveURL = conversationStore?.effectiveWorkingDirectory(for: conversationID) ?? workspace.url
        return runCoordinator.computeSystemPrompt(for: conversationID, workspaceURL: effectiveURL)
    }

    static func sanitizedToolInput(_ call: ProviderToolCall) -> String {
        if call.function.name == "shell_execute",
           let data = call.function.arguments.data(using: .utf8),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let environment = object["environment"] as? [String: Any] {
                object["environment"] = environment.mapValues { _ in "••••" }
            }
            if let sanitized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let result = String(data: sanitized, encoding: .utf8) {
                return result
            }
            return "{\"environment\":\"values hidden\"}"
        }
        if call.function.name == "browser_use",
           let data = call.function.arguments.data(using: .utf8),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["text"] != nil {
                object["text"] = "••••"
            }
            if let rawURL = object["url"] as? String,
               let comp = URLComponents(string: rawURL),
               let scheme = comp.scheme, let host = comp.host {
                var safeComp = URLComponents()
                safeComp.scheme = scheme
                safeComp.host = host
                safeComp.path = comp.path
                if let port = comp.port { safeComp.port = port }
                object["url"] = safeComp.string ?? "\(scheme)://\(host)\(comp.path)"
            }
            if let sanitized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
               let result = String(data: sanitized, encoding: .utf8) {
                return result
            }
        }
        return call.function.arguments
    }
}
