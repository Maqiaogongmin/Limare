import Foundation

enum FileToolError: LocalizedError {
    case notAFile(String)
    case tooLarge(limit: Int)
    case invalidUTF8
    case emptyMatch
    case matchNotFound
    case matchNotUnique(count: Int)

    var errorDescription: String? {
        switch self {
        case .notAFile(let path): "Not a regular file: \(path)"
        case .tooLarge(let limit): "File exceeds the \(limit)-byte read limit."
        case .invalidUTF8: "The file is not valid UTF-8 text."
        case .emptyMatch: "file_edit requires a non-empty old_text value."
        case .matchNotFound: "old_text was not found in the file."
        case .matchNotUnique(let count): "old_text matched \(count) locations; provide a unique match."
        }
    }
}

struct FileToolService: Sendable {
    let maximumReadBytes: Int

    init(maximumReadBytes: Int = 1_048_576) {
        self.maximumReadBytes = maximumReadBytes
    }

    func read(url: URL) throws -> String {
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw FileToolError.notAFile(url.path) }
        if let size = values.fileSize, size > maximumReadBytes {
            throw FileToolError.tooLarge(limit: maximumReadBytes)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileToolError.invalidUTF8
        }
        return text
    }

    func write(url: URL, content: String) throws -> Int {
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: url)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return data.count
    }

    /// Writes `content` at a location pinned to its directory (see `AnchoredFileSystem`).
    func write(content: String, at location: AnchoredPath) throws -> Int {
        let data = Data(content.utf8)
        try AnchoredFileSystem.write(data, to: location)
        return data.count
    }

    /// Replaces the unique match of `oldText`. With `location`, the result is written there
    /// (pinned to its directory); otherwise to `url`.
    func edit(url: URL, oldText: String, newText: String, writingTo location: AnchoredPath? = nil) throws -> Int {
        guard !oldText.isEmpty else { throw FileToolError.emptyMatch }
        let original = try read(url: url)
        let matches = original.ranges(of: oldText)
        guard !matches.isEmpty else { throw FileToolError.matchNotFound }
        guard matches.count == 1 else { throw FileToolError.matchNotUnique(count: matches.count) }
        let updated = original.replacingCharacters(in: matches[0], with: newText)
        let data = Data(updated.utf8)
        if let location {
            try AnchoredFileSystem.write(data, to: location)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return data.count
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchRange = startIndex..<endIndex
        while let range = range(of: needle, options: [], range: searchRange) {
            result.append(range)
            searchRange = range.upperBound..<endIndex
        }
        return result
    }
}
