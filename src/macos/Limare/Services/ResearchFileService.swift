import Foundation

public enum ResearchFileError: LocalizedError, Equatable {
    case workspaceRequired
    case invalidPath(String)
    case accessDenied(String)
    case searchError(String)

    public var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            "A Project folder or working directory must be set to use file operations."
        case .invalidPath(let path):
            "Invalid or out-of-workspace path: \(path)"
        case .accessDenied(let message):
            "Access denied: \(message)"
        case .searchError(let message):
            "File search error: \(message)"
        }
    }
}

public struct ResearchFileService: Sendable {
    public static let defaultMaxDepth = 5
    public static let maxAllowedDepth = 5
    public static let defaultMaxEntries = 500
    public static let maxAllowedEntries = 500
    public static let defaultMaxSearchResults = 100
    public static let maxAllowedSearchResults = 100
    public static let maxContentSearchFileBytes = 1_048_576 // 1MB

    private static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "DerivedData", ".build", ".svn", ".hg", "Pods", "Carthage"
    ]

    private static let ignoredBinaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "pdf", "zip", "tar", "gz", "bz2", "xz",
        "o", "a", "dylib", "so", "class", "jar", "exe", "bin", "mp3", "mp4", "mov", "wav"
    ]

    public init() {}

    public func listFiles(
        in workspaceURL: URL,
        subpath: String = ".",
        recursive: Bool = true,
        maxDepth: Int = defaultMaxDepth,
        maxEntries: Int = defaultMaxEntries
    ) throws -> [[String: Any]] {
        let rootURL = try resolveURL(subpath: subpath, workspaceURL: workspaceURL)
        let effectiveDepth = min(max(maxDepth, 1), Self.maxAllowedDepth)
        let effectiveMaxEntries = min(max(maxEntries, 1), Self.maxAllowedEntries)

        guard WorkspacePathResolver.isInsideWorkspace(rootURL, workspaceURL: workspaceURL) else {
            throw ResearchFileError.accessDenied("Path '\(rootURL.path)' is outside the workspace.")
        }
        let containmentRoot = workspaceURL
        let relativeBase = workspaceURL

        var entries: [[String: Any]] = []
        let fileManager = FileManager.default
        let standardizedContainmentPath = containmentRoot.standardizedFileURL.path

        if !recursive || effectiveDepth == 1 {
            let contents = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for fileURL in contents.sorted(by: { $0.path < $1.path }) {
                guard entries.count < effectiveMaxEntries else { break }
                let name = fileURL.lastPathComponent
                if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) { continue }
                let resolved = fileURL.resolvingSymlinksInPath()
                guard WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: containmentRoot) else { continue }
                if PermissionEvaluator.isSensitivePath(fileURL) || PermissionEvaluator.isSensitivePath(resolved) { continue }
                let relative = relativePath(from: relativeBase, to: fileURL)
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                entries.append([
                    "path": relative,
                    "type": isDir ? "directory" : "file"
                ])
            }
            return entries
        }

        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard entries.count < effectiveMaxEntries else { break }
            let name = fileURL.lastPathComponent
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let resolved = fileURL.resolvingSymlinksInPath()

            if isDir {
                if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) || !WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: containmentRoot) {
                    enumerator?.skipDescendants()
                    continue
                }
            } else {
                guard WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: containmentRoot) else {
                    continue
                }
                if name.hasPrefix(".") || PermissionEvaluator.isSensitivePath(fileURL) || PermissionEvaluator.isSensitivePath(resolved) {
                    continue
                }
            }

            let standardURL = fileURL.standardizedFileURL
            guard standardURL.path.hasPrefix(standardizedContainmentPath) else {
                continue
            }

            // Check depth relative to rootURL
            let depth = fileURL.pathComponents.count - rootURL.pathComponents.count
            if depth > effectiveDepth {
                if isDir { enumerator?.skipDescendants() }
                continue
            }

            let relative = relativePath(from: relativeBase, to: fileURL)
            entries.append([
                "path": relative,
                "type": isDir ? "directory" : "file"
            ])
        }

        return entries
    }

    public func searchFiles(
        in workspaceURL: URL,
        query: String,
        subpath: String = ".",
        mode: String = "content",
        isRegex: Bool = false,
        maxResults: Int = defaultMaxSearchResults
    ) throws -> [[String: Any]] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw ResearchFileError.searchError("Search query cannot be empty.")
        }
        let rootURL = try resolveURL(subpath: subpath, workspaceURL: workspaceURL)
        let effectiveMaxResults = min(max(maxResults, 1), Self.maxAllowedSearchResults)
        let searchContent = (mode.lowercased() != "name")
        let fileManager = FileManager.default

        guard WorkspacePathResolver.isInsideWorkspace(rootURL, workspaceURL: workspaceURL) else {
            throw ResearchFileError.accessDenied("Path '\(rootURL.path)' is outside the workspace.")
        }
        let containmentRoot = workspaceURL
        let relativeBase = workspaceURL
        let standardizedContainmentPath = containmentRoot.standardizedFileURL.path

        var regex: NSRegularExpression?
        if isRegex {
            do {
                regex = try NSRegularExpression(pattern: trimmedQuery, options: [.caseInsensitive])
            } catch {
                throw ResearchFileError.searchError("Invalid regular expression: \(error.localizedDescription)")
            }
        }

        var results: [[String: Any]] = []

        // A file path searches that file, as grep and rg do.
        var isDirectory: ObjCBool = false
        var singleFile: URL? = fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue ? rootURL : nil
        let enumerator = singleFile == nil ? fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants, .skipsHiddenFiles]
        ) : nil
        func nextFile() -> URL? {
            if let file = singleFile {
                singleFile = nil
                return file
            }
            return enumerator?.nextObject() as? URL
        }

        var boundary = MCPInfrastructureBoundary.AccessChecker()
        while let fileURL = nextFile() {
            guard results.count < effectiveMaxResults else { break }
            do { try boundary.require(fileURL) }
            catch { enumerator?.skipDescendants(); continue }
            let name = fileURL.lastPathComponent
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let resolved = fileURL.resolvingSymlinksInPath()

            if isDir {
                if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) || !WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: containmentRoot) {
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: containmentRoot) else {
                continue
            }

            if name.hasPrefix(".") || PermissionEvaluator.isSensitivePath(fileURL) || PermissionEvaluator.isSensitivePath(resolved) {
                continue
            }

            let standardURL = fileURL.standardizedFileURL
            guard standardURL.path.hasPrefix(standardizedContainmentPath) else {
                continue
            }

            let relative = relativePath(from: relativeBase, to: fileURL)

            if !searchContent {
                // Name search mode
                let matches: Bool
                if let regex {
                    matches = regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) != nil
                } else {
                    matches = name.localizedCaseInsensitiveContains(trimmedQuery)
                }
                if matches {
                    results.append([
                        "path": relative,
                        "type": "file"
                    ])
                }
            } else {
                // Content search mode
                // Defense-in-depth: skip binary files and sensitive paths
                let ext = fileURL.pathExtension.lowercased()
                if Self.ignoredBinaryExtensions.contains(ext) {
                    continue
                }

                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize,
                      size <= Self.maxContentSearchFileBytes else {
                    continue
                }

                guard let data = try? Data(contentsOf: resolved, options: .mappedIfSafe),
                      let content = String(data: data, encoding: .utf8) else {
                    continue
                }

                let lines = content.components(separatedBy: .newlines)
                for (index, line) in lines.enumerated() {
                    guard results.count < effectiveMaxResults else { break }
                    let lineMatches: Bool
                    if let regex {
                        lineMatches = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
                    } else {
                        lineMatches = line.localizedCaseInsensitiveContains(trimmedQuery)
                    }

                    if lineMatches {
                        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                        let boundedSnippet = String(trimmedLine.prefix(200))
                        results.append([
                            "path": relative,
                            "line": index + 1,
                            "snippet": boundedSnippet
                        ])
                    }
                }
            }
        }

        return results
    }

    private func resolveURL(subpath: String, workspaceURL: URL) throws -> URL {
        let cleanSubpath = subpath.trimmingCharacters(in: .whitespacesAndNewlines)
        return try WorkspacePathResolver.resolve(
            cleanSubpath.isEmpty ? "." : cleanSubpath,
            relativeTo: workspaceURL,
            mustExist: true
        )
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        if targetPath.hasPrefix(basePath) {
            let relative = targetPath.dropFirst(basePath.count)
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "." : trimmed
        }
        return targetPath
    }
}
