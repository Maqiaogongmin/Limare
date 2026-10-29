import Foundation

/// Git operations for conversation worktrees: `worktree add`, a status for the details view and
/// for cleanup, `worktree remove`, merging the task into Local and exporting a patch. Git's own
/// checks guard every write (a locked worktree, an unmerged branch, local changes a merge would
/// overwrite); nothing here second-guesses them. All paths are arguments, never shell text.
struct GitWorktreeService: Sendable {
    enum Failure: Error, LocalizedError {
        case unavailable(String)
        case git(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .git(let message): message
            }
        }
    }

    let configuration: GitReviewService.Configuration
    private let runner = BoundedSubprocessRunner()

    init(configuration: GitReviewService.Configuration = .live()) {
        self.configuration = configuration
    }

    typealias Outcome = BoundedSubprocessRunner.Outcome

    /// Runs `/usr/bin/git -C <root> <args>` without a shell. `environment` is added to the fixed one.
    func git(_ root: URL, _ arguments: [String], timeout: TimeInterval = 30, allowFailure: Bool = false,
             environment: [String: String] = [:], standardInputFile: URL? = nil,
             outputLimit: Int = 8 * 1024 * 1024) async throws -> Outcome {
        guard await configuration.commandLineToolsInstalled() else {
            throw Failure.unavailable(String(localized: "Git is unavailable. Install the Xcode Command Line Tools first."))
        }
        let result = await runner.run(.init(executable: configuration.gitURL,
                                            arguments: ["-C", root.path, "--no-pager"] + arguments,
                                            environment: configuration.environment.merging(environment) { $1 },
                                            standardInputFile: standardInputFile,
                                            timeoutSeconds: timeout, outputLimitBytes: outputLimit))
        if result.cancelled { throw CancellationError() }
        guard result.launched else { throw Failure.unavailable(result.launchError ?? String(localized: "Git couldn't be started.")) }
        guard !result.timedOut else { throw Failure.git(String(localized: "Git took too long to answer.")) }
        guard !result.stdoutTruncated else { throw Failure.git(String(localized: "Git's output was too large.")) }
        if !allowFailure && result.exitCode != 0 { throw Failure.git(GitReviewService.summary(result.stderr)) }
        return result
    }

    private func value(_ root: URL, _ args: [String]) async throws -> String {
        try await git(root, args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Availability

    /// Why a run can't use `worktree`, or nil when it can: its directory and `.git` exist, and
    /// `workingDirectory` (a resolved run root), when given, is that directory.
    static func unavailableReason(_ worktree: ConversationWorktree, workingDirectory: URL? = nil) -> String? {
        let root = worktree.workspace.url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return String(localized: "The worktree directory is missing.")
        }
        if let workingDirectory, canonical(workingDirectory) != canonical(root) {
            return String(localized: "The run would start outside the worktree.")
        }
        return nil
    }

    static func slug(_ name: String) -> String {
        let chars = name.lowercased().unicodeScalars.map { scalar -> Character in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(chars).split(separator: "-").joined(separator: "-")
        return result.isEmpty ? "project" : String(result.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Branches

    /// Local's branches, and the one it is on (nil when detached).
    func localBranches(root: URL) async throws -> (current: String?, branches: [String]) {
        let current = try await git(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], allowFailure: true)
        let refs = try await value(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return (current.exitCode == 0 ? current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                refs.split(separator: "\n").map(String.init))
    }

    /// The worktree's branch, or its short commit when detached.
    func currentBranch(_ worktree: ConversationWorktree) async -> String? {
        let root = worktree.workspace.url
        if let branch = try? await git(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], allowFailure: true), branch.exitCode == 0 {
            return branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try? await value(root, ["rev-parse", "--short", "HEAD"]).nonEmpty.map { "HEAD \($0)" }
    }

    // MARK: - Creating

    /// Adds a worktree for `conversationID` on a new branch from `baseBranch` (Local's HEAD when
    /// nil), then copies what `.worktreeinclude` names. A copy that fails is reported in
    /// `includeWarning`; the worktree is still created.
    func create(repositoryRoot: URL, conversationID: UUID, baseBranch: String?, managedRoot: URL,
                branchPrefix: String) async throws -> (worktree: ConversationWorktree, includeWarning: String?) {
        let top = try await git(repositoryRoot, ["rev-parse", "--show-toplevel"], allowFailure: true)
        guard top.exitCode == 0 else {
            throw Failure.unavailable(String(localized: "This folder is not a Git repository."))
        }
        let root = URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
        guard Self.canonical(root) == Self.canonical(repositoryRoot) else {
            throw Failure.unavailable(String(localized: "Open the repository root as the project folder."))
        }
        let baseRef = baseBranch.map { "refs/heads/\($0)" } ?? "HEAD"
        let resolved = try await git(root, ["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"], allowFailure: true)
        guard resolved.exitCode == 0 else {
            throw Failure.unavailable(baseBranch == nil
                ? String(localized: "Create the repository's first commit before creating a worktree.")
                : String(localized: "The base branch no longer exists."))
        }
        let commit = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        if let baseBranch { baseName = baseBranch }
        else { baseName = try await localBranches(root: root).current ?? "HEAD" }

        // A conversation that had a worktree before may have left its branch or folder behind.
        let stem = "\(Self.slug(root.lastPathComponent))-\(conversationID.uuidString.lowercased().prefix(8))"
        var name = stem, branch = "\(branchPrefix)/\(stem)"
        for suffix in 2... {
            let taken = try await git(root, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], allowFailure: true)
            if taken.exitCode != 0, !FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent(name).path) { break }
            name = "\(stem)-\(suffix)"
            branch = "\(branchPrefix)/\(name)"
        }
        let target = managedRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        _ = try await git(root, ["worktree", "add", "--no-track", "-b", branch, "--", target.path, commit], timeout: 300)

        let worktree = ConversationWorktree(repositoryRoot: root.path, workspace: .from(url: target), branch: branch,
                                            baseName: baseName, baseCommit: commit, createdAt: Date())
        var warning: String?
        do {
            let failures = try await WorktreeIncludeService.copy(from: root, to: target, git: self)
            if !failures.isEmpty {
                warning = String(localized: ".worktreeinclude: \(failures.count) files couldn't be copied (\(failures.prefix(3).joined(separator: ", "))).")
            }
        } catch {
            warning = String(localized: ".worktreeinclude: nothing was copied (\(error.localizedDescription)).")
        }
        return (worktree, warning)
    }

    // MARK: - Status

    func status(_ worktree: ConversationWorktree) async throws -> WorktreeStatus {
        let root = worktree.workspace.url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return WorktreeStatus(exists: false)
        }
        let output = try await git(root, ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
        let report = try GitDiffParser.parseStatus(output.stdoutData)
        var status = WorktreeStatus(exists: true, branch: report.head, head: report.oid)
        status.changedPaths = report.entries.filter { $0.kind == .unmerged || $0.isStaged || $0.isUnstaged }.map(\.path).sorted()
        status.untrackedPaths = report.entries.filter { $0.kind == .untracked }.map(\.path).sorted()
        if let head = report.oid {
            status.commitsSinceBase = Int(try await value(root, ["rev-list", "--count", "\(worktree.baseCommit)..\(head)"]))
            if report.head == nil, head != worktree.baseCommit {
                let containing = try await value(root, ["for-each-ref", "--count=1", "--contains", head, "--format=%(refname)",
                                                        "refs/heads", "refs/remotes"])
                status.hasUnreferencedCommit = containing.isEmpty
            }
        }
        return status
    }

    // MARK: - Removing

    /// Removes the worktree's directory (or prunes its registration when the directory is already
    /// gone), then its branch when the branch holds nothing: no commits past the base, or merged
    /// into Local (`branch -d`). Returns whether the branch was kept.
    func remove(_ worktree: ConversationWorktree) async throws -> Bool {
        let root = URL(fileURLWithPath: worktree.repositoryRoot, isDirectory: true)
        if FileManager.default.fileExists(atPath: worktree.workspace.path) {
            _ = try await git(root, ["worktree", "remove", "--force", "--", worktree.workspace.path], timeout: 300)
        } else {
            _ = try await git(root, ["worktree", "prune"])
        }
        let ref = "refs/heads/\(worktree.branch)"
        let tip = try await git(root, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], allowFailure: true)
        guard tip.exitCode == 0 else { return false }
        let unchanged = tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == worktree.baseCommit
        let deleted = try await git(root, ["branch", unchanged ? "-D" : "-d", "--", worktree.branch], allowFailure: true)
        return deleted.exitCode != 0
    }

    // MARK: - Merging

    func mergeSummary(_ worktree: ConversationWorktree) async throws -> WorktreeMergeSummary {
        let root = URL(fileURLWithPath: worktree.repositoryRoot, isDirectory: true)
        let task = try await status(worktree)
        guard task.exists, let taskHead = task.head else {
            throw Failure.unavailable(String(localized: "The worktree directory is missing."))
        }
        let local = try await localBranches(root: root).current
        let localHead = try await value(root, ["rev-parse", "--verify", "HEAD^{commit}"])
        let commits = Int(try await value(root, ["rev-list", "--count", "\(localHead)..\(taskHead)"])) ?? 0
        return WorktreeMergeSummary(localBranch: local, taskBranch: task.branch,
                                    uncommittedCount: task.changedPaths.count + task.untrackedPaths.count, commitsToMerge: commits)
    }

    /// Commits the worktree's uncommitted changes with `commitMessage`, then merges its HEAD into
    /// Local's branch with `--no-ff`. Git refuses on its own when Local's changes or ignored files
    /// would be overwritten; a conflicted merge is aborted, leaving Local as it was. Returns
    /// Local's new HEAD. Nothing is pushed.
    func merge(_ worktree: ConversationWorktree, commitMessage: String) async throws -> String {
        let root = URL(fileURLWithPath: worktree.repositoryRoot, isDirectory: true)
        let taskRoot = worktree.workspace.url
        let summary = try await mergeSummary(worktree)
        guard summary.localBranch != nil else {
            throw Failure.unavailable(String(localized: "Local isn't on a branch; check out a branch in Local first."))
        }
        if summary.uncommittedCount > 0 {
            _ = try await git(taskRoot, ["add", "-A"], timeout: 120)
            _ = try await git(taskRoot, ["commit", "-m", commitMessage], timeout: 300)
        }
        let taskHead = try await value(taskRoot, ["rev-parse", "--verify", "HEAD^{commit}"])
        let merge = try await git(root, ["merge", "--no-ff", "--no-edit", "--no-overwrite-ignore", taskHead],
                                  timeout: 300, allowFailure: true)
        if merge.exitCode != 0 {
            let merging = try await git(root, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], allowFailure: true)
            guard merging.exitCode == 0 else { throw Failure.git(GitReviewService.summary(merge.stderr + merge.stdout)) }
            let conflicted = try await git(root, ["diff", "--name-only", "--diff-filter=U", "-z"], allowFailure: true)
            let paths = GitDiffParser.fields(conflicted.stdoutData).map(\.text)
            _ = try await git(root, ["merge", "--abort"], timeout: 120)
            throw Failure.git(String(localized: "The merge has conflicts in \(paths.prefix(5).joined(separator: ", ")); it was undone and Local was left as it was. The task's changes are committed on \(worktree.branch)."))
        }
        return try await value(root, ["rev-parse", "--verify", "HEAD^{commit}"])
    }

    // MARK: - Patch

    /// Everything the worktree holds since its base, new files included, as a binary-safe patch.
    /// Built in a throwaway index, so the worktree's own index is never touched.
    func exportPatch(_ worktree: ConversationWorktree) async throws -> Data {
        let root = worktree.workspace.url
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("limare-patch-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        _ = try await git(root, ["read-tree", "HEAD"], environment: environment)
        _ = try await git(root, ["add", "-A"], timeout: 120, environment: environment)
        return try await git(root, ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv", worktree.baseCommit],
                             timeout: 120, environment: environment, outputLimit: 256 * 1024 * 1024).stdoutData
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
