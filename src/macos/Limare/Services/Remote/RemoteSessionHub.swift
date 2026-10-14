import Foundation
import Observation

/// The remote session: who is connected, what each client has been shown, and the frozen
/// command set. It owns no truth. Every answer is read from the canonical owners and every
/// command goes to them; what it remembers per client is only what it last sent, which can be
/// dropped at any time (the client then gets a fresh snapshot).
///
/// Two change signals feed it: the run coordinator's events for live run messages (not
/// observable), and Observation for everything the owners already publish (conversations,
/// runs, queues, approvals, run status). Both only schedule a flush; a flush compares the
/// owners' current state with what each client was last sent and sends the difference, so
/// streaming text reaches clients at most once per `flushDelay`.
///
/// A conversation is shown from its latest page on (a phone cannot take a long history in one
/// go); the client asks for older pages as its reader scrolls back, and everything it has been
/// sent stays in the diff from then on.
///
/// The one thing it holds that is not a copy of what it sent: attachments a client has uploaded
/// but not yet sent, the same as the Mac composer's pending attachments. They belong to that
/// connection and are deleted when it goes away.
@MainActor
final class RemoteSessionHub: RemoteSessionEndpoint {
    private final class Client {
        let connection: RemoteClientConnection
        let connectedAt = Date()
        var openConversationID: UUID?
        /// The open conversation's messages the client has, from the oldest page it loaded to the end.
        var sentMessages: [RemoteMessage] = []
        var sentRunState: RemoteRunState?
        var sentSummaries: [UUID: RemoteConversationSummary] = [:]
        var sentApprovals: [RemoteApproval] = []
        var sentProjects: [RemoteProjectSummary] = []
        var sentModels: RemoteModelCatalog?
        var sentSettings: RemoteConversationSettings?
        var sentCompactions: RemoteCompactions?
        /// Uploaded, not yet sent, in upload order.
        var pendingAttachments: [ChatAttachment] = []
        /// Uploads being taken in; they count against the limit until they finish.
        var uploadsInProgress = 0

        init(connection: RemoteClientConnection) {
            self.connection = connection
        }
    }

    private let conversations: ConversationStore
    private let runs: ConversationRunCoordinator
    private let interaction: ConversationInteractionService
    private let permissions: PermissionStore
    private let appAuthorization: ComputerUseAppAuthorizationStore
    private let runtimeEvents: RuntimeEventStore
    private let providers: ProviderStore
    private let modelGroups: ModelGroupStore?
    private let attachments: AttachmentStore
    private let artifacts: ArtifactStore?
    /// The Mac's attachment import (ChatStore), for a file the transport has written.
    private let importUpload: @MainActor (URL, UUID?) async throws -> ChatAttachment
    private let logs: DebugLogStore
    private let encoder = RemoteWire.makeEncoder()

    private var clients: [UUID: Client] = [:]
    private var runSubscription: ConversationRunSubscription?
    private var isStarted = false
    /// Changes with every start and stop. Observation callbacks cannot be cancelled, so one armed
    /// before a restart checks this and stops re-arming instead of running beside the new one.
    private var generation = 0
    private var flushTask: Task<Void, Never>?
    private var isFlushScheduled = false
    /// How many owner changes the hub has reacted to (tests).
    private(set) var ownerObservationCount = 0
    /// How long changes are gathered before clients hear about them.
    var flushDelay: Duration = .milliseconds(100)
    /// At most this many messages, and about this many bytes of text, go in one page.
    var pageMessageLimit = 40
    var pageByteBudget = 192 * 1024

    init(
        conversations: ConversationStore,
        runs: ConversationRunCoordinator,
        interaction: ConversationInteractionService,
        permissions: PermissionStore,
        appAuthorization: ComputerUseAppAuthorizationStore,
        runtimeEvents: RuntimeEventStore,
        providers: ProviderStore,
        modelGroups: ModelGroupStore?,
        attachments: AttachmentStore,
        artifacts: ArtifactStore? = nil,
        importUpload: @escaping @MainActor (URL, UUID?) async throws -> ChatAttachment,
        logs: DebugLogStore
    ) {
        self.conversations = conversations
        self.runs = runs
        self.interaction = interaction
        self.permissions = permissions
        self.appAuthorization = appAuthorization
        self.runtimeEvents = runtimeEvents
        self.providers = providers
        self.modelGroups = modelGroups
        self.attachments = attachments
        self.artifacts = artifacts
        self.importUpload = importUpload
        self.logs = logs
    }

    var clientCount: Int { clients.count }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        generation += 1
        runSubscription = runs.observe { [weak self] _ in self?.scheduleFlush() }
        observeOwners(generation)
    }

    func stop() {
        isStarted = false
        generation += 1
        runSubscription?.cancel()
        runSubscription = nil
        flushTask?.cancel()
        flushTask = nil
        isFlushScheduled = false
        closeAllClients()
    }

    func closeAllClients() {
        let open = clients.values
        clients.removeAll()
        for client in open {
            discardPendingAttachments(of: client)
            client.connection.close()
        }
    }

    // MARK: - RemoteSessionEndpoint

    func connect(_ connection: RemoteClientConnection) {
        let client = Client(connection: connection)
        clients[connection.id] = client
        let summaries = currentSummaries()
        let approvals = currentApprovals()
        let projects = currentProjects()
        let models = currentModels()
        client.sentSummaries = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        client.sentApprovals = approvals
        client.sentProjects = projects
        client.sentModels = models
        let bytes = send(.hello(connectionID: connection.id, conversations: summaries, projects: projects, models: models, approvals: approvals,
                                commands: RemoteProjection.commands), to: client)
        logs.info("Remote", "Client connected (\(clients.count) open); sent the list of \(summaries.count) conversations, \(bytes / 1024) KB.")
    }

    func disconnect(_ connection: RemoteClientConnection) {
        guard let client = clients.removeValue(forKey: connection.id) else { return }
        discardPendingAttachments(of: client)
        logs.info("Remote", "Client disconnected after \(Int(Date().timeIntervalSince(client.connectedAt))) s.")
    }

    func handle(_ frame: RemoteCommandFrame, from connection: RemoteClientConnection) {
        guard let client = clients[connection.id] else { return }
        logs.info("Remote", "Command \(frame.command.name)")
        let reply: (error: String?, admission: String?, conversationID: UUID?)
        switch frame.command {
        case .openConversation(let id):
            guard let record = visibleRecord(id) else {
                reply = ("conversationNotFound", nil, id)
                break
            }
            client.openConversationID = id
            let bytes = sendSnapshot(of: record, to: client)
            logs.info("Remote", "Sent the latest \(client.sentMessages.count) messages, \(bytes / 1024) KB.")
            reply = (nil, nil, id)
        case .loadEarlier(let id, let before):
            guard client.openConversationID == id, let record = visibleRecord(id) else {
                reply = ("conversationNotFound", nil, id)
                break
            }
            sendEarlier(of: record, before: before, to: client)
            reply = (nil, nil, id)
        case .submit(let conversationID, let projectID, let text, let mode, let attachmentIDs, let model, let thinking):
            reply = submit(conversationID: conversationID, projectID: projectID, text: text, mode: mode,
                           attachmentIDs: attachmentIDs, model: model, thinking: thinking, from: client)
        case .setModel(let id, let model):
            reply = withIdleRecord(id) { record in
                let source = RemoteProjection.modelSource(model)
                guard let modelGroups, ModelChoiceCatalog.offers(source, modelGroups: modelGroups, providers: providers.providers) else {
                    return "modelNotAvailable"
                }
                conversations.setConversationModelSource(id: record.id, source: source)
                return nil
            }
        case .setThinking(let id, let level):
            reply = withIdleRecord(id) { record in
                guard let thinking = thinking(for: record), thinking.options.contains(where: { $0.level == level }) else { return "levelNotAvailable" }
                conversations.setConversationThinkingLevelOverride(id: record.id, level: level.flatMap(ThinkingLevel.init(rawValue:)))
                return nil
            }
        case .discardAttachment(let id):
            if let index = client.pendingAttachments.firstIndex(where: { $0.id == id }) {
                attachments.deleteAttachment(client.pendingAttachments.remove(at: index))
                reply = (nil, nil, nil)
            } else {
                reply = ("attachmentNotFound", nil, nil)
            }
        case .stop(let id):
            reply = withRecord(id) { runs.stop(conversationID: id) }
        case .pause(let id):
            reply = withRecord(id) { runs.pause(conversationID: id) }
        case .resume(let id):
            reply = withRecord(id) { runs.resume(conversationID: id) }
        case .resumeQueue(let id):
            reply = withRecord(id) { runs.resumeQueue(conversationID: id) }
        case .clearQueue(let id):
            reply = withRecord(id) { runs.clearQueue(conversationID: id) }
        case .resolveApproval(let kind, let id, let approved):
            // Only the request the user is being shown can be answered, as on the Mac.
            switch kind {
            case .tool:
                guard permissions.pendingApproval?.id == id else {
                    reply = ("approvalNotPending", nil, nil)
                    break
                }
                permissions.resolvePendingApproval(id: id, approved: approved)
                reply = (nil, nil, nil)
            case .app:
                guard appAuthorization.pendingApproval?.id == id else {
                    reply = ("approvalNotPending", nil, nil)
                    break
                }
                appAuthorization.resolvePendingApproval(id: id, approved: approved)
                reply = (nil, nil, nil)
            }
        }
        send(.commandResult(requestID: frame.requestID, ok: reply.error == nil, error: reply.error,
                            admission: reply.admission, conversationID: reply.conversationID), to: client)
    }

    // MARK: - Flushing

    private func scheduleFlush() {
        guard isStarted, !isFlushScheduled, !clients.isEmpty else { return }
        isFlushScheduled = true
        let delay = flushDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Sends every client what changed since it was last told. Also callable directly (tests).
    func flush() {
        isFlushScheduled = false
        flushTask = nil
        guard !clients.isEmpty else { return }
        let summaries = currentSummaries()
        let summariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let approvals = currentApprovals()
        let projects = currentProjects()
        let models = currentModels()
        for client in clients.values {
            if projects != client.sentProjects {
                client.sentProjects = projects
                send(.projectsChanged(projects: projects), to: client)
            }
            if models != client.sentModels {
                client.sentModels = models
                send(.modelsChanged(models: models), to: client)
            }
            let upserts = summaries.filter { client.sentSummaries[$0.id] != $0 }
            let removed = client.sentSummaries.keys.filter { summariesByID[$0] == nil }
            if !upserts.isEmpty || !removed.isEmpty {
                client.sentSummaries = summariesByID
                send(.conversationsChanged(upserts: upserts, removed: Array(removed)), to: client)
            }
            if approvals != client.sentApprovals {
                client.sentApprovals = approvals
                send(.approvalsChanged(approvals: approvals), to: client)
            }
            if let id = client.openConversationID {
                guard let record = visibleRecord(id) else {
                    // Deleted or archived: the list update above tells the client.
                    client.openConversationID = nil
                    continue
                }
                flushConversation(record, to: client)
            }
        }
    }

    private func flushConversation(_ record: ConversationRecord, to client: Client) {
        let all = runs.conversationMessages(for: record.id)
        // Compare from the oldest message the client has; nothing before it was sent.
        guard let oldest = client.sentMessages.first,
              let start = all.firstIndex(where: { $0.id == oldest.id }) else {
            if !client.sentMessages.isEmpty || !all.isEmpty {
                sendSnapshot(of: record, to: client)
            } else {
                flushRunState(record.id, to: client)
            }
            return
        }
        let files = fileLookup(record.id)
        let messages = all[start...].map { RemoteProjection.message($0, files: files) }
        let sentIDs = client.sentMessages.map(\.id)
        guard messages.count >= sentIDs.count, messages.prefix(sentIDs.count).map(\.id) == sentIDs else {
            // Messages were removed or replaced (retraction, clear, a discarded turn): start over.
            sendSnapshot(of: record, to: client)
            return
        }
        for (index, message) in messages.enumerated()
        where index >= client.sentMessages.count || client.sentMessages[index] != message {
            send(.messageUpsert(conversationID: record.id, message: message), to: client)
        }
        client.sentMessages = messages
        flushRunState(record.id, to: client)
        let settings = settings(for: record)
        if settings != client.sentSettings {
            client.sentSettings = settings
            send(.conversationSettings(conversationID: record.id, settings: settings), to: client)
        }
        let compactions = compactions(for: record)
        if compactions != client.sentCompactions {
            client.sentCompactions = compactions
            send(.conversationCompactions(conversationID: record.id, compactions: compactions), to: client)
        }
    }

    private func flushRunState(_ conversationID: UUID, to client: Client) {
        let runState = currentRunState(conversationID)
        if runState != client.sentRunState {
            client.sentRunState = runState
            send(.runChanged(conversationID: conversationID, runState: runState), to: client)
        }
    }

    @discardableResult
    private func sendSnapshot(of record: ConversationRecord, to client: Client) -> Int {
        let all = runs.conversationMessages(for: record.id)
        let page = page(of: all, before: all.endIndex, files: fileLookup(record.id))
        let runState = currentRunState(record.id)
        let settings = settings(for: record)
        let compactions = compactions(for: record)
        client.sentMessages = page.messages
        client.sentRunState = runState
        client.sentSettings = settings
        client.sentCompactions = compactions
        return send(.conversationSnapshot(conversation: summary(record), messages: page.messages, hasEarlier: page.start > 0,
                                          runState: runState, settings: settings, compactions: compactions), to: client)
    }

    /// The page before the client's oldest message. If `before` is not that message any more (the
    /// history changed under the client), the client gets a fresh snapshot instead.
    private func sendEarlier(of record: ConversationRecord, before: UUID, to client: Client) {
        let all = runs.conversationMessages(for: record.id)
        guard client.sentMessages.first?.id == before, let end = all.firstIndex(where: { $0.id == before }) else {
            sendSnapshot(of: record, to: client)
            return
        }
        let page = page(of: all, before: end, files: fileLookup(record.id))
        client.sentMessages = page.messages + client.sentMessages
        send(.conversationEarlier(conversationID: record.id, messages: page.messages, hasEarlier: page.start > 0), to: client)
    }

    /// The messages ending just before `end`: at most `pageMessageLimit` of them and, past the
    /// first, no more than `pageByteBudget` of text.
    private func page(of all: [ChatMessage], before end: Int, files: RemoteProjection.FileLookup) -> (start: Int, messages: [RemoteMessage]) {
        var start = end
        var bytes = 0
        var messages: [RemoteMessage] = []
        while start > 0, messages.count < pageMessageLimit {
            let message = RemoteProjection.message(all[start - 1], files: files)
            let size = RemoteProjection.approximateSize(message)
            guard messages.isEmpty || bytes + size <= pageByteBudget else { break }
            bytes += size
            messages.append(message)
            start -= 1
        }
        return (start, messages.reversed())
    }

    /// Re-arms itself on every change of the observed owner state; each change schedules a flush.
    /// `armed` is the generation it belongs to: after a stop it ends instead of re-arming.
    private func observeOwners(_ armed: Int) {
        guard isStarted, armed == generation else { return }
        withObservationTracking {
            _ = conversations.conversations
            _ = conversations.projects
            _ = runs.activeRuns
            _ = runs.queuedInputs
            _ = runs.isQueueSuspended
            _ = runs.compactions
            for id in runs.activeRuns.keys { _ = runs.isPausing(conversationID: id) }
            _ = permissions.pendingApproval
            _ = appAuthorization.pendingApproval
            _ = runtimeEvents.eventsByRun
            // Everything the project list and the model menu are computed from.
            _ = currentProjects()
            _ = currentModels()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, armed == self.generation else { return }
                self.ownerObservationCount += 1
                self.scheduleFlush()
                self.observeOwners(armed)
            }
        }
    }

    // MARK: - Composer commands

    private func submit(conversationID: UUID?, projectID: UUID?, text: String, mode: RemoteCommand.SubmitMode,
                        attachmentIDs: [UUID], model: RemoteModelRef?, thinking: String?,
                        from client: Client) -> (error: String?, admission: String?, conversationID: UUID?) {
        var chosen: [ChatAttachment] = []
        for id in attachmentIDs {
            guard let attachment = client.pendingAttachments.first(where: { $0.id == id }) else { return ("attachmentNotFound", nil, conversationID) }
            chosen.append(attachment)
        }
        // A model and thinking level are chosen with the first message of a new conversation;
        // an existing one is changed with conversation.setModel / setThinking.
        var modelSource: ConversationModelSource?
        var thinkingLevel: ThinkingLevel?
        if conversationID == nil {
            if let model {
                let source = RemoteProjection.modelSource(model)
                guard let modelGroups, ModelChoiceCatalog.offers(source, modelGroups: modelGroups, providers: providers.providers) else {
                    return ("modelNotAvailable", nil, nil)
                }
                modelSource = source
            }
            if let thinking {
                let effective = modelSource ?? ModelChoiceCatalog.currentModelSource(conversation: nil, modelGroups: modelGroups, providers: providers)
                let menu = RemoteProjection.thinking(ConversationThinkingResolver.resolvePresentationState(
                    conversation: nil, modelSource: effective, providers: providers.providers, modelGroups: modelGroups))
                guard menu?.options.contains(where: { $0.level == thinking }) == true, let level = ThinkingLevel(rawValue: thinking) else {
                    return ("levelNotAvailable", nil, nil)
                }
                thinkingLevel = level
            }
        }
        let admission = interaction.submit(.init(
            conversationID: conversationID,
            projectID: projectID,
            text: text,
            attachments: chosen,
            mode: mode == .queue ? .queue : .steerOrSend,
            modelSource: modelSource,
            thinkingLevelOverride: thinkingLevel
        ))
        if admission.conversationID != nil {
            // Admitted: the attachments now belong to the message.
            client.pendingAttachments.removeAll { attachment in chosen.contains { $0.id == attachment.id } }
        }
        return Self.reply(for: admission)
    }

    /// Runs `change` on a visible conversation without a live run (the Mac composer disables its
    /// model and thinking menus while one streams).
    private func withIdleRecord(_ id: UUID, _ change: (ConversationRecord) -> String?) -> (error: String?, admission: String?, conversationID: UUID?) {
        guard let record = visibleRecord(id) else { return ("conversationNotFound", nil, id) }
        guard !runs.isActive(conversationID: id) else { return ("runActive", nil, id) }
        return (change(record), nil, id)
    }

    private func discardPendingAttachments(of client: Client) {
        for attachment in client.pendingAttachments { attachments.deleteAttachment(attachment) }
        client.pendingAttachments.removeAll()
    }

    // MARK: - Uploads

    func mayUpload(connectionID: UUID) -> Bool {
        guard let client = clients[connectionID] else { return false }
        return client.pendingAttachments.count + client.uploadsInProgress < RemoteWire.maxPendingAttachments
    }

    func receiveUpload(at file: URL, connectionID: UUID) async -> Result<RemoteAttachment, RemoteUploadError> {
        guard mayUpload(connectionID: connectionID), let client = clients[connectionID] else {
            return .failure(RemoteUploadError(code: "uploadRefused", message: "最多 \(RemoteWire.maxPendingAttachments) 个附件。"))
        }
        client.uploadsInProgress += 1
        defer { client.uploadsInProgress -= 1 }
        do {
            let attachment = try await importUpload(file, client.openConversationID)
            // The connection may have closed while the file was imported.
            guard clients[connectionID] === client else {
                attachments.deleteAttachment(attachment)
                return .failure(RemoteUploadError(code: "disconnected", message: "连接已断开。"))
            }
            client.pendingAttachments.append(attachment)
            logs.info("Remote", "Took in an uploaded \(attachment.kind.rawValue) attachment, \(attachment.byteCount / 1024) KB.")
            return .success(RemoteAttachment(id: attachment.id, filename: attachment.filename, kind: attachment.kind.rawValue, byteCount: attachment.byteCount))
        } catch {
            logs.info("Remote", "Refused an uploaded file: \(error.localizedDescription)")
            return .failure(RemoteUploadError(code: "importFailed", message: error.localizedDescription))
        }
    }

    // MARK: - Files

    /// What the cards of conversation `conversationID` name, as `RemoteProjection` needs it.
    private func fileLookup(_ conversationID: UUID) -> RemoteProjection.FileLookup {
        let workspace = conversations.effectiveWorkingDirectory(for: conversationID)
        return RemoteProjection.FileLookup(
            conversationID: conversationID,
            artifact: { [artifacts] id in
                (try? artifacts?.resolveDescriptor(artifactID: id, conversationID: conversationID))
                    .map { ($0.filename, Int($0.byteCount)) }
            },
            toolCallTarget: { call in
                ToolCallFileTargetResolver.resolveTargetURL(for: call, in: workspace)
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            }
        )
    }

    /// The file a card names, found the way the Mac's card finds it, and only within the
    /// conversation: an attachment of one of its messages, one of its artifacts (the workspace
    /// file it was registered from while that is still there), or the target of one of its file
    /// tool calls.
    func file(conversationID: UUID, source: RemoteFile.Source, id: UUID) -> RemoteServedFile? {
        guard conversations.conversations.contains(where: { $0.id == conversationID }) else { return nil }
        let messages = runs.conversationMessages(for: conversationID)
        let location: URL?
        let filename: String?
        switch source {
        case .attachment:
            let attachment = messages.lazy.flatMap(\.attachments).first { $0.id == id }
            location = attachment.flatMap { try? attachments.fileURL(for: $0) }
            filename = attachment?.filename
        case .artifact:
            let descriptor = try? artifacts?.resolveDescriptor(artifactID: id, conversationID: conversationID)
            location = descriptor.flatMap { artifactLocation($0, conversationID: conversationID) }
            filename = descriptor?.filename
        case .toolCall:
            let call = messages.lazy.flatMap(\.toolCalls).first { $0.id == id }
            location = call.flatMap { fileLookup(conversationID).toolCallTarget($0) }
            filename = location?.lastPathComponent
        }
        guard let location, let filename, FileManager.default.fileExists(atPath: location.path) else { return nil }
        let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return RemoteServedFile(location: location, filename: filename, preview: RemoteProjection.preview(of: filename, byteCount: size).preview)
    }

    /// As the Mac's `AppState.workspaceSource(ofArtifact:)`: an artifact registered from a workspace
    /// file reads as that file while it is there, else as the stored copy.
    private func artifactLocation(_ descriptor: ArtifactDescriptor, conversationID: UUID) -> URL? {
        let workspace = conversations.effectiveWorkingDirectory(for: conversationID)
        if descriptor.producerProvenance == .workspaceRegistration, let source = descriptor.workspaceProvenance,
           FileManager.default.fileExists(atPath: source.path),
           WorkspacePathResolver.isInsideWorkspace(source.standardizedFileURL.resolvingSymlinksInPath(), workspaceURL: workspace) {
            return source
        }
        return try? artifacts?.resolveFileURL(artifactID: descriptor.artifactID, conversationID: conversationID)
    }

    // MARK: - Reading the owners

    /// Projects in the Mac sidebar's order: pinned first, then the most recently updated.
    private func currentProjects() -> [RemoteProjectSummary] {
        (conversations.pinnedProjects + conversations.unpinnedProjects).map(RemoteProjection.project)
    }

    /// The Mac composer's model menu, each entry with the thinking menu a new conversation on it would have.
    private func currentModels() -> RemoteModelCatalog {
        let providerList = providers.providers
        func choice(_ source: ConversationModelSource, label: String, section: String) -> RemoteModelChoice {
            RemoteModelChoice(
                model: RemoteProjection.modelRef(source), label: label, section: section,
                thinking: RemoteProjection.thinking(ConversationThinkingResolver.resolvePresentationState(
                    conversation: nil, modelSource: source, providers: providerList, modelGroups: modelGroups))
            )
        }
        var choices: [RemoteModelChoice] = []
        if let modelGroups {
            choices += ModelChoiceCatalog.selectableGroups(modelGroups: modelGroups, providers: providerList)
                .map { choice(.group(groupID: $0.id), label: $0.name, section: "Model Groups") }
        }
        choices += ModelChoiceCatalog.visibleModelEntries(providers: providerList, current: nil)
            .map { choice(.direct(providerID: $0.providerID, modelID: $0.model.id), label: $0.model.displayName, section: $0.providerName) }
        let defaultModel = ModelChoiceCatalog.currentModelSource(conversation: nil, modelGroups: modelGroups, providers: providers)
        return RemoteModelCatalog(choices: choices, defaultModel: defaultModel.map(RemoteProjection.modelRef))
    }

    private func thinking(for record: ConversationRecord) -> RemoteThinking? {
        let source = ModelChoiceCatalog.currentModelSource(conversation: record, modelGroups: modelGroups, providers: providers)
        return RemoteProjection.thinking(ConversationThinkingResolver.resolvePresentationState(
            conversation: record, modelSource: source, providers: providers.providers, modelGroups: modelGroups))
    }

    private func settings(for record: ConversationRecord) -> RemoteConversationSettings {
        let source = ModelChoiceCatalog.currentModelSource(conversation: record, modelGroups: modelGroups, providers: providers)
        return RemoteConversationSettings(
            model: source.map(RemoteProjection.modelRef),
            modelLabel: ModelChoiceCatalog.shortLabel(for: source, modelGroups: modelGroups, providers: providers.providers),
            thinking: thinking(for: record)
        )
    }

    private func compactions(for record: ConversationRecord) -> RemoteCompactions {
        RemoteProjection.compactions(record.compactionMarkers, current: runs.compactions[record.id])
    }

    private func visibleRecord(_ id: UUID) -> ConversationRecord? {
        conversations.conversations.first { $0.id == id && !$0.isNativeDelegationChild && !$0.isArchived }
    }

    private func withRecord(_ id: UUID, _ action: () -> Void) -> (error: String?, admission: String?, conversationID: UUID?) {
        guard visibleRecord(id) != nil else { return ("conversationNotFound", nil, id) }
        action()
        return (nil, nil, id)
    }

    private func currentSummaries() -> [RemoteConversationSummary] {
        conversations.conversations
            .filter { !$0.isNativeDelegationChild && !$0.isArchived }
            .map(summary)
            .sorted { ($0.isPinned ? 1 : 0, $0.updatedAt) > ($1.isPinned ? 1 : 0, $1.updatedAt) }
    }

    private func summary(_ record: ConversationRecord) -> RemoteConversationSummary {
        let badge: RemoteConversationSummary.RunBadge?
        if !runs.isActive(conversationID: record.id) {
            badge = nil
        } else if runs.isPaused(conversationID: record.id) {
            badge = .paused
        } else if runs.isPausing(conversationID: record.id) {
            badge = .pausing
        } else {
            badge = .running
        }
        let waiting = permissions.pendingApproval?.conversationID == record.id
            || appAuthorization.pendingApproval?.conversationID == record.id
        return RemoteProjection.summary(
            record,
            projectName: conversations.project(for: record)?.name,
            run: badge,
            hasPendingApproval: waiting
        )
    }

    private func currentRunState(_ conversationID: UUID) -> RemoteRunState {
        let run = runs.run(for: conversationID)
        return RemoteProjection.runState(
            run,
            isPausing: runs.isPausing(conversationID: conversationID),
            statusText: run.map { runtimeEvents.trace(for: $0.id).currentStatus },
            queuedCount: runs.queuedInputCount(for: conversationID),
            queueHeld: runs.isQueueHeld(for: conversationID)
        )
    }

    /// Both approval owners' presented requests, the Computer Use app first (as the Mac shows them).
    private func currentApprovals() -> [RemoteApproval] {
        var approvals: [RemoteApproval] = []
        if let app = appAuthorization.pendingApproval {
            let title = conversations.conversations.first { $0.id == app.conversationID }?.title
            approvals.append(RemoteProjection.approval(app, conversationTitle: title))
        }
        if let tool = permissions.pendingApproval {
            approvals.append(RemoteProjection.approval(tool))
        }
        return approvals
    }

    private static func reply(for admission: ConversationInteractionService.Admission) -> (error: String?, admission: String?, conversationID: UUID?) {
        switch admission {
        case .steered(let id, _): (nil, "steered", id)
        case .queued(let id, _): (nil, "queued", id)
        case .started(let id, _, _): (nil, "started", id)
        case .committedNotStarted(let id, _): (nil, "committedNotStarted", id)
        case .compacting(let id): (nil, "compacting", id)
        case .refused(let refusal): (refusal.errorDescription ?? "empty", nil, nil)
        }
    }

    @discardableResult
    private func send(_ event: RemoteServerEvent, to client: Client) -> Int {
        do {
            let data = try encoder.encode(event)
            client.connection.send(String(decoding: data, as: UTF8.self))
            return data.count
        } catch {
            logs.error("Remote", "Could not encode a remote event: \(error.localizedDescription)")
            return 0
        }
    }
}
