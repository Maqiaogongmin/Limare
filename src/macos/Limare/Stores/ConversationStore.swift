import Foundation
import Observation

@MainActor
@Observable
final class ConversationStore {
    private(set) var projects: [ProjectRecord] = []
    private(set) var conversations: [ConversationRecord] = []
    var activeConversationID: UUID?
    var expandedProjectIDs: Set<UUID> = []

    @ObservationIgnored
    var onSelectConversation: ((ConversationRecord) -> Void)?
    /// True while some window shows the conversation or holds its unsent draft. An untouched
    /// placeholder is kept only while one does (see `discardUnshownPlaceholders`); without
    /// this, every one is kept.
    @ObservationIgnored
    var isConversationInUse: ((UUID) -> Bool)?
    @ObservationIgnored
    var onWorkspaceChanged: (() -> Void)?
    @ObservationIgnored
    var onConversationDeleted: ((UUID) -> Void)?
    @ObservationIgnored
    var onDelegationRelationshipDeletion: ((UUID) throws -> Void)?
    /// True when the conversation still holds archived drafts (for example a retracted first
    /// message). Such an empty conversation is not a disposable placeholder: pruning or reusing
    /// it would orphan the drafts.
    @ObservationIgnored
    let hasRetainedDrafts: ((UUID) -> Bool)?

    @ObservationIgnored
    private let persistence: ConversationPersistence
    @ObservationIgnored
    private let logs: DebugLogStore
    @ObservationIgnored
    private let attachmentStore: AttachmentStore?
    @ObservationIgnored
    private(set) weak var runCoordinator: ConversationRunCoordinator?
    @ObservationIgnored
    private var hasIssuedMutationSink = false
    @ObservationIgnored
    var defaultSubModelSource: @MainActor () -> ConversationModelSource? = { nil }
    @ObservationIgnored
    var defaultWorkspaceConfiguration: (@MainActor () -> WorkspaceConfiguration?)?

    init(
        persistence: ConversationPersistence,
        logs: DebugLogStore,
        attachmentStore: AttachmentStore? = nil,
        defaultSubModelSource: (@MainActor () -> ConversationModelSource?)? = nil,
        hasRetainedDrafts: ((UUID) -> Bool)? = nil
    ) {
        self.persistence = persistence
        // Must be known before `load()` prunes empty conversations, or a conversation whose
        // only content is an archived draft is deleted as a redundant placeholder.
        self.hasRetainedDrafts = hasRetainedDrafts
        self.logs = logs
        self.attachmentStore = attachmentStore
        if let defaultSubModelSource {
            self.defaultSubModelSource = defaultSubModelSource
        }
        load()
    }

    var activeConversation: ConversationRecord? {
        guard let id = activeConversationID else { return nil }
        return conversations.first(where: { $0.id == id })
    }

    func project(for conversation: ConversationRecord) -> ProjectRecord? {
        guard let pid = conversation.projectID else { return nil }
        return projects.first(where: { $0.id == pid })
    }

    func managedWorkingDirectory(for conversationID: UUID) -> URL {
        persistence.ensureWorkingDirectoryExists(for: conversationID)
    }

    /// Resolves the effective working directory using the canonical 4-step resolution ladder (SR-I03).
    /// Resolution is governed strictly by scope configuration truth, not current filesystem availability.
    func effectiveWorkingDirectory(for conversationID: UUID) -> URL {
        guard let conv = conversations.first(where: { $0.id == conversationID }) else {
            return managedWorkingDirectory(for: conversationID)
        }
        // Native child admission binds an immutable explicit workspace; no UI/global/project fallback.
        if conv.isNativeDelegationChild, let workspace = conv.workspace { return workspace.url }
        // Step 1: Project Workspace
        if conv.projectID != nil, let parent = project(for: conv), let parentWorkspace = parent.workspace {
            return parentWorkspace.url
        }
        // Step 2: Legacy Standalone Compatibility Bridge
        if conv.projectID == nil, let directWorkspace = conv.workspace {
            return directWorkspace.url
        }
        // Step 3: Global Durable Default Workspace
        if let defaultWS = defaultWorkspaceConfiguration?() {
            return defaultWS.url
        }
        // Step 4: Managed Scratch Directory
        return managedWorkingDirectory(for: conversationID)
    }


    // MARK: - Query Resolvers (Centralized Sorting & Filtering)

    var pinnedProjects: [ProjectRecord] {
        projects.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast, $0.updatedAt) > ($1.pinnedAt ?? .distantPast, $1.updatedAt) }
    }

    var unpinnedProjects: [ProjectRecord] {
        projects.filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var pinnedStandaloneConversations: [ConversationRecord] {
        conversations.filter { $0.projectID == nil && !$0.isNativeDelegationChild && !$0.isArchived && $0.isPinned }
            .sorted { ($0.pinnedAt ?? .distantPast, $0.updatedAt) > ($1.pinnedAt ?? .distantPast, $1.updatedAt) }
    }

    var unpinnedStandaloneConversations: [ConversationRecord] {
        conversations.filter { $0.projectID == nil && !$0.isNativeDelegationChild && !$0.isArchived && !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var standaloneConversations: [ConversationRecord] {
        pinnedStandaloneConversations + unpinnedStandaloneConversations
    }

    func activeConversations(in project: ProjectRecord) -> [ConversationRecord] {
        let child = conversations.filter { $0.projectID == project.id && !$0.isNativeDelegationChild && !$0.isArchived }
        let pinned = child.filter(\.isPinned).sorted { ($0.pinnedAt ?? .distantPast, $0.updatedAt) > ($1.pinnedAt ?? .distantPast, $1.updatedAt) }
        let unpinned = child.filter { !$0.isPinned }.sorted { $0.updatedAt > $1.updatedAt }
        return pinned + unpinned
    }

    func conversations(in project: ProjectRecord) -> [ConversationRecord] {
        activeConversations(in: project)
    }

    var archivedConversations: [ConversationRecord] {
        conversations.filter(\.isArchived)
            .sorted { ($0.archivedAt ?? .distantPast, $0.updatedAt) > ($1.archivedAt ?? .distantPast, $1.updatedAt) }
    }

    var hasPinnedItems: Bool {
        !pinnedProjects.isEmpty || !pinnedStandaloneConversations.isEmpty
    }

    func searchResults(query: String) -> (projects: [ProjectRecord], conversations: [ConversationRecord]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (unpinnedProjects + pinnedProjects, conversations.filter { !$0.isNativeDelegationChild && !$0.isArchived })
        }
        let matchingProjects = projects.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        let matchingConversations = conversations.filter { !$0.isNativeDelegationChild && !$0.isArchived && $0.title.localizedCaseInsensitiveContains(trimmed) }
        return (matchingProjects, matchingConversations)
    }

    /// Durable explicit creation: no placeholder reuse, selection, defaults or swallowed failures.
    func createNativeChild(_ candidate: ConversationRecord) throws -> ConversationRecord {
        guard candidate.isNativeDelegationChild, candidate.nativeDelegationParentID != nil,
              candidate.workspace != nil, candidate.effectiveModelSource != nil,
              !candidate.isDisposablePlaceholder else { throw DelegationFailure.invalidRequest }
        if let existing = conversations.first(where: { $0.id == candidate.id }) {
            guard existing.nativeDelegationTaskID == candidate.nativeDelegationTaskID,
                  existing.nativeDelegationParentID == candidate.nativeDelegationParentID,
                  existing.workspace == candidate.workspace,
                  existing.effectiveModelSource == candidate.effectiveModelSource else {
                throw DelegationFailure.reconciliationRequired
            }
            return existing
        }
        guard !conversations.contains(where: { $0.nativeDelegationTaskID == candidate.nativeDelegationTaskID }) else {
            throw DelegationFailure.duplicateCommandConflict
        }
        try persistence.saveConversation(candidate)
        conversations.insert(candidate, at: 0)
        // Parent relationship is stored on the child. The Project compatibility index
        // is rebuilt by its owner during load; it is never spawn authority.
        return candidate
    }

    // MARK: - Conversation Operations

    @discardableResult
    func newConversation(
        projectID: UUID? = nil,
        workspace: WorkspaceConfiguration? = nil,
        modelSource: ConversationModelSource? = nil
    ) -> ConversationRecord {
        let parentProject = projectID.flatMap { pid in projects.first(where: { $0.id == pid }) }
        // SR-I04: Dynamic inheritance at resolution time. Do NOT copy parentProject.workspace.
        let effectiveWorkspace = workspace
        // Capture the global default exactly once for this new-conversation operation.
        // Existing non-disposable conversations never consult it again.
        let effectiveSubModelSource = defaultSubModelSource()

        // Reuse only an untouched default placeholder in the exact same scope.
        if let existingEmpty = conversations.first(where: {
            $0.projectID == projectID && isDisposable($0)
        }) {
            if let index = conversations.firstIndex(where: { $0.id == existingEmpty.id }) {
                var candidate = conversations[index]
                var changed = false
                if candidate.workspace != effectiveWorkspace {
                    candidate.workspace = effectiveWorkspace
                    changed = true
                }
                if modelSource != nil && candidate.modelSource != modelSource {
                    candidate.modelSource = modelSource
                    if case .direct(let pID, let mID) = modelSource {
                        candidate.providerID = pID
                        candidate.modelID = mID
                    } else if case .group = modelSource {
                        candidate.providerID = nil
                        candidate.modelID = nil
                    }
                    changed = true
                }
                if candidate.subModelSource != effectiveSubModelSource {
                    candidate.subModelSource = effectiveSubModelSource
                    changed = true
                }
                if candidate.subagentEnabled != ConversationRecord.defaultSubagentEnabled {
                    candidate.subagentEnabled = ConversationRecord.defaultSubagentEnabled
                    changed = true
                }
                if changed {
                    do {
                        try persistence.saveConversation(candidate)
                        conversations[index] = candidate
                    } catch {
                        logs.error("Conversation", "Failed to persist reused placeholder conversation '\(candidate.id)': \(error.localizedDescription)")
                    }
                }
            }
            if let pid = projectID {
                expandedProjectIDs.insert(pid)
            }
            selectConversation(id: existingEmpty.id)
            logs.info("Conversation", "Reused existing empty conversation '\(existingEmpty.id)' (project: \(projectID?.uuidString ?? "none")).")
            return conversations.first(where: { $0.id == existingEmpty.id }) ?? existingEmpty
        }

        let conversation = ConversationRecord(
            projectID: projectID,
            workspace: effectiveWorkspace,
            modelSource: modelSource,
            subModelSource: effectiveSubModelSource,
            memoryEnabled: true
        )

        conversations.insert(conversation, at: 0)
        if let parentProject {
            if let index = projects.firstIndex(where: { $0.id == parentProject.id }) {
                if !projects[index].conversationIDs.contains(conversation.id) {
                    projects[index].conversationIDs.append(conversation.id)
                    projects[index].updatedAt = Date()
                    try? persistence.saveProjects(projects)
                }
            }
            expandedProjectIDs.insert(parentProject.id)
        }

        try? persistence.saveConversation(conversation)
        selectConversation(id: conversation.id)
        logs.info("Conversation", "Created new conversation '\(conversation.id)' (project: \(projectID?.uuidString ?? "none")).")
        return conversation
    }

    @discardableResult
    func newBackgroundConversation(
        projectID: UUID? = nil,
        workspace: WorkspaceConfiguration? = nil,
        modelSource: ConversationModelSource? = nil,
        title: String? = nil
    ) -> ConversationRecord {
        let effectiveWorkspace = workspace
        let effectiveSubModelSource = defaultSubModelSource()

        var conversation = ConversationRecord(
            projectID: projectID,
            workspace: effectiveWorkspace,
            modelSource: modelSource,
            subModelSource: effectiveSubModelSource,
            memoryEnabled: true
        )
        if let title {
            conversation.title = title
        }

        conversations.insert(conversation, at: 0)
        if let parentProject = projectID.flatMap({ pid in projects.first(where: { $0.id == pid }) }) {
            if let index = projects.firstIndex(where: { $0.id == parentProject.id }) {
                if !projects[index].conversationIDs.contains(conversation.id) {
                    projects[index].conversationIDs.append(conversation.id)
                    projects[index].updatedAt = Date()
                    try? persistence.saveProjects(projects)
                }
            }
        }

        try? persistence.saveConversation(conversation)
        logs.info("Conversation", "Created background conversation '\(conversation.id)' (title: \(title ?? "none")).")
        return conversation
    }

    /// Creates a background conversation that already holds `messages`, in one durable save.
    /// When the save fails nothing is added, so a first message that cannot be persisted leaves
    /// no empty conversation behind. Never selects it in the Mac UI.
    func createBackgroundConversation(
        id: UUID,
        projectID: UUID?,
        modelSource: ConversationModelSource,
        thinkingLevelOverride: ThinkingLevel? = nil,
        messages: [ChatMessage]
    ) throws -> ConversationRecord {
        var conversation = ConversationRecord(
            id: id,
            projectID: projectID,
            modelSource: modelSource,
            subModelSource: defaultSubModelSource(),
            messages: messages,
            memoryEnabled: true
        )
        conversation.thinkingLevelOverride = thinkingLevelOverride
        try persistence.saveConversation(conversation)
        conversations.insert(conversation, at: 0)
        if let projectID, let index = projects.firstIndex(where: { $0.id == projectID }),
           !projects[index].conversationIDs.contains(id) {
            projects[index].conversationIDs.append(id)
            projects[index].updatedAt = Date()
            try? persistence.saveProjects(projects)
        }
        logs.info("Conversation", "Created background conversation '\(id)' with its first message.")
        return conversation
    }

    func setConversationModelSource(id: UUID, source: ConversationModelSource) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].modelSource = source
        switch source {
        case .direct(let providerID, let modelID):
            conversations[index].providerID = providerID
            conversations[index].modelID = modelID
        case .group:
            conversations[index].providerID = nil
            conversations[index].modelID = nil
        }
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        logs.info("Conversation", "Updated model source for conversation '\(id)' to \(source).")
    }

    func setConversationThinkingLevelOverride(id: UUID, level: ThinkingLevel?) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].thinkingLevelOverride = level
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        logs.info("Conversation", "Updated thinking level override for conversation '\(id)' to \(level?.rawValue ?? "nil (inherit)").")
    }

    func selectConversation(id: UUID) {
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        activeConversationID = id
        onSelectConversation?(conversation)
        discardUnshownPlaceholders(keeping: id)
    }

    /// An untouched "New Conversation" lives only while a window shows it: leaving it, for an
    /// existing conversation or a new one in another project, removes it, so the sidebar never
    /// gathers empty placeholders across projects. Its unsent draft was archived when the window
    /// left it, which makes it no longer disposable, so nothing typed is lost.
    private func discardUnshownPlaceholders(keeping keptID: UUID) {
        guard let isConversationInUse else { return }
        let unshown = conversations.filter { $0.id != keptID && isDisposable($0) && !isConversationInUse($0.id) }
        guard !unshown.isEmpty else { return }
        var projectsChanged = false
        for placeholder in unshown {
            conversations.removeAll(where: { $0.id == placeholder.id })
            if let pid = placeholder.projectID, let index = projects.firstIndex(where: { $0.id == pid }) {
                projects[index].conversationIDs.removeAll(where: { $0 == placeholder.id })
                projectsChanged = true
            }
            try? persistence.deleteConversation(id: placeholder.id)
        }
        if projectsChanged {
            try? persistence.saveProjects(projects)
        }
        logs.info("Conversation", "Discarded \(unshown.count) empty placeholder conversation(s) no window shows.")
    }

    private func isDisposable(_ record: ConversationRecord) -> Bool {
        record.isDisposablePlaceholder && hasRetainedDrafts?(record.id) != true
    }

    func renameConversation(id: UUID, title: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        conversations[index].generatedTitleSourceMessageID = nil
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
    }

    /// Commits a generated title only while the conversation is still untitled. With a source
    /// message, the commit is also fenced on that message still being in the conversation: a
    /// generation that finishes after its message was retracted must not resurrect it as the title.
    @discardableResult
    func setGeneratedTitleIfStillUntitled(id: UUID, title: String, sourceMessageID: UUID? = nil) -> Bool {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return false }
        let current = conversations[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == ConversationRecord.defaultTitle else { return false }
        if let sourceMessageID, !conversations[index].messages.contains(where: { $0.id == sourceMessageID }) {
            return false
        }
        let generated = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generated.isEmpty else { return false }
        conversations[index].title = generated
        conversations[index].generatedTitleSourceMessageID = sourceMessageID
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        return true
    }

    func toggleConversationPinned(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let nowPinned = conversations[index].isPinned ? nil : Date()
        conversations[index].pinnedAt = nowPinned
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        logs.info("Conversation", "\(nowPinned != nil ? "Pinned" : "Unpinned") conversation '\(id)'.")
    }

    func setConversationPinned(id: UUID, isPinned: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].pinnedAt = isPinned ? Date() : nil
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
    }

    func archiveConversation(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].archivedAt = Date()
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        logs.info("Conversation", "Archived conversation '\(id)'.")

        if activeConversationID == id {
            if let next = conversations.first(where: { !$0.isArchived && !$0.isNativeDelegationChild }) {  // hidden Native Child is never auto-selected
                selectConversation(id: next.id)
            } else {
                newConversation()
            }
        }
    }

    func restoreConversation(id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].archivedAt = nil
        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        logs.info("Conversation", "Restored conversation '\(id)'.")
        selectConversation(id: id)
    }

    func deleteConversation(id: UUID) {
        do { try onDelegationRelationshipDeletion?(id) }
        catch { logs.error("Conversation", "Delegation relationship deletion failed: \(error)"); return }
        runCoordinator?.stop(conversationID: id)
        runCoordinator?.discardInteractiveInputs(conversationID: id)
        runCoordinator?.discardRecovery(conversationID: id)
        if let recoveryStore = runCoordinator?.recoveryStore {
            do {
                try recoveryStore.removeConversation(conversationID: id)
            } catch {
                logs.error("Conversation", "Failed to remove recovery store state for conversation '\(id)': \(error.localizedDescription)")
                return
            }
        }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let removed = conversations.remove(at: index)
        try? persistence.deleteConversation(id: id)

        if let attachmentStore {
            for msg in removed.messages {
                for att in msg.attachments {
                    attachmentStore.deleteAttachment(att)
                }
            }
        }

        if let pid = removed.projectID, let pIndex = projects.firstIndex(where: { $0.id == pid }) {
            projects[pIndex].conversationIDs.removeAll(where: { $0 == id })
            projects[pIndex].updatedAt = Date()
            try? persistence.saveProjects(projects)
        }

        if activeConversationID == id {
            if let next = conversations.first(where: { !$0.isArchived && !$0.isNativeDelegationChild }) {  // hidden Native Child is never auto-selected
                selectConversation(id: next.id)
            } else {
                newConversation()
            }
        }
        onConversationDeleted?(id)
        logs.info("Conversation", "Deleted conversation '\(id)'.")
    }

    func moveConversation(id: UUID, toProjectID: UUID?) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let oldPID = conversations[index].projectID
        if oldPID == toProjectID { return }

        if let oldPID, let pIndex = projects.firstIndex(where: { $0.id == oldPID }) {
            projects[pIndex].conversationIDs.removeAll(where: { $0 == id })
            projects[pIndex].updatedAt = Date()
        }

        conversations[index].projectID = toProjectID
        if let toProjectID {
            if let pIndex = projects.firstIndex(where: { $0.id == toProjectID }) {
                if !projects[pIndex].conversationIDs.contains(id) {
                    projects[pIndex].conversationIDs.append(id)
                    projects[pIndex].updatedAt = Date()
                }
            }
            expandedProjectIDs.insert(toProjectID)
        }
        // SR-I04: Scope-transition reconciliation. Clear legacy workspace copy.
        conversations[index].workspace = nil

        conversations[index].updatedAt = Date()
        try? persistence.saveConversation(conversations[index])
        try? persistence.saveProjects(projects)
        onWorkspaceChanged?()
    }

    func bindRunCoordinator(_ coordinator: ConversationRunCoordinator) -> ConversationMutationSink? {
        if let existing = self.runCoordinator, existing === coordinator, hasIssuedMutationSink {
            return nil
        }
        guard !hasIssuedMutationSink, self.runCoordinator == nil else {
            logs.error("ConversationStore", "Rejected unauthorized attempt to rebind run coordinator or obtain a secondary mutation sink.")
            return nil
        }
        self.runCoordinator = coordinator
        self.hasIssuedMutationSink = true
        return ConversationMutationSink(store: self)
    }

    func commitDurableMessages(id: UUID, messages: [ChatMessage]) throws {
        if let coordinator = runCoordinator, coordinator.hasActiveMutationOwner(for: id) {
            logs.error("ConversationStore", "Blocked unauthorized ambient message mutation for conversation '\(id)' while an active run owns the session.")
            throw RuntimePersistenceError.writeFailed("Blocked unauthorized ambient message mutation while active run owns the session.")
        }
        try applyDurableMessagesUpdate(id: id, messages: messages)
    }

    /// Durably replaces the transcript with `keptMessages` after a retraction, in one save. A title
    /// generated from a removed message reverts to the default title; a title the user set stays.
    /// Ambient, so it is refused while a run owns the conversation.
    func commitRetraction(id: UUID, keptMessages: [ChatMessage], removedMessageIDs: Set<UUID>, fencedRecoveryRunID: UUID? = nil) throws {
        if let coordinator = runCoordinator, coordinator.hasActiveMutationOwner(for: id) {
            throw RuntimePersistenceError.writeFailed("Blocked retraction while an active run owns the session.")
        }
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            throw RuntimePersistenceError.conversationNotFound(id)
        }
        var candidate = conversations[index]
        candidate.messages = keptMessages
        if let source = candidate.generatedTitleSourceMessageID, removedMessageIDs.contains(source) {
            candidate.title = ConversationRecord.defaultTitle
            candidate.generatedTitleSourceMessageID = nil
        }
        if let fencedRecoveryRunID {
            candidate.retractedRecoveryRunID = fencedRecoveryRunID
        }
        // A compaction shown after a removed message goes with it.
        candidate.compactionMarkers.removeAll { removedMessageIDs.contains($0.afterMessageID) }
        candidate.updatedAt = Date()
        try persistence.saveConversation(candidate)
        conversations[index] = candidate
    }

    /// Records a finished Compact command so the transcript shows it.
    func recordCompaction(id: UUID, marker: CompactionMarker) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var candidate = conversations[index]
        candidate.compactionMarkers.append(marker)
        do {
            try persistence.saveConversation(candidate)
            conversations[index] = candidate
        } catch {
            logs.error("ConversationStore", "Failed to record the compaction of conversation '\(id)': \(error.localizedDescription)")
        }
    }

    /// Clears the retraction fence once the fenced run can no longer be offered for recovery.
    func clearRetractionFence(id: UUID, runID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
              conversations[index].retractedRecoveryRunID == runID else { return }
        var candidate = conversations[index]
        candidate.retractedRecoveryRunID = nil
        do {
            try persistence.saveConversation(candidate)
            conversations[index] = candidate
        } catch {
            logs.error("ConversationStore", "Failed to clear the retraction fence of conversation '\(id)'; it is reconciled again at the next launch: \(error.localizedDescription)")
        }
    }

    func updateConversationMessages(id: UUID, messages: [ChatMessage]) {
        if let coordinator = runCoordinator, coordinator.hasActiveMutationOwner(for: id) {
            logs.error("ConversationStore", "Blocked unauthorized ambient message mutation for conversation '\(id)' while an active run owns the session.")
            return
        }
        try? applyDurableMessagesUpdate(id: id, messages: messages)
    }

    fileprivate func applyDurableMessagesUpdate(id: UUID, messages: [ChatMessage]) throws {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else {
            throw RuntimePersistenceError.conversationNotFound(id)
        }
        var candidate = conversations[index]
        candidate.messages = messages
        candidate.updatedAt = Date()
        try persistence.saveConversation(candidate)
        conversations[index] = candidate
    }

    /// Conversation-scoped Subagent policy. Persists immediately; the next Manifest projection
    /// honours it. Leaves `subModelSource` untouched. Native Children never delegate, so their
    /// records cannot be used to change the policy.
    func setSubagentEnabled(id: UUID, enabled: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        guard !conversations[index].isNativeDelegationChild else {
            logs.info("Conversation", "Ignored Subagent policy change for Native Child conversation '\(id)'.")
            return
        }
        guard conversations[index].subagentEnabled != enabled else { return }

        var candidate = conversations[index]
        candidate.subagentEnabled = enabled

        do {
            try persistence.saveConversation(candidate)
            conversations[index] = candidate
            logs.info("Conversation", "Subagent \(enabled ? "enabled" : "disabled") for conversation '\(id)'.")
        } catch {
            logs.error("Conversation", "Failed to persist Subagent policy for conversation '\(id)': \(error.localizedDescription)")
        }
    }

    /// Resolves conversation-scoped Memory projection policy (MEM-G04, MEM-G08).
    /// Read-only lookup based strictly on explicit conversation ID identity.
    func shouldProjectMemory(for conversationID: UUID?) -> Bool {
        guard let conversationID else {
            return true
        }
        return conversations.first(where: { $0.id == conversationID })?.shouldProjectMemory
            ?? true
    }

    func updateActiveConversationContext(providerID: UUID?, modelID: String?, workspace: WorkspaceConfiguration?) {
        guard let id = activeConversationID,
              let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if conversations[index].providerID != providerID {
            conversations[index].providerID = providerID
            changed = true
        }
        if conversations[index].modelID != modelID {
            conversations[index].modelID = modelID
            changed = true
        }
        if conversations[index].workspace != workspace {
            conversations[index].workspace = workspace
            changed = true
        }
        if changed {
            conversations[index].updatedAt = Date()
            try? persistence.saveConversation(conversations[index])
            onWorkspaceChanged?()
        }
    }

    /// Compatibility/local-fallback entry point. The primary send path must not
    /// call this before the assistant finishes; ConversationTitleGenerator owns
    /// normal title generation and invokes equivalent fallback semantics only
    /// after model attempts are exhausted.
    func autoGenerateTitleIfNeeded(id: UUID, firstUserPrompt: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let current = conversations[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.isEmpty || current == ConversationRecord.defaultTitle else { return }
        let flattened = firstUserPrompt
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return }
        let source = conversations[index].messages.first(where: { $0.role == .user })?.id
        _ = setGeneratedTitleIfStillUntitled(id: id, title: String(flattened.prefix(35)), sourceMessageID: source)
    }

    // MARK: - Project Operations

    @discardableResult
    func newProject(name: String, workspace: WorkspaceConfiguration? = nil) -> ProjectRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = trimmed.isEmpty ? "New Project" : trimmed
        let project = ProjectRecord(name: projectName, workspace: workspace)
        projects.insert(project, at: 0)
        expandedProjectIDs.insert(project.id)
        try? persistence.saveProjects(projects)
        logs.info("Project", "Created project '\(project.name)' (\(project.id)).")
        return project
    }

    func renameProject(id: UUID, name: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        projects[index].updatedAt = Date()
        try? persistence.saveProjects(projects)
    }

    func toggleProjectPinned(id: UUID) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let nowPinned = projects[index].isPinned ? nil : Date()
        projects[index].pinnedAt = nowPinned
        projects[index].updatedAt = Date()
        try? persistence.saveProjects(projects)
        logs.info("Project", "\(nowPinned != nil ? "Pinned" : "Unpinned") project '\(id)'.")
    }

    func setProjectPinned(id: UUID, isPinned: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].pinnedAt = isPinned ? Date() : nil
        projects[index].updatedAt = Date()
        try? persistence.saveProjects(projects)
    }

    func setProjectWorkspace(id: UUID, workspace: WorkspaceConfiguration?) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].workspace = workspace
        projects[index].updatedAt = Date()
        try? persistence.saveProjects(projects)
        // SR-I04: Dynamic inheritance at resolution time. Do NOT cascade writes to child conversations.
        onWorkspaceChanged?()
    }

    func archiveProjectConversations(id: UUID) {
        var anyArchived = false
        for index in conversations.indices where conversations[index].projectID == id && !conversations[index].isNativeDelegationChild && !conversations[index].isArchived {
            conversations[index].archivedAt = Date()
            conversations[index].updatedAt = Date()
            try? persistence.saveConversation(conversations[index])
            anyArchived = true
        }

        if anyArchived {
            logs.info("Project", "Archived conversations in project '\(id)'.")
            if let active = activeConversation, active.projectID == id {
                if let next = conversations.first(where: { !$0.isArchived && !$0.isNativeDelegationChild }) {  // hidden Native Child is never auto-selected
                    selectConversation(id: next.id)
                } else {
                    newConversation()
                }
            }
        }
    }

    func deleteProject(id: UUID) {
        do {
            for conversation in conversations where conversation.projectID == id {
                try onDelegationRelationshipDeletion?(conversation.id)
            }
        } catch {
            logs.error("Project", "Delegation termination failed: \(error)")
            return
        }
        projects.removeAll(where: { $0.id == id })
        expandedProjectIDs.remove(id)
        try? persistence.saveProjects(projects)

        // Unassign conversations rather than deleting to avoid losing user history
        for i in conversations.indices where conversations[i].projectID == id {
            conversations[i].projectID = nil
            if !conversations[i].isNativeDelegationChild { conversations[i].workspace = nil }
            conversations[i].updatedAt = Date()
            try? persistence.saveConversation(conversations[i])
        }
        logs.info("Project", "Deleted project '\(id)', unassigned child conversations.")
        onWorkspaceChanged?()
    }

    func toggleProjectExpanded(id: UUID) {
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    // MARK: - Internal

    private func load() {
        projects = persistence.loadProjects()
        conversations = persistence.loadConversations()
        if let attachmentStore {
            for conv in conversations {
                for msg in conv.messages {
                    for att in msg.attachments {
                        attachmentStore.registerAttachment(att)
                    }
                }
            }
        }
        expandedProjectIDs = Set(projects.map(\.id))

        // SR-I09: Referential integrity reconciliation for broken project references
        let projectIDs = Set(projects.map(\.id))
        for index in conversations.indices {
            if let pid = conversations[index].projectID, !projectIDs.contains(pid) {
                logs.info("Conversation", "Normalizing broken project reference '\(pid)' for conversation '\(conversations[index].id)' to nil.")
                conversations[index].projectID = nil
                if !conversations[index].isNativeDelegationChild { conversations[index].workspace = nil }
                conversations[index].updatedAt = Date()
                try? persistence.saveConversation(conversations[index])
            }
        }

        // SR-I09: Rebuild ProjectRecord.conversationIDs compatibility index from ALL matching conversations (including archived)
        var projectsChanged = false
        for pIndex in projects.indices {
            let pid = projects[pIndex].id
            let matchingIDs = conversations.filter { $0.projectID == pid }.map(\.id)
            if projects[pIndex].conversationIDs != matchingIDs {
                projects[pIndex].conversationIDs = matchingIDs
                projects[pIndex].updatedAt = Date()
                projectsChanged = true
            }
        }
        if projectsChanged {
            try? persistence.saveProjects(projects)
        }

        pruneRedundantEmptyConversations()

        if conversations.isEmpty {
            let initial = ConversationRecord(memoryEnabled: true)
            conversations.append(initial)
            try? persistence.saveConversation(initial)
        }

        // Set active conversation to the first unarchived conversation if available
        activeConversationID = conversations.first(where: { !$0.isNativeDelegationChild && !$0.isArchived })?.id ?? conversations.first(where: { !$0.isNativeDelegationChild })?.id
    }

    private func pruneRedundantEmptyConversations() {
        // 1. Standalone empty conversations
        let standaloneEmpty = conversations.filter {
            $0.projectID == nil && isDisposable($0)
        }
        if standaloneEmpty.count > 1 {
            for duplicate in standaloneEmpty.dropFirst() {
                conversations.removeAll(where: { $0.id == duplicate.id })
                try? persistence.deleteConversation(id: duplicate.id)
            }
            logs.info("Conversation", "Pruned \(standaloneEmpty.count - 1) redundant empty standalone conversations.")
        }

        // 2. Project empty conversations
        var projectsChanged = false
        for pIndex in projects.indices {
            let pid = projects[pIndex].id
            let projectEmpty = conversations.filter {
                $0.projectID == pid && isDisposable($0)
            }
            if projectEmpty.count > 1 {
                for duplicate in projectEmpty.dropFirst() {
                    conversations.removeAll(where: { $0.id == duplicate.id })
                    projects[pIndex].conversationIDs.removeAll(where: { $0 == duplicate.id })
                    try? persistence.deleteConversation(id: duplicate.id)
                }
                projectsChanged = true
                logs.info("Conversation", "Pruned \(projectEmpty.count - 1) redundant empty conversations in project '\(projects[pIndex].name)'.")
            }
        }
        if projectsChanged {
            try? persistence.saveProjects(projects)
        }
    }
}

@MainActor
struct ConversationMutationSink {
    fileprivate let store: ConversationStore
    fileprivate init(store: ConversationStore) {
        self.store = store
    }

    func commitDurableMessages(id: UUID, messages: [ChatMessage]) throws {
        try store.applyDurableMessagesUpdate(id: id, messages: messages)
    }
}
