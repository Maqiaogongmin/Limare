import Foundation

/// The state of one filesystem path at a moment, as far as undo needs it: enough to recognise
/// it again (hash, link target) and, when `blob` is set, to bring it back.
enum UndoFileState: Codable, Equatable, Sendable {
    case absent
    /// A regular file. `blob` names the backup of its content in the undo blob store; nil when
    /// only the hash was recorded (an "after" state) or the backup was evicted.
    case file(sha256: String, size: Int64, mode: UInt16, blob: String?)
    case symlink(target: String)
    /// Anything undo does not manage (directory, socket, …). Never restored.
    case other(kind: String)

    /// Same observable state (content, size and permission bits), ignoring whether a backup is held.
    func sameState(as other: UndoFileState) -> Bool {
        switch (self, other) {
        case (.absent, .absent): return true
        case let (.file(a, sa, ma, _), .file(b, sb, mb, _)): return a == b && sa == sb && ma == mb
        case let (.symlink(a), .symlink(b)): return a == b
        case let (.other(a), .other(b)): return a == b
        default: return false
        }
    }

    var blob: String? {
        if case let .file(_, _, _, blob) = self { return blob }
        return nil
    }

    var isRestorable: Bool {
        switch self {
        case .absent, .symlink: return true
        case .file(_, _, _, let blob): return blob != nil
        case .other: return false
        }
    }

    var withoutBlob: UndoFileState {
        if case let .file(hash, size, mode, _) = self { return .file(sha256: hash, size: size, mode: mode, blob: nil) }
        return self
    }
}

/// How a recorded change reached the project.
enum UndoChangeChannel: String, Codable, Sendable {
    /// `file_write`, `file_edit`, `attachment_copy` writing the project directly (direct mode).
    case fileTool
    /// Delivery of an isolated working copy segment into the project.
    case delivery
    /// A change observed in the project inside an isolation-exception window
    /// (escalated shell, Git, Computer Use, MCP).
    case exception
}

/// One change of one path in the user's project, attributed to the user message whose turn
/// produced it. The only record kind restore plans are built from.
struct UndoChangeRecord: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The before-state is backed up; the write may or may not have happened yet.
        case pending
        /// The write happened and `after` describes its result.
        case applied
        /// Restored by an undo.
        case reverted
        /// Superseded without restore (for example the user kept their own version), or a
        /// write that turned out to change nothing.
        case discarded
    }

    let id: UUID
    /// Monotonic per conversation; orders records of the same path.
    let sequence: Int
    let conversationID: UUID
    /// The user message whose turn made this change.
    let ownerMessageID: UUID
    let runID: UUID?
    /// Isolation segment that produced the change; nil in direct mode.
    let segment: Int?
    let channel: UndoChangeChannel
    /// Tool or exception that caused it, for display (`file_edit`, `shell_execute`, …).
    let source: String
    /// Provider call ID of the tool call that made the change, when one did.
    var toolCallID: String?
    /// The isolation exception window that observed the change (exception channel only).
    var exceptionID: UUID? = nil
    let path: String
    /// The real path of the directory the change was made under (the project, or the directory
    /// an approved write outside it went to). Restore walks from it without following links.
    var anchor: String? = nil
    /// Full directory identity captured when this change was recorded.
    var recordedLocation: AnchoredPath? = nil
    var before: UndoFileState
    var after: UndoFileState?
    /// Directories the change created; removed again on restore when empty.
    var createdDirectories: [String]
    var status: Status
    /// Exception-window changes whose author cannot be told apart from the user's own edits.
    /// Offered for restore, never selected by default.
    var isUncertain: Bool
    let createdAt: Date
    var updatedAt: Date

    /// Where restore operates: below the recorded anchor, or (for records without one) below
    /// the path's parent as it is now.
    var location: AnchoredPath {
        recordedLocation ?? anchor.flatMap { AnchoredPath(path: path, under: $0) } ?? .atParent(of: path)
    }
}

/// Maps a native child task to the user message that delegated it, so the child's changes are
/// attributed to that message in the parent conversation.
struct UndoDelegationOwner: Codable, Equatable, Sendable {
    let taskID: UUID
    let parentConversationID: UUID
    let ownerMessageID: UUID
}

struct UndoJournalSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = UndoJournalSnapshot.currentSchemaVersion
    var nextSequence = 1
    var records: [UndoChangeRecord] = []
}

// MARK: - Restore planning

/// Why a path cannot be restored safely right now.
enum UndoConflictReason: Codable, Equatable, Sendable {
    /// The file no longer matches what the recorded change left behind.
    case modifiedSinceChange
    /// Between two changes of the same message something else changed the file.
    case modifiedBetweenChanges
    /// Changes of an already retracted message, made later, were never restored.
    case leftoverChanges(messageIDs: [UUID])
    /// A directory on the way to the path was replaced by a link or a file: restoring would
    /// write somewhere else.
    case pathRedirected
}

struct UndoPathConflict: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let reason: UndoConflictReason
}

/// One path's restore: from `expected` (what the turn left) back to `target`.
struct UndoRestoreItem: Equatable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let location: AnchoredPath
    let expected: UndoFileState
    let target: UndoFileState
    let recordIDs: [UUID]
    let createdDirectories: [String]
    let source: String
    /// Not selected by default (uncertain authorship).
    let isOptional: Bool

    enum Kind: Sendable { case removeCreated, restoreContent, recreateDeleted }
    var kind: Kind {
        if case .absent = target { return .removeCreated }
        if case .absent = expected { return .recreateDeleted }
        return .restoreContent
    }
}

/// An effect of the turn that undo cannot reverse, listed so the preview is honest.
struct UndoIrreversibleEffect: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String
}

/// What undoing a message would do, computed without changing anything.
struct UndoPreview: Equatable, Sendable {
    let conversationID: UUID
    let messageID: UUID
    var willRestore: [UndoRestoreItem]
    var optional: [UndoRestoreItem]
    var irreversible: [UndoIrreversibleEffect]
    var conflicts: [UndoPathConflict]
    /// Records of this message whose backup is gone; file restore is unavailable and the undo
    /// degrades to retracting the message only.
    var missingBackups: [String]
    /// Leftover changes of retracted messages that the user may choose to include.
    var leftoverMessageIDs: [UUID]
    var includesLeftovers: Bool

    var hasFileChanges: Bool { !willRestore.isEmpty || !optional.isEmpty }
    var isBlocked: Bool { !conflicts.isEmpty || !missingBackups.isEmpty }
    var canIncludeLeftovers: Bool {
        !includesLeftovers && !conflicts.isEmpty && conflicts.allSatisfy {
            if case .leftoverChanges = $0.reason { return true } else { return false }
        }
    }
}

// MARK: - Persistent restore plans

struct UndoRestoreStep: Codable, Equatable, Sendable {
    /// `skipped`: the undo was cancelled before this step was restored; the file stays as it is.
    enum State: String, Codable, Sendable { case pending, done, failed, skipped }
    let path: String
    var location: AnchoredPath? = nil
    let expected: UndoFileState
    let target: UndoFileState
    let recordIDs: [UUID]
    let createdDirectories: [String]
    var state: State
    /// Backup of the content the step replaced, so a cancelled undo can put it back.
    var replaced: UndoFileState?
    var failure: String?

    /// Where the step operates (steps saved before anchors existed: below the path's parent).
    var anchoredLocation: AnchoredPath { location ?? .atParent(of: path) }
}

struct UndoRestorePlan: Codable, Identifiable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// Steps are being applied.
        case restoring
        /// At least one step failed; waiting for the user to continue, keep or cancel.
        case partiallyFailed
        /// All selected steps are done; the message retraction still has to be committed.
        case filesRestored
        case completed
        /// Cancelled: restored steps stay restored, the rest were skipped; the message stays.
        case cancelled
    }
    static let currentSchemaVersion = 1
    var schemaVersion = UndoRestorePlan.currentSchemaVersion
    let id: UUID
    let conversationID: UUID
    let messageID: UUID
    var steps: [UndoRestoreStep]
    var phase: Phase
    /// True when the plan ends by retracting the message (always, except a plain file restore).
    let retractsMessage: Bool
    let createdAt: Date
    var updatedAt: Date

    var failedSteps: [UndoRestoreStep] { steps.filter { $0.state == .failed } }
    var isOpen: Bool { phase == .restoring || phase == .partiallyFailed || phase == .filesRestored }
}
