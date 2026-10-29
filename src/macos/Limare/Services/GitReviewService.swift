import Foundation

/// Reads a repository for the Changes surface with the system Git, read-only: `status`, `diff`,
/// `for-each-ref`, `rev-parse`, `merge-base`, `symbolic-ref`, `config --get`. It never writes the
/// index or the working tree and never fetches. Output is parsed off the main actor.
struct GitReviewService: Sendable {
    struct Configuration: Sendable {
        var gitURL = URL(fileURLWithPath: "/usr/bin/git")
        /// The whole environment Git runs with; nothing else is inherited, no caller `GIT_*` either.
        var environment: [String: String]
        /// Whether the Command Line Tools are installed. Without them `/usr/bin/git` is only a shim
        /// that offers to install them, so it is never started.
        var commandLineToolsInstalled: @Sendable () async -> Bool

        static func live() -> Configuration {
            let process = ProcessInfo.processInfo.environment
            var environment = fixedEnvironment
            for key in ["HOME", "PATH", "TMPDIR"] {
                if let value = process[key] { environment[key] = value }
            }
            return Configuration(environment: environment, commandLineToolsInstalled: { await commandLineTools.installed() })
        }

        private static let commandLineTools = CommandLineToolsCheck()

        /// No optional locks (status would refresh the index), no prompts, no lazy fetch of missing
        /// objects in a partial clone, and untranslated messages.
        static let fixedEnvironment: [String: String] = [
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_NO_LAZY_FETCH": "1",
            "LC_ALL": "C",
        ]
    }

    enum Location: Sendable, Equatable {
        case repository(root: URL)
        case unavailable(GitRepositoryUnavailable)
    }

    enum Failure: Error, Equatable, LocalizedError {
        case launch(String)
        case timedOut
        case outputTooLarge
        case git(String)
        case noCommonHistory(base: String)
        case requiresCommit
        case parse(String)

        var errorDescription: String? {
            switch self {
            case .launch(let detail): String(localized: "Git couldn't be started: \(detail)")
            case .timedOut: String(localized: "Git took too long to answer.")
            case .outputTooLarge: String(localized: "Git's file list is too large to show.")
            case .git(let summary): summary
            case .noCommonHistory(let base): String(localized: "This branch and \(base) have no common history.")
            case .requiresCommit: String(localized: "This view needs at least one commit.")
            case .parse(let detail): String(localized: "Git's output couldn't be read: \(detail)")
            }
        }
    }

    /// What one file's diff came to.
    enum PatchResult: Sendable, Equatable {
        case document(GitDiffDocument)
        /// Too many changed lines, or a patch over the byte limit (`lineCount` nil).
        case tooLarge(lineCount: Int?)
        /// The working tree's size when there is one to read.
        case binary(byteCount: Int?)
        case conflicted
        case noNetChange
        case untrackedNote(UntrackedNote)
        /// The path isn't UTF-8, so it can't be handed back to Git.
        case pathUnreadable
        case failed(String)
    }

    /// Why an untracked file is shown as metadata only.
    enum UntrackedNote: Sendable, Equatable {
        case symbolicLink(destination: String)
        case directory
        case tooLarge(byteCount: Int)
        case binary(byteCount: Int)
        case unreadable(String)
    }

    struct BaseChoices: Sendable, Equatable {
        var candidates: [String]
        var defaultBase: String?
    }

    static let maximumInlineLines = 5_000
    static let maximumPatchBytes = 2 * 1024 * 1024
    static let maximumListingBytes = 8 * 1024 * 1024
    static let listingTimeout: TimeInterval = 10
    static let patchTimeout: TimeInterval = 15
    /// Used for every listing and every patch, so the file list and its patches agree on renames
    /// even when `diff.renames` is off, and textconv or an external diff can't reshape the lines.
    static let diffOptions = ["--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"]

    let configuration: Configuration
    private let runner = BoundedSubprocessRunner()

    init(configuration: Configuration = .live()) {
        self.configuration = configuration
    }

    // MARK: - Locating

    /// Finds the repository the workspace is the root of.
    func locate(workspace: URL) async -> Location {
        guard await configuration.commandLineToolsInstalled() else { return .unavailable(.gitNotInstalled) }
        let inside: Outcome
        do {
            inside = try await git(in: workspace, ["rev-parse", "--is-inside-work-tree"], timeout: Self.listingTimeout,
                                   allowFailure: true)
        } catch {
            return .unavailable(.gitFailed(error.localizedDescription))
        }
        if inside.exitCode != 0 {
            // No `.git` in the folder or above it is a plain folder; anything else is Git refusing
            // a repository (dubious ownership, permissions, a broken repository).
            if Self.enclosingGitEntry(of: workspace) == nil {
                return .unavailable(.notRepository(nestedRepository: Self.nestedRepository(in: workspace)))
            }
            return .unavailable(.gitFailed(Self.summary(inside.stderr)))
        }
        guard inside.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return .unavailable(.notRepository(nestedRepository: nil))
        }
        do {
            let top = try await git(in: workspace, ["rev-parse", "--show-toplevel"], timeout: Self.listingTimeout)
            let toplevel = URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .newlines), isDirectory: true)
            if Self.canonical(toplevel) != Self.canonical(workspace) {
                return .unavailable(.notRepositoryRoot(repositoryRoot: toplevel.path))
            }
            return .repository(root: workspace)
        } catch {
            return .unavailable(.gitFailed(error.localizedDescription))
        }
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The nearest `.git` at or above `folder`.
    static func enclosingGitEntry(of folder: URL) -> URL? {
        var current = folder.standardizedFileURL
        while true {
            let entry = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: entry.path) { return entry }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// A direct subfolder that is a repository of its own, named in the "open it instead" hint.
    /// One level only; nothing is searched deeper.
    static func nestedRepository(in workspace: URL) -> String? {
        let children = (try? FileManager.default.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey],
                                                                      options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .map(\.lastPathComponent)
            .sorted()
            .first
    }

    // MARK: - File list

    /// `base` is the branch Branch compares against, or the task's base commit for Task.
    func readSnapshot(root: URL, scope: GitReviewScope, base: String?) async throws -> GitReviewSnapshot {
        let statusOutput = try await git(in: root, ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"],
                                         timeout: Self.listingTimeout, limit: Self.maximumListingBytes)
        let status = try parse { try GitDiffParser.parseStatus(statusOutput.stdoutData) }
        let branch: GitBranchState
        switch (status.head, status.oid) {
        case (let name?, nil): branch = .unborn(name)
        case (let name?, _): branch = .branch(name)
        case (nil, let oid?): branch = .detached(shortSHA: String(oid.prefix(7)))
        case (nil, nil): branch = .unborn("")
        }
        if status.oid == nil, scope != .unstaged, scope != .staged { throw Failure.requiresCommit }

        let files: [GitChangedFile]
        switch scope {
        case .all:
            let names = try await nameStatus(root, ["HEAD"])
            let counts = try await numstat(root, ["HEAD"])
            files = Self.allFiles(status: status.entries, names: names, counts: counts)
        case .unstaged:
            let counts = try await numstat(root, [])
            files = Self.unstagedFiles(status: status.entries, counts: counts)
        case .staged:
            // From diff, not from status: status.renames follows diff.renames, so with renames off
            // status would list a rename as a delete and an add while the patch pairs them.
            let names = try await nameStatus(root, ["--cached"])
            let counts = try await numstat(root, ["--cached"])
            files = Self.stagedFiles(status: status.entries, names: names, counts: counts)
        case .branch:
            guard let base else { throw Failure.git(String(localized: "Choose a base to compare against.")) }
            try await requireCommonHistory(root, base: base)
            let names = try await nameStatus(root, ["\(base)...HEAD"])
            let counts = try await numstat(root, ["\(base)...HEAD"])
            files = Self.committedFiles(names: names, counts: counts)
        case .task:
            guard let base else { throw Failure.git(String(localized: "This conversation has no task base.")) }
            let names = try await nameStatus(root, [base])
            let counts = try await numstat(root, [base])
            files = Self.taskFiles(status: status.entries, names: names, counts: counts)
        }
        return GitReviewSnapshot(repositoryRoot: root, branch: branch, head: status.oid, scope: scope,
                                 base: scope == .branch || scope == .task ? base : nil, files: Self.sorted(files), readAt: Date())
    }

    private func nameStatus(_ root: URL, _ args: [String]) async throws -> [GitNameStatusRecord] {
        let output = try await git(in: root, ["diff"] + Self.diffOptions + ["--name-status", "-z"] + args,
                                   timeout: Self.listingTimeout, limit: Self.maximumListingBytes)
        return try parse { try GitDiffParser.parseNameStatus(output.stdoutData) }
    }

    private func numstat(_ root: URL, _ args: [String]) async throws -> [GitNumstatRecord] {
        let output = try await git(in: root, ["diff"] + Self.diffOptions + ["--numstat", "-z"] + args,
                                   timeout: Self.listingTimeout, limit: Self.maximumListingBytes)
        return try parse { try GitDiffParser.parseNumstat(output.stdoutData) }
    }

    private func requireCommonHistory(_ root: URL, base: String) async throws {
        let output = try await git(in: root, ["merge-base", base, "HEAD"], timeout: Self.listingTimeout, allowFailure: true)
        switch output.exitCode {
        case 0: return
        case 1: throw Failure.noCommonHistory(base: base)
        default: throw Failure.git(Self.summary(output.stderr))
        }
    }

    private func parse<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Failure.parse(error.localizedDescription) }
    }

    /// All: every path `git status` lists, with HEAD → working tree's net status and counts.
    /// A path with no net change stays listed, marked, rather than disappearing.
    static func allFiles(status: [GitStatusEntry], names: [GitNameStatusRecord], counts: [GitNumstatRecord]) -> [GitChangedFile] {
        let statusPaths = Set(status.map(\.path))
        let namesByPath = Dictionary(names.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let namesByOldPath = Dictionary(names.compactMap { name in name.oldPath.map { ($0, name) } }, uniquingKeysWith: { first, _ in first })
        let countsByPath = countIndex(counts)
        var files: [GitChangedFile] = []
        var seen: Set<String> = []
        for entry in status {
            var file: GitChangedFile
            switch entry.kind {
            case .untracked:
                file = GitChangedFile(path: entry.path, status: .untracked, stageMark: .untracked)
            case .unmerged:
                file = GitChangedFile(path: entry.path, status: .conflicted)
            case .ordinary, .renamed:
                let mark: GitStageMark = entry.isStaged && entry.isUnstaged ? .both : (entry.isStaged ? .staged : .unstaged)
                if let name = namesByPath[entry.path] ?? entry.origPath.flatMap({ namesByPath[$0] }) {
                    file = GitChangedFile(path: name.path, oldPath: name.oldPath, status: name.status, similarity: name.similarity,
                                          stageMark: mark)
                } else if let name = namesByOldPath[entry.path], statusPaths.contains(name.path) {
                    // The source of a rename Git paired across the index and the working tree; the
                    // rename's own row shows it.
                    continue
                } else {
                    let letter = entry.isUnstaged ? entry.y : entry.x
                    file = GitChangedFile(path: entry.path, status: GitFileStatus(gitLetter: letter) ?? .modified,
                                          stageMark: mark, hasNoNetChange: true)
                }
                if let count = countsByPath[file.path] {
                    file.additions = count.additions
                    file.deletions = count.deletions
                    file.isBinary = count.isBinary
                }
            }
            apply(entry, to: &file)
            if seen.insert(file.path).inserted { files.append(file) }
        }
        return files
    }

    /// Staged (HEAD → index): what `diff --cached` lists, with conflicts and submodules from status.
    static func stagedFiles(status: [GitStatusEntry], names: [GitNameStatusRecord], counts: [GitNumstatRecord]) -> [GitChangedFile] {
        withStatus(committedFiles(names: names, counts: counts), status: status, includingUntracked: false)
    }

    /// Task (task base → working tree): what diff lists against the base, with conflicts,
    /// submodules and untracked files from status.
    static func taskFiles(status: [GitStatusEntry], names: [GitNameStatusRecord], counts: [GitNumstatRecord]) -> [GitChangedFile] {
        withStatus(committedFiles(names: names, counts: counts), status: status, includingUntracked: true)
    }

    private static func withStatus(_ listed: [GitChangedFile], status: [GitStatusEntry], includingUntracked: Bool) -> [GitChangedFile] {
        var files = listed
        let entries = Dictionary(status.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for index in files.indices {
            if let entry = entries[files[index].path] {
                if entry.kind == .unmerged { files[index].status = .conflicted }
                apply(entry, to: &files[index])
            }
        }
        var listedPaths = Set(files.map(\.path))
        for entry in status where !listedPaths.contains(entry.path) {
            switch entry.kind {
            case .unmerged: files.append(GitChangedFile(path: entry.path, status: .conflicted, pathIsLossy: entry.pathIsLossy))
            case .untracked where includingUntracked: files.append(GitChangedFile(path: entry.path, status: .untracked, pathIsLossy: entry.pathIsLossy))
            default: continue
            }
            listedPaths.insert(entry.path)
        }
        return files
    }

    /// Unstaged (index → working tree), from each path's Y status, with conflicts and untracked files.
    static func unstagedFiles(status: [GitStatusEntry], counts: [GitNumstatRecord]) -> [GitChangedFile] {
        let countsByPath = countIndex(counts)
        var files: [GitChangedFile] = []
        for entry in status {
            var file: GitChangedFile
            switch entry.kind {
            case .untracked:
                file = GitChangedFile(path: entry.path, status: .untracked)
            case .unmerged:
                file = GitChangedFile(path: entry.path, status: .conflicted)
            case .ordinary, .renamed:
                guard entry.y != ".", let status = GitFileStatus(gitLetter: entry.y) else { continue }
                file = GitChangedFile(path: entry.path, status: status)
                if let count = countsByPath[entry.path] {
                    file.additions = count.additions
                    file.deletions = count.deletions
                    file.isBinary = count.isBinary
                }
            }
            apply(entry, to: &file)
            files.append(file)
        }
        return files
    }

    /// Branch: what the commits since the merge base changed.
    static func committedFiles(names: [GitNameStatusRecord], counts: [GitNumstatRecord]) -> [GitChangedFile] {
        let countsByPath = countIndex(counts)
        return names.map { name in
            var file = GitChangedFile(path: name.path, oldPath: name.oldPath, status: name.status, similarity: name.similarity,
                                      pathIsLossy: name.pathIsLossy)
            if let count = countsByPath[name.path] {
                file.additions = count.additions
                file.deletions = count.deletions
                file.isBinary = count.isBinary
            }
            return file
        }
    }

    private static func countIndex(_ counts: [GitNumstatRecord]) -> [String: GitNumstatRecord] {
        Dictionary(counts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func apply(_ entry: GitStatusEntry, to file: inout GitChangedFile) {
        file.pathIsLossy = file.pathIsLossy || entry.pathIsLossy
        if let submodule = entry.submodule {
            file.isSubmodule = true
            file.submoduleDirtyOnly = !submodule.commitChanged && (submodule.trackedChanges || submodule.untrackedChanges)
        }
    }

    static func sorted(_ files: [GitChangedFile]) -> [GitChangedFile] {
        files.sorted { lhs, rhs in
            lhs.status.groupOrder != rhs.status.groupOrder
                ? lhs.status.groupOrder < rhs.status.groupOrder
                : lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    // MARK: - Bases

    /// Local and remote branches to compare against, the current branch and `*/HEAD` left out.
    /// The default is what `origin/HEAD` points at, else `init.defaultBranch` when it exists;
    /// never the upstream, which usually shows only unpushed commits.
    func readBaseChoices(root: URL, currentBranch: String?) async throws -> BaseChoices {
        let refs = try await git(in: root, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"],
                                 timeout: Self.listingTimeout, limit: Self.maximumListingBytes)
        let candidates = refs.stdout.split(separator: "\n").compactMap { line -> String? in
            let ref = String(line)
            if ref.hasPrefix("refs/remotes/"), ref.hasSuffix("/HEAD") { return nil }
            let short = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count))
                : ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) : ref
            return short == currentBranch ? nil : short
        }
        var defaultBase: String?
        let originHead = try await git(in: root, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                                       timeout: Self.listingTimeout, allowFailure: true)
        let pointed = originHead.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if originHead.exitCode == 0, candidates.contains(pointed) {
            defaultBase = pointed
        } else {
            let configured = try await git(in: root, ["config", "--get", "init.defaultBranch"], timeout: Self.listingTimeout,
                                           allowFailure: true)
            let name = configured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if configured.exitCode == 0, candidates.contains(name) { defaultBase = name }
        }
        return BaseChoices(candidates: candidates, defaultBase: defaultBase)
    }

    // MARK: - Patches

    func readPatch(root: URL, scope: GitReviewScope, base: String?, file: GitChangedFile) async -> PatchResult {
        if file.pathIsLossy { return .pathUnreadable }
        switch file.status {
        case .conflicted: return .conflicted
        case .untracked: return Self.untrackedPatch(root: root, path: file.path)
        default: break
        }
        if file.hasNoNetChange { return .noNetChange }
        if file.isBinary {
            return .binary(byteCount: scope.readsWorkingTree ? Self.workingTreeSize(root: root, path: file.path) : nil)
        }
        if file.changedLineCount > Self.maximumInlineLines { return .tooLarge(lineCount: file.changedLineCount) }

        var args = ["diff"] + Self.diffOptions + ["--unified=3"]
        switch scope {
        case .all: args.append("HEAD")
        case .unstaged: break
        case .staged: args.append("--cached")
        case .branch:
            guard let base else { return .failed(String(localized: "Choose a base to compare against.")) }
            args.append("\(base)...HEAD")
        case .task:
            guard let base else { return .failed(String(localized: "This conversation has no task base.")) }
            args.append(base)
        }
        // A rename needs both paths, or Git shows the new path as a new file.
        args.append("--")
        if let oldPath = file.oldPath { args.append(oldPath) }
        args.append(file.path)

        do {
            let output = try await git(in: root, args, timeout: Self.patchTimeout, limit: Self.maximumPatchBytes,
                                       truncationIsError: false)
            if output.stdoutTruncated { return .tooLarge(lineCount: nil) }
            let document = try GitDiffParser.parsePatch(output.stdout)
            if document.sections.contains(where: \.isBinary) {
                return .binary(byteCount: scope.readsWorkingTree ? Self.workingTreeSize(root: root, path: file.path) : nil)
            }
            return .document(document)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// An untracked file as one hunk of new lines, read without following links and only inside
    /// the repository. Large or binary files are shown by their size.
    static func untrackedPatch(root: URL, path: String) -> PatchResult {
        let url = root.appendingPathComponent(path)
        let rootPath = canonical(root)
        let parent = canonical(url.deletingLastPathComponent())
        guard parent == rootPath || parent.hasPrefix(rootPath + "/") else {
            return .untrackedNote(.unreadable(String(localized: "The file is outside the repository.")))
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return .untrackedNote(.unreadable(error.localizedDescription))
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .untrackedNote(.symbolicLink(destination: destination))
        }
        if type == .typeDirectory { return .untrackedNote(.directory) }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if size > maximumPatchBytes { return .untrackedNote(.tooLarge(byteCount: size)) }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return .untrackedNote(.unreadable(String(localized: "The file couldn't be read.")))
        }
        if data.contains(0) { return .untrackedNote(.binary(byteCount: data.count)) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        if lines > maximumInlineLines { return .tooLarge(lineCount: lines) }
        return .document(GitDiffParser.untrackedDocument(path: path, text: text))
    }

    static func workingTreeSize(root: URL, path: String) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    // MARK: - Running Git

    typealias Outcome = BoundedSubprocessRunner.Outcome

    /// Runs `/usr/bin/git -C <root> --no-pager --literal-pathspecs <args>` without a shell.
    /// A nonzero exit throws unless `allowFailure`; output past `limit` throws unless the caller
    /// handles truncation itself.
    private func git(in root: URL, _ args: [String], timeout: TimeInterval, limit: Int = 1024 * 1024,
                     allowFailure: Bool = false, truncationIsError: Bool = true) async throws -> Outcome {
        let request = BoundedSubprocessRunner.Request(
            executable: configuration.gitURL,
            arguments: ["-C", root.path, "--no-pager", "--literal-pathspecs"] + args,
            environment: configuration.environment,
            timeoutSeconds: timeout,
            outputLimitBytes: limit
        )
        let outcome = await runner.run(request)
        if outcome.cancelled { throw CancellationError() }
        guard outcome.launched else { throw Failure.launch(outcome.launchError ?? "") }
        if outcome.timedOut { throw Failure.timedOut }
        if truncationIsError, outcome.stdoutTruncated { throw Failure.outputTooLarge }
        if !allowFailure, outcome.exitCode != 0 { throw Failure.git(Self.summary(outcome.stderr)) }
        return outcome
    }

    /// The first lines of Git's error, enough to recognise it.
    static func summary(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let text = lines.prefix(3).joined(separator: "\n")
        return text.isEmpty ? String(localized: "Git reported an error.") : String(text.prefix(400))
    }

    /// Asks `xcode-select` until the tools are found, then remembers it: every Git call checks,
    /// and installing the tools needs no relaunch.
    actor CommandLineToolsCheck {
        private var found = false

        func installed() async -> Bool {
            if !found { found = await GitReviewService.xcodeSelectFindsDeveloperDirectory() }
            return found
        }
    }

    /// `xcode-select -p` succeeds and names a folder that exists.
    static func xcodeSelectFindsDeveloperDirectory() async -> Bool {
        let outcome = await BoundedSubprocessRunner().run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            environment: [:],
            timeoutSeconds: 5,
            outputLimitBytes: 64 * 1024
        ))
        let path = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return outcome.exitCode == 0 && !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }
}
