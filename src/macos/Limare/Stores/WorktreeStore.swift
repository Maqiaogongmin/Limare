import Foundation
import Observation

enum WorktreeAdmission: Equatable {
    case admitted
    case refused(path: String, reason: String)
}

/// Conversation worktrees: the "start in a new worktree" choice of an empty conversation, the
/// worktree created on its first send, run admission, merging and removal.
@MainActor
@Observable
final class WorktreeStore {
    enum Operation: String { case creating, removing, merging }

    /// An empty conversation set to start in a new worktree; `baseBranch` nil is Local's HEAD.
    struct Pending: Equatable {
        var baseBranch: String?
    }

    private(set) var operations: [UUID: Operation] = [:]
    private(set) var pending: [UUID: Pending] = [:]
    private(set) var notices: [UUID: String] = [:]
    let preferences: WorktreePreferencesStore
    weak var undoJournal: UndoJournalStore?
    weak var subagents: SubagentCoordinator?
    var discardComments: ((UUID) -> Void)?

    private let conversations: ConversationStore
    private let runs: ConversationRunCoordinator
    private let service: GitWorktreeService
    private let defaultManagedRoot: URL

    /// Where new worktrees go: the Settings choice, else `~/.limare/worktrees`.
    var managedRoot: URL { preferences.value.root?.url ?? defaultManagedRoot }

    init(conversations: ConversationStore, runs: ConversationRunCoordinator, settingsRoot: URL,
         defaultManagedRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".limare/worktrees", isDirectory: true),
         service: GitWorktreeService = GitWorktreeService()) {
        self.conversations = conversations
        self.runs = runs
        self.defaultManagedRoot = defaultManagedRoot
        self.service = service
        self.preferences = WorktreePreferencesStore(root: settingsRoot)
    }

    func setNotice(_ message: String, for conversationID: UUID) { notices[conversationID] = message }
    func clearNotice(for conversationID: UUID) { notices.removeValue(forKey: conversationID) }

    private func record(_ id: UUID) -> ConversationRecord? {
        conversations.conversations.first { $0.id == id }
    }

    // MARK: - Admission

    /// Whether a run of `conversationID` may start. A subtask is checked against its parent's
    /// worktree. A worktree conversation never falls back to Local.
    func admit(conversationID: UUID, workingDirectory: URL? = nil) -> WorktreeAdmission {
        let conversation = record(conversationID)
        let ownerID = conversation?.nativeDelegationParentID ?? conversationID
        let owner = record(ownerID)
        if conversation?.isNativeDelegationChild == true, owner == nil {
            return .refused(path: conversation?.workspace?.path ?? "", reason: String(localized: "The parent conversation is unavailable."))
        }
        if operations[ownerID] != nil {
            return .refused(path: owner?.worktree?.workspace.path ?? "", reason: String(localized: "The worktree is being changed."))
        }
        guard let worktree = owner?.worktree else { return .admitted }
        if let reason = GitWorktreeService.unavailableReason(worktree, workingDirectory: workingDirectory) {
            return .refused(path: worktree.workspace.path, reason: reason)
        }
        return .admitted
    }

    // MARK: - Choosing a worktree

    /// The project folder an empty, unbound conversation would branch from.
    func explicitLocal(for conversationID: UUID) -> URL? {
        guard let conversation = record(conversationID), !conversation.isNativeDelegationChild else { return nil }
        if conversation.projectID != nil { return conversations.project(for: conversation)?.workspace?.url }
        return conversation.workspace?.url
    }

    /// An empty conversation whose folder is a Git repository can start in a new worktree.
    func canOfferWorktree(for conversationID: UUID) -> Bool {
        guard let conversation = record(conversationID), conversation.messages.isEmpty, conversation.worktree == nil,
              let local = explicitLocal(for: conversationID) else { return false }
        return FileManager.default.fileExists(atPath: local.appendingPathComponent(".git").path)
    }

    func setPending(_ value: Pending?, for conversationID: UUID) {
        pending[conversationID] = value
    }

    func localBranches(for conversationID: UUID) async -> (current: String?, branches: [String]) {
        guard let local = explicitLocal(for: conversationID),
              let result = try? await service.localBranches(root: local) else { return (nil, []) }
        return result
    }

    /// Run before a message is sent: creates the worktree the conversation was set to start in.
    func prepareBeforeSend(conversationID: UUID) async throws {
        guard let choice = pending[conversationID] else { return }
        guard let conversation = record(conversationID), conversation.messages.isEmpty, conversation.worktree == nil else {
            pending.removeValue(forKey: conversationID)
            return
        }
        try await create(conversationID: conversationID, baseBranch: choice.baseBranch)
    }

    func create(conversationID id: UUID, baseBranch: String?) async throws {
        guard operations[id] == nil else { throw GitWorktreeService.Failure.unavailable(String(localized: "The worktree is being changed.")) }
        guard let local = explicitLocal(for: id) else {
            throw GitWorktreeService.Failure.unavailable(String(localized: "Choose a project folder first."))
        }
        guard preferences.isReadable else {
            throw GitWorktreeService.Failure.unavailable(String(localized: "Worktree settings couldn't be read; fix or remove worktree_settings_v1.json."))
        }
        operations[id] = .creating
        defer { operations.removeValue(forKey: id) }
        let created = try await service.create(repositoryRoot: local, conversationID: id, baseBranch: baseBranch,
                                               managedRoot: managedRoot, branchPrefix: preferences.value.branchPrefix)
        guard let current = record(id), current.messages.isEmpty, current.worktree == nil else {
            _ = try? await service.remove(created.worktree)
            throw GitWorktreeService.Failure.unavailable(String(localized: "The conversation changed while its worktree was being created."))
        }
        do {
            try conversations.setConversationWorktree(id: id, worktree: created.worktree)
        } catch {
            _ = try? await service.remove(created.worktree)
            throw error
        }
        pending.removeValue(forKey: id)
        if let warning = created.includeWarning { notices[id] = warning } else { notices.removeValue(forKey: id) }
    }

    // MARK: - Reading

    private func boundWorktree(_ id: UUID) throws -> ConversationWorktree {
        guard let worktree = record(id)?.worktree else {
            throw GitWorktreeService.Failure.unavailable(String(localized: "This conversation has no worktree."))
        }
        return worktree
    }

    func status(conversationID: UUID) async throws -> WorktreeStatus {
        try await service.status(boundWorktree(conversationID))
    }

    func currentBranch(conversationID: UUID) async -> String? {
        guard let worktree = record(conversationID)?.worktree else { return nil }
        return await service.currentBranch(worktree)
    }

    /// Whether removing the worktree would lose work; a status that can't be read counts as yes.
    func hasUnsavedWork(conversationID: UUID) async -> Bool {
        guard let worktree = record(conversationID)?.worktree else { return false }
        guard let status = try? await service.status(worktree) else { return true }
        return status.exists && status.hasUnsavedWork
    }

    // MARK: - Merging and exporting

    private func requireIdle(_ id: UUID) throws {
        guard operations[id] == nil, runs.canStartRun(conversationID: id), runs.compactions[id]?.isRunning != true,
              subagents?.hasUnfinishedTasks(parentConversationID: id) != true else {
            throw GitWorktreeService.Failure.unavailable(String(localized: "Stop the conversation's run and subtasks first."))
        }
    }

    func mergeSummary(conversationID: UUID) async throws -> WorktreeMergeSummary {
        try await service.mergeSummary(boundWorktree(conversationID))
    }

    func merge(conversationID id: UUID, commitMessage: String) async throws {
        let worktree = try boundWorktree(id)
        try requireIdle(id)
        operations[id] = .merging
        defer { operations.removeValue(forKey: id) }
        let head = try await service.merge(worktree, commitMessage: commitMessage)
        notices[id] = String(localized: "Merged into Local at \(String(head.prefix(8))). The worktree and its branch were kept.")
    }

    func exportPatch(conversationID: UUID) async throws -> Data {
        try await service.exportPatch(boundWorktree(conversationID))
    }

    // MARK: - Removing

    /// Unbinds the conversation's worktree and, unless `keepFolder`, removes its directory (and
    /// its branch when the branch holds nothing). The conversation's undo history, recovery
    /// offer and review comments point into the worktree, so they go too. Nothing is cleared
    /// when Git refuses the removal. `stopping` stops the conversation first, as deleting it does.
    func remove(conversationID id: UUID, keepFolder: Bool, stopping: Bool = false) async throws {
        let worktree = try boundWorktree(id)
        if stopping {
            runs.stop(conversationID: id)
            guard operations[id] == nil else { throw GitWorktreeService.Failure.unavailable(String(localized: "The worktree is being changed.")) }
        } else {
            try requireIdle(id)
        }
        operations[id] = .removing
        defer { operations.removeValue(forKey: id) }
        var branchKept = true
        if !keepFolder { branchKept = try await service.remove(worktree) }
        undoJournal?.removeAll(conversationID: id)
        runs.discardRecovery(conversationID: id)
        discardComments?(id)
        try conversations.setConversationWorktree(id: id, worktree: nil)
        pending.removeValue(forKey: id)
        guard !stopping else { return }
        let local = conversations.effectiveWorkingDirectory(for: id).path
        notices[id] = keepFolder
            ? String(localized: "The worktree folder was kept at \(worktree.workspace.path). This conversation now works in \(local).")
            : branchKept
                ? String(localized: "The worktree was removed; its branch \(worktree.branch) was kept. This conversation now works in \(local).")
                : String(localized: "The worktree was removed. This conversation now works in \(local).")
    }

    // MARK: - Settings

    func setPreferences(root: URL?, branchPrefix: String) async throws {
        let prefix = branchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = root ?? FileManager.default.homeDirectoryForCurrentUser
        let format = try await service.git(probe, ["check-ref-format", "--branch", "\(prefix)/name"], allowFailure: true)
        guard !prefix.isEmpty, format.exitCode == 0 else {
            throw GitWorktreeService.Failure.unavailable(String(localized: "Enter a valid branch prefix."))
        }
        if let root {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: root.path) else {
                throw GitWorktreeService.Failure.unavailable(String(localized: "Choose a writable folder."))
            }
        }
        var candidate = preferences.value
        candidate.root = root.map(WorkspaceConfiguration.from(url:))
        candidate.branchPrefix = prefix
        try preferences.save(candidate)
    }
}
