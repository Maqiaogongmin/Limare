import Foundation
import Observation

struct WorktreePreferences: Codable, Equatable, Sendable {
    var root: WorkspaceConfiguration?
    var branchPrefix: String = "limare"
}

/// Preferences affect new worktrees only; existing bindings keep their recorded paths.
@MainActor
@Observable
final class WorktreePreferencesStore {
    private(set) var value = WorktreePreferences()
    private(set) var isReadable = true
    private let fileURL: URL

    init(root: URL) {
        fileURL = root.appendingPathComponent("worktree_settings_v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { value = try JSONDecoder().decode(WorktreePreferences.self, from: Data(contentsOf: fileURL)) }
            catch { isReadable = false }
        }
    }

    func save(_ candidate: WorktreePreferences) throws {
        guard isReadable else { throw GitWorktreeService.Failure.unavailable(String(localized: "Worktree settings could not be read; they were not overwritten.")) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(candidate).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        value = candidate
    }
}
