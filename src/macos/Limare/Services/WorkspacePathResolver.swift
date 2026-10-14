import Foundation

enum WorkspacePathError: LocalizedError, Equatable {
    case workspaceRequired
    case pathNotFound(String)
    case parentNotFound(String)

    var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            "Choose a Project Folder or conversation before using file or shell tools."
        case .pathNotFound(let path):
            "Path does not exist: \(path)"
        case .parentNotFound(let path):
            "The destination parent does not exist: \(path)"
        }
    }
}

enum WorkspacePathResolver {
    static func resolve(
        _ rawPath: String,
        relativeTo workspaceURL: URL,
        mustExist: Bool
    ) throws -> URL {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else {
            candidate = workspaceURL.appendingPathComponent(expanded)
        }

        let standardized = candidate.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath()
        }
        guard !mustExist else {
            throw WorkspacePathError.pathNotFound(standardized.path)
        }

        let parent = standardized.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            return parent.resolvingSymlinksInPath()
                .appendingPathComponent(standardized.lastPathComponent)
                .standardizedFileURL
        }
        return standardized.resolvingSymlinksInPath()
    }

    static func isInsideWorkspace(_ url: URL, workspaceURL: URL) -> Bool {
        let root = canonicalPath(workspaceURL)
        let target = canonicalPath(url)
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves symlinks through the deepest existing ancestor, so a file that does not exist yet
    /// resolves like its folder. resolvingSymlinksInPath leaves a missing path untouched, so a new file
    /// under /private/tmp would otherwise look outside its workspace, which resolves to /tmp.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }
}
