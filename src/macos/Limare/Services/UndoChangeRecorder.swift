import Foundation

/// Records the project changes a run's file tools make, for undo. Each write is bracketed:
/// the before-state is backed up and journaled first; if that fails the write does not happen.
/// Attribution is the user message the turn currently answers (for a native child: the parent
/// message that delegated it).
@MainActor
final class UndoChangeRecorder {
    let journal: UndoJournalStore
    /// The conversation the changes are attributed to (the parent for a native child run).
    let conversationID: UUID
    let runID: UUID
    private let owner: @MainActor () -> UUID?

    init(journal: UndoJournalStore, conversationID: UUID, runID: UUID, owner: @escaping @MainActor () -> UUID?) {
        self.journal = journal
        self.conversationID = conversationID
        self.runID = runID
        self.owner = owner
    }

    var currentOwner: UUID? { owner() }

    /// Brackets a write of `path`. `location` pins it to the directory it was approved under.
    func recording<T>(path: URL, location: AnchoredPath? = nil, source: String, toolCallID: String?, workspaceRoot: URL?,
                      _ body: (AnchoredPath?) throws -> T) throws -> T {
        guard let ownerMessageID = owner() else { return try body(location) }
        let standardized = path.standardizedFileURL.path
        let root = workspaceRoot?.standardizedFileURL.path
        let anchored = location ?? root.flatMap { AnchoredPath(path: standardized, under: $0) } ?? .atParent(of: standardized)
        let recordID = try journal.beginChange(
            conversationID: conversationID, ownerMessageID: ownerMessageID, runID: runID,
            channel: .fileTool, source: source, toolCallID: toolCallID,
            path: standardized, location: anchored, workspaceRoot: root)
        let result: T
        do {
            result = try body(journal.record(id: recordID, conversationID: conversationID)?.location)
        } catch {
            journal.abandonChange(recordID, conversationID: conversationID)
            throw error
        }
        CrashInjection.point("recorder.afterWrite")
        journal.completeChange(recordID, conversationID: conversationID)
        return result
    }

    /// A native child task's later changes belong to the message that delegated it.
    func registerDelegation(taskID: UUID) {
        guard let ownerMessageID = owner() else { return }
        journal.registerDelegationOwner(.init(taskID: taskID, parentConversationID: conversationID, ownerMessageID: ownerMessageID))
    }
}
