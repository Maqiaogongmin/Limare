import Foundation

/// The one admission path for user input to a conversation: send, steer, queue and the
/// composer commands ("/compact").
///
/// The Mac composer and Remote submit through the same function, so both get the same model
/// choice, capability check, hold check, steer/queue routing, durable commit and commands. It keeps no
/// state of its own: the transcript stays with ConversationStore, the run and its queue with
/// ConversationRunCoordinator, the model choice with ProviderStore and ModelGroupStore.
/// Composer content, @-mentioned files and error wording stay with the caller.
@MainActor
final class ConversationInteractionService {
    enum Mode: Equatable, Sendable {
        /// Steer the active run, or start a run when the conversation is idle.
        case steerOrSend
        /// Queue behind the active run, or start a run when the conversation is idle.
        case queue
    }

    struct Input {
        /// The conversation to submit to. Nil creates a background conversation (in `projectID`)
        /// for this input; it never selects it in the Mac UI.
        var conversationID: UUID?
        var projectID: UUID?
        var text: String
        /// Attachments the caller has already taken in (the Mac file picker). Their files stay
        /// owned by the caller until the input is admitted.
        var attachments: [ChatAttachment]
        var mode: Mode
        /// Only when creating a conversation (`conversationID` nil): its model and thinking level,
        /// chosen before it exists. An existing conversation keeps its own (ConversationStore).
        var modelSource: ConversationModelSource?
        var thinkingLevelOverride: ThinkingLevel?
        var outcomeDeclaration: OutcomeRunDeclaration?
        /// Only for a ChatStore that has no ConversationStore at all: the transcript of its
        /// in-memory conversation. With a ConversationStore it must be nil, so an id the store
        /// does not hold is refused instead of running without a durable commit.
        var unpersistedTranscript: [ChatMessage]?
        /// Passed to `ConversationRunCoordinator.startRun`: a synchronous, throwing write of the
        /// admitted run's identity, made before the run's execution Task exists. Nil for every
        /// interactive caller.
        var onRunAdmitted: ((_ conversationID: UUID, _ runID: UUID) throws -> Void)?

        init(
            conversationID: UUID?,
            projectID: UUID? = nil,
            text: String,
            attachments: [ChatAttachment] = [],
            mode: Mode,
            modelSource: ConversationModelSource? = nil,
            thinkingLevelOverride: ThinkingLevel? = nil,
            outcomeDeclaration: OutcomeRunDeclaration? = nil,
            unpersistedTranscript: [ChatMessage]? = nil,
            onRunAdmitted: ((_ conversationID: UUID, _ runID: UUID) throws -> Void)? = nil
        ) {
            self.conversationID = conversationID
            self.projectID = projectID
            self.text = text
            self.attachments = attachments
            self.mode = mode
            self.modelSource = modelSource
            self.thinkingLevelOverride = thinkingLevelOverride
            self.outcomeDeclaration = outcomeDeclaration
            self.unpersistedTranscript = unpersistedTranscript
            self.onRunAdmitted = onRunAdmitted
        }
    }

    enum Admission: Equatable {
        /// Added to the active run; it reaches the model at the run's next safe boundary.
        case steered(conversationID: UUID, messageID: UUID)
        /// Persisted in the conversation's queue; it runs after the active run.
        case queued(conversationID: UUID, messageID: UUID)
        /// Durably committed and a run was admitted for it and is live.
        case started(conversationID: UUID, runID: UUID, messageID: UUID)
        /// Durably committed (and kept), but no live run: the coordinator did not admit one,
        /// or the run failed while starting (for example its recovery marker could not be saved).
        case committedNotStarted(conversationID: UUID, messageID: UUID)
        /// The input was the Compact command: no message, the conversation is being compacted
        /// (`ConversationRunCoordinator.compactions` tracks it).
        case compacting(conversationID: UUID)
        /// Nothing was persisted: no message, no queue entry, no new conversation, no model source.
        case refused(Refusal)

        var conversationID: UUID? {
            switch self {
            case .steered(let id, _), .queued(let id, _), .started(let id, _, _), .committedNotStarted(let id, _), .compacting(let id): id
            case .refused: nil
            }
        }
    }

    enum Refusal: LocalizedError, Equatable {
        case empty
        case conversationNotFound
        case projectNotFound
        case nativeChild
        case noModel
        case imageInputUnsupported(String)
        /// An explicit outcome run needs an idle conversation; it is never turned into a steer or queue entry.
        case outcomeRequiresIdle
        case held(String)
        case persistenceFailed(String)
        case queuePersistenceFailed
        /// Compact needs an existing conversation with history and no run or compaction on it.
        case compactUnavailable

        /// What to tell the user; nil when the refusal needs no explanation (empty input).
        var errorDescription: String? {
            switch self {
            case .empty: nil
            case .conversationNotFound: String(localized: "This conversation can't be found.")
            case .projectNotFound: String(localized: "This project can't be found.")
            case .nativeChild: String(localized: "A subtask's history is maintained by its own run. Steer or continue it from the parent conversation.")
            case .noModel: String(localized: "No model configured. Please connect a Provider or select a Model Group in Settings.")
            case .imageInputUnsupported(let reason): reason
            case .outcomeRequiresIdle: String(localized: "Cannot start an explicit outcome run while this conversation is busy.")
            case .held(let reason): reason
            case .persistenceFailed(let reason): String(localized: "Failed to save message: \(reason)")
            case .queuePersistenceFailed: String(localized: "The queued message couldn't be saved; your input was kept.")
            case .compactUnavailable: String(localized: "Compact is available when the conversation is idle and has history.")
            }
        }
    }

    private(set) var runs: ConversationRunCoordinator
    /// The question card a steered message answers in its place.
    private let userQuestions: UserQuestionStore?
    private weak var conversationStore: ConversationStore?
    private let providers: ProviderStore
    private let modelGroups: ModelGroupStore?
    private let visionGroupResolver: VisionGroupResolver
    private let logs: DebugLogStore

    init(
        runs: ConversationRunCoordinator,
        userQuestions: UserQuestionStore? = nil,
        providers: ProviderStore,
        modelGroups: ModelGroupStore?,
        visionGroupResolver: VisionGroupResolver,
        logs: DebugLogStore
    ) {
        self.runs = runs
        self.userQuestions = userQuestions
        self.providers = providers
        self.modelGroups = modelGroups
        self.visionGroupResolver = visionGroupResolver
        self.logs = logs
    }

    func setConversationStore(_ store: ConversationStore) {
        conversationStore = store
    }

    func setRunCoordinator(_ coordinator: ConversationRunCoordinator) {
        runs = coordinator
    }

    // MARK: - Model

    /// The model source a send to `conversationID` would use now (the composer shows the same one).
    func modelSource(for conversationID: UUID?) -> ConversationModelSource? {
        ModelChoiceCatalog.currentModelSource(conversation: conversationID.flatMap(record(for:)), modelGroups: modelGroups, providers: providers)
    }

    /// Whether `modelSource` can serve a chat run now: a chat-eligible direct model, or a Model
    /// Group with at least one usable member (the eligibility the composer offers by).
    func isModelUsable(_ modelSource: ConversationModelSource) -> Bool {
        switch modelSource {
        case .direct(let providerID, let modelID):
            return ModelGroupStore.evaluateMemberEligibility(
                entryId: ModelGroup.makeEntryId(providerID: providerID, modelID: modelID),
                providers: providers.providers
            ).isChatEligible
        case .group(let groupID):
            guard let modelGroups, let group = modelGroups.group(for: groupID) else { return false }
            return !modelGroups.availableEntries(for: group, providers: providers.providers).isEmpty
        }
    }

    /// Why images cannot be sent to `modelSource`, if they cannot: neither the model nor a
    /// usable Vision Group takes image input.
    func imageInputRefusal(for modelSource: ConversationModelSource) -> String? {
        let usableVisionGroup = visionGroupResolver.hasExecutableCandidate
        switch modelSource {
        case .direct(let pID, let mID):
            guard let prov = providers.providers.first(where: { $0.id == pID }),
                  let model = prov.models.first(where: { $0.id == mID }) else {
                return String(localized: "Configured model not found.")
            }
            guard model.modality?.contains(.imageInput) != true, !usableVisionGroup else { return nil }
            return model.modality == nil
                ? String(localized: "This conversation contains image input, but this model's image capability is unknown, and no usable Vision Group is available.")
                : String(localized: "This conversation contains image input that the selected model cannot process, and no usable Vision Group is available.")
        case .group(let gID):
            guard let group = modelGroups?.group(for: gID) else { return String(localized: "Model Group '\(gID)' not found.") }
            let eligible = modelGroups?.availableEntries(for: group, requireImageInput: true, providers: providers.providers) ?? []
            return eligible.isEmpty && !usableVisionGroup
                ? String(localized: "Selected Model Group has no model configured for image input, and no usable Vision Group is available.")
                : nil
        }
    }

    // MARK: - Admission

    /// Admits one user input. A refusal persists nothing; the user message is durably committed
    /// before any run starts (KERNEL-I11), and stays committed even if the run then fails to start.
    func submit(_ input: Input) -> Admission {
        let existing = input.conversationID.flatMap(record(for:))
        if input.conversationID != nil, existing == nil, input.unpersistedTranscript == nil {
            return .refused(.conversationNotFound)
        }
        // A persistent child is driven by its own run; viewing it must never start a Primary run.
        if existing?.isNativeDelegationChild == true { return .refused(.nativeChild) }

        let prompt = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !input.attachments.isEmpty else { return .refused(.empty) }

        // A command, as in Claude Code and Codex, not a message.
        if prompt == ComposerCommand.compact.invocation, input.attachments.isEmpty, input.outcomeDeclaration == nil {
            guard let conversationID = input.conversationID else { return .refused(.compactUnavailable) }
            return compact(conversationID: conversationID)
        }
        // A failed Compact's line at the end of the transcript goes once the conversation moves on.
        if let conversationID = input.conversationID { runs.dismissCompaction(conversationID: conversationID) }

        let createsConversation = input.conversationID == nil
        guard let modelSource = (createsConversation ? input.modelSource : nil) ?? modelSource(for: input.conversationID) else {
            return .refused(.noModel)
        }

        let transcript = existing?.messages ?? input.unpersistedTranscript ?? []
        let hasImages = input.attachments.contains { $0.kind == .image }
            || transcript.contains { $0.attachments.contains { $0.kind == .image } }
        if hasImages, let refusal = imageInputRefusal(for: modelSource) {
            return .refused(.imageInputUnsupported(refusal))
        }

        // A new conversation gets its id now but is created only together with its first message.
        if createsConversation {
            guard let store = conversationStore else { return .refused(.conversationNotFound) }
            if let projectID = input.projectID, !store.projects.contains(where: { $0.id == projectID }) {
                return .refused(.projectNotFound)
            }
        }
        let conversationID = input.conversationID ?? UUID()

        // Checked before the user message is committed, so a rejected declaration leaves no orphan input.
        if input.outcomeDeclaration != nil && !runs.canStartRun(conversationID: conversationID) {
            return .refused(.outcomeRequiresIdle)
        }

        let userMessage = ChatMessage(role: .user, content: prompt, attachments: input.attachments)

        // A Compact in progress: the message waits in the queue and is sent once it ends.
        if !runs.isActive(conversationID: conversationID), runs.compactions[conversationID]?.isRunning == true {
            if input.outcomeDeclaration != nil { return .refused(.outcomeRequiresIdle) }
            guard runs.enqueue(conversationID: conversationID, message: userMessage, modelSource: modelSource) else {
                return .refused(.queuePersistenceFailed)
            }
            adoptModelSource(modelSource, for: existing)
            return .queued(conversationID: conversationID, messageID: userMessage.id)
        }

        if !runs.isActive(conversationID: conversationID),
           let reason = runs.admissionHoldReason(conversationID: conversationID) {
            return .refused(.held(reason))
        }

        if runs.isActive(conversationID: conversationID) {
            // Steering is a different, non-deterministic semantic: an explicit outcome run is never absorbed by a live run.
            if input.outcomeDeclaration != nil { return .refused(.outcomeRequiresIdle) }
            switch input.mode {
            case .steerOrSend:
                let wasPausedOrPausing = runs.isPaused(conversationID: conversationID) || runs.isPausing(conversationID: conversationID)
                if runs.steer(conversationID: conversationID, message: userMessage) {
                    // Only once the message is saved: a card waiting in this run ends unanswered,
                    // and the message reaches the model right after that tool result.
                    userQuestions?.supersede(conversationID: conversationID)
                    adoptModelSource(modelSource, for: existing)
                    if wasPausedOrPausing {
                        runs.markResumingFromNewMessage(conversationID: conversationID)
                        let resumed = runs.resume(conversationID: conversationID)
                        if !resumed {
                            runs.clearResumingFromNewMessage(conversationID: conversationID)
                            logs.error("ConversationRun", "Failed to resume run for conversation '\(conversationID)' after steer admission.")
                        }
                    }
                    return .steered(conversationID: conversationID, messageID: userMessage.id)
                }
                // The run finished just before the steer could attach; the conversation is idle, so send.
            case .queue:
                guard runs.enqueue(conversationID: conversationID, message: userMessage, modelSource: modelSource) else {
                    return .refused(.queuePersistenceFailed)
                }
                adoptModelSource(modelSource, for: existing)
                return .queued(conversationID: conversationID, messageID: userMessage.id)
            }
        }

        let committedTranscript = (record(for: conversationID)?.messages ?? transcript) + [userMessage]
        do {
            if createsConversation, let store = conversationStore {
                _ = try store.createBackgroundConversation(
                    id: conversationID,
                    projectID: input.projectID,
                    modelSource: modelSource,
                    thinkingLevelOverride: input.thinkingLevelOverride,
                    messages: committedTranscript
                )
            } else if record(for: conversationID) != nil, let store = conversationStore {
                try store.commitDurableMessages(id: conversationID, messages: committedTranscript)
            }
        } catch {
            logs.error("Chat", "User admission persistence failed for conversation '\(conversationID)': \(error.localizedDescription)")
            return .refused(.persistenceFailed(error.localizedDescription))
        }
        adoptModelSource(modelSource, for: existing)

        // No fallback history: the coordinator builds the provider history from the run's
        // messages, which now hold the committed user message (buildChatRequestHistory uses a
        // fallback only for an empty transcript).
        let previousRunID = runs.run(for: conversationID)?.id
        runs.startRun(
            conversationID: conversationID,
            modelSource: modelSource,
            prompt: prompt,
            initialMessages: committedTranscript,
            outcomeDeclaration: input.outcomeDeclaration,
            onRunAdmitted: input.onRunAdmitted
        )
        // startRun can register a run and fail it synchronously (its recovery marker could not
        // be saved); only a new, non-terminal run counts as started.
        guard let run = runs.run(for: conversationID), run.id != previousRunID, !run.status.isTerminal else {
            return .committedNotStarted(conversationID: conversationID, messageID: userMessage.id)
        }
        return .started(conversationID: conversationID, runID: run.id, messageID: userMessage.id)
    }

    // MARK: - Commands

    /// Starts the Compact command (`ConversationRunCoordinator.compactConversation`) on a
    /// conversation with history and no run or compaction on it.
    func compact(conversationID: UUID) -> Admission {
        if let record = record(for: conversationID), record.isNativeDelegationChild { return .refused(.nativeChild) }
        guard !runs.conversationMessages(for: conversationID).isEmpty,
              runs.canStartRun(conversationID: conversationID),
              runs.compactions[conversationID]?.isRunning != true else {
            return .refused(.compactUnavailable)
        }
        guard let source = modelSource(for: conversationID) else { return .refused(.noModel) }
        guard runs.startCompaction(conversationID: conversationID, modelSource: source) else { return .refused(.compactUnavailable) }
        return .compacting(conversationID: conversationID)
    }

    /// A conversation without its own model source keeps the one its first admitted input used.
    private func adoptModelSource(_ source: ConversationModelSource, for record: ConversationRecord?) {
        guard let record, record.effectiveModelSource == nil else { return }
        conversationStore?.setConversationModelSource(id: record.id, source: source)
    }

    private func record(for conversationID: UUID) -> ConversationRecord? {
        conversationStore?.conversations.first { $0.id == conversationID }
    }
}
