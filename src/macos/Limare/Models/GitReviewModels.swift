import Foundation

// The Changes surface: what Git says changed in the project, read-only, with line comments the
// user hands to the conversation. Every type here is a value; reading Git and parsing its output
// happen off the main actor (`GitReviewService`, `GitDiffParser`), `GitReviewStore` applies them.

/// Which comparison the Changes surface shows. The old and new sides of a line number depend on it.
enum GitReviewScope: String, CaseIterable, Codable, Sendable, Identifiable {
    /// HEAD → working tree: everything uncommitted, staged or not, plus untracked files.
    case all
    /// Index → working tree, plus untracked files.
    case unstaged
    /// HEAD → index.
    case staged
    /// merge-base(base, HEAD) → HEAD: committed changes only.
    case branch
    /// A worktree conversation's base commit → working tree: everything its task changed,
    /// committed or not, untracked files included.
    case task

    var id: String { rawValue }

    /// The scope's name in comments sent to the conversation. Model-facing, so English.
    var messageLabel: String {
        switch self {
        case .all: "All"
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        case .branch: "Branch"
        case .task: "Since task base"
        }
    }

    /// Whether the scope reads the working tree, where untracked files and conflicts live.
    var isUncommitted: Bool { self != .branch }
    /// Whether the new side of its diff is the working tree.
    var readsWorkingTree: Bool { self == .all || self == .unstaged || self == .task }
}

/// Which side of a diff a line number counts on.
enum GitDiffSide: String, Codable, Sendable, Hashable {
    case old
    case new
}

/// What happened to a file in the shown scope.
enum GitFileStatus: String, Sendable, Equatable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case typeChanged
    case conflicted
    case untracked

    /// The letter Git uses for it.
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .conflicted: "U"
        case .untracked: "?"
        }
    }

    /// From a status letter of `git diff --name-status` or porcelain v2's X/Y.
    init?(gitLetter: Character) {
        switch gitLetter {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        case "U": self = .conflicted
        default: return nil
        }
    }

    /// The order of the file list's groups.
    var groupOrder: Int {
        switch self {
        case .conflicted: 0
        case .modified, .typeChanged: 1
        case .added: 2
        case .deleted: 3
        case .renamed, .copied: 4
        case .untracked: 5
        }
    }
}

/// Under All, where a file's changes sit.
enum GitStageMark: String, Sendable, Equatable {
    case staged
    case unstaged
    case both
    case untracked
}

/// One file in the shown scope.
struct GitChangedFile: Sendable, Equatable, Identifiable {
    /// The path relative to the repository root, the new one for a rename.
    var path: String
    /// The path before a rename or copy.
    var oldPath: String?
    var status: GitFileStatus
    /// Rename or copy similarity, 0–100.
    var similarity: Int?
    /// Lines added and removed; nil when Git counts none (binary, untracked, no net change).
    var additions: Int?
    var deletions: Int?
    var isBinary = false
    var isSubmodule = false
    /// A submodule whose only change is inside its own working tree.
    var submoduleDirtyOnly = false
    /// Under All only.
    var stageMark: GitStageMark?
    /// Under All: listed by `git status` but HEAD and the working tree hold the same content.
    var hasNoNetChange = false
    /// Git's path bytes were not UTF-8; the shown path is a lossy decoding Git can't be asked about.
    var pathIsLossy = false

    var id: String { path }

    /// Lines changed in total, for the inline-rendering limit.
    var changedLineCount: Int { (additions ?? 0) + (deletions ?? 0) }
}

/// The branch the repository is on.
enum GitBranchState: Sendable, Equatable {
    case branch(String)
    case detached(shortSHA: String)
    /// No commit yet: `branch.oid (initial)`.
    case unborn(String)
}

/// One read of the shown scope's file list.
struct GitReviewSnapshot: Sendable, Equatable {
    var repositoryRoot: URL
    var branch: GitBranchState
    /// The full HEAD commit, nil before the first commit.
    var head: String?
    var scope: GitReviewScope
    /// The base the Branch scope compares against.
    var base: String?
    var files: [GitChangedFile]
    var readAt: Date

    var hasHead: Bool { head != nil }
    /// Tracked files' totals; untracked files are not counted.
    var totalAdditions: Int { files.reduce(0) { $0 + ($1.additions ?? 0) } }
    var totalDeletions: Int { files.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

/// A line of a hunk.
struct GitDiffLine: Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable, Equatable {
        case context
        case added
        case removed
    }

    var kind: Kind
    var oldLine: Int?
    var newLine: Int?
    var text: String
    /// Followed by Git's "\ No newline at end of file".
    var noNewlineAtEnd = false

    var id: String { "\(oldLine ?? -1):\(newLine ?? -1):\(kind)" }

    /// The side and number a comment on this line anchors to: the new side unless the line was removed.
    var anchorSide: GitDiffSide { kind == .removed ? .old : .new }
    var anchorLine: Int? { kind == .removed ? oldLine : newLine }
}

struct GitDiffHunk: Sendable, Equatable, Identifiable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    /// The text after the second `@@`, often the enclosing function.
    var section: String
    var lines: [GitDiffLine]

    var id: String { "\(oldStart),\(oldCount),\(newStart),\(newCount)" }
    var header: String {
        let range = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        return section.isEmpty ? range : "\(range) \(section)"
    }
}

/// One `diff --git` section. A file's patch usually has one; a type change has two.
struct GitDiffSection: Sendable, Equatable, Identifiable {
    var oldPath: String?
    var newPath: String?
    var oldMode: String?
    var newMode: String?
    var isNewFile = false
    var isDeletedFile = false
    var renameFrom: String?
    var renameTo: String?
    var copyFrom: String?
    var copyTo: String?
    var similarity: Int?
    var isBinary = false
    var hunks: [GitDiffHunk]

    var id: String { "\(oldPath ?? "")→\(newPath ?? "")" }
    /// Mode 160000 on either side.
    var isSubmodule: Bool { oldMode == "160000" || newMode == "160000" }
    var hasModeChange: Bool { oldMode != nil && newMode != nil && oldMode != newMode && !isNewFile && !isDeletedFile }
}

/// One file's diff, as `git diff` printed it (or as synthesized for an untracked file).
struct GitDiffDocument: Sendable, Equatable {
    var sections: [GitDiffSection]

    var lines: [GitDiffLine] { sections.flatMap { $0.hunks.flatMap(\.lines) } }

    /// The line a comment anchored at `side`/`number` points at now, if any.
    func line(side: GitDiffSide, number: Int) -> GitDiffLine? {
        lines.first { $0.anchorSide == side && $0.anchorLine == number }
    }
}

/// Where a comment points: a line on one side of one file's diff in one scope (against one base,
/// for Branch), with the text it had when the comment was written.
struct GitLineAnchor: Codable, Sendable, Hashable {
    var scope: GitReviewScope
    /// The base Branch compared against; nil for the other scopes.
    var base: String?
    var path: String
    var side: GitDiffSide
    var line: Int
    /// The line's text when commented, at most `quoteLimit` characters.
    var quote: String
    /// The line was removed (old side) or added (new side), rather than context.
    var lineKind: GitDiffLine.Kind

    static let quoteLimit = 500

    init(scope: GitReviewScope, base: String? = nil, path: String, line: GitDiffLine) {
        self.scope = scope
        self.base = scope == .branch ? base : nil
        self.path = path
        self.side = line.anchorSide
        self.line = line.anchorLine ?? 0
        self.quote = String(line.text.prefix(Self.quoteLimit))
        self.lineKind = line.kind
    }

    /// One comment per line: the same scope and base, file, side and number.
    var key: Key { Key(scope: scope, base: base, path: path, side: side, line: line) }

    struct Key: Sendable, Hashable {
        var scope: GitReviewScope
        var base: String?
        var path: String
        var side: GitDiffSide
        var line: Int
    }

    /// Whether `current` still holds the commented text; a trailing `\r` doesn't count.
    func matches(_ current: GitDiffLine) -> Bool {
        func trimmed(_ text: String) -> Substring {
            let prefix = text.prefix(Self.quoteLimit)
            return prefix.hasSuffix("\r") ? prefix.dropLast() : prefix[...]
        }
        return trimmed(current.text) == trimmed(quote)
    }
}

/// A comment the user wrote on a line.
struct GitReviewComment: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var anchor: GitLineAnchor
    var body: String
    var createdAt: Date
    /// The anchored line no longer holds the quoted text, or is gone.
    var isOutdated = false

    init(id: UUID = UUID(), anchor: GitLineAnchor, body: String, createdAt: Date = Date(), isOutdated: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.isOutdated = isOutdated
    }
}

/// Why the Changes surface has no repository to show.
enum GitRepositoryUnavailable: Sendable, Equatable {
    /// The Command Line Tools are missing; `/usr/bin/git` would only offer to install them.
    case gitNotInstalled
    case notRepository(nestedRepository: String?)
    /// The workspace sits inside a repository whose root is elsewhere.
    case notRepositoryRoot(repositoryRoot: String)
    /// Git ran but refused: dubious ownership, permissions, a broken repository.
    case gitFailed(String)
}
