import Foundation

/// A conversation's Git worktree: where it lives, the repository it belongs to, and the branch
/// and commit it started from.
struct ConversationWorktree: Codable, Equatable, Sendable {
    var repositoryRoot: String
    var workspace: WorkspaceConfiguration
    var branch: String
    var baseName: String
    var baseCommit: String
    var createdAt: Date
}

/// What a worktree holds now, read by `GitWorktreeService.status`.
struct WorktreeStatus: Sendable, Equatable {
    var exists: Bool
    var branch: String?
    var head: String?
    /// Staged, unstaged and conflicted paths.
    var changedPaths: [String] = []
    var untrackedPaths: [String] = []
    var commitsSinceBase: Int?
    /// A detached HEAD whose commit no branch contains.
    var hasUnreferencedCommit = false
    var readAt = Date()

    /// Work that exists only in this directory: removing it would lose it.
    var hasUnsavedWork: Bool { !changedPaths.isEmpty || !untrackedPaths.isEmpty || hasUnreferencedCommit }
}

struct WorktreeMergeSummary: Sendable, Equatable {
    var localBranch: String?
    var taskBranch: String?
    /// Uncommitted and untracked paths, committed before the merge.
    var uncommittedCount: Int
    /// Task commits Local doesn't have yet.
    var commitsToMerge: Int

    var hasNothingToMerge: Bool { uncommittedCount == 0 && commitsToMerge == 0 }
}
