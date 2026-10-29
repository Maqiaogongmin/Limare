import Foundation

/// Copies into a new worktree the files of Local that `.worktreeinclude` names (gitignore syntax)
/// and that Git ignores, such as `.env`: what a fresh checkout lacks. Untracked files Git doesn't
/// ignore are left out, so the copy never shows up as new work. Existing files are never
/// overwritten; on APFS the copies are clones.
enum WorktreeIncludeService {
    /// Returns the paths that couldn't be copied.
    static func copy(from local: URL, to target: URL, git: GitWorktreeService) async throws -> [String] {
        let manifest = local.appendingPathComponent(".worktreeinclude")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let named = try await git.git(local, ["ls-files", "-z", "--others", "--ignored", "--exclude-from=\(manifest.path)"])
        let candidates = GitDiffParser.fields(named.stdoutData).filter { !$0.lossy }.map(\.text)
        guard !candidates.isEmpty else { return [] }

        let input = FileManager.default.temporaryDirectory.appendingPathComponent("limare-worktreeinclude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: input) }
        try Data((candidates.joined(separator: "\0") + "\0").utf8).write(to: input)
        // Exit 1 means none of them is ignored.
        let ignored = try await git.git(local, ["check-ignore", "-z", "--stdin"], allowFailure: true, standardInputFile: input)
        guard ignored.exitCode == 0 || ignored.exitCode == 1 else {
            throw GitWorktreeService.Failure.git(GitReviewService.summary(ignored.stderr))
        }

        var failures: [String] = []
        for field in GitDiffParser.fields(ignored.stdoutData) {
            let path = field.text
            let destination = target.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: local.appendingPathComponent(path), to: destination)
            } catch {
                failures.append(path)
            }
        }
        return failures
    }
}
