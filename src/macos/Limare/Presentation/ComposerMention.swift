import Foundation

/// The `@` token at the end of the draft: `@` at the start or after whitespace, then no
/// whitespace and no further `@`.
struct ComposerMentionQuery: Equatable {
    let tokenRange: Range<String.Index>
    let query: String
    /// Everything up to and including the last "/" of the query; "" when there is none.
    let directoryPart: String
    let namePrefix: String
}

enum ComposerMentionParser {
    static func query(in draft: String) -> ComposerMentionQuery? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let rest = draft[draft.index(after: at)...]
        guard !rest.contains(where: { $0.isWhitespace || $0 == "@" }) else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = String(rest)
        let directoryPart: String
        let namePrefix: String
        if let slash = query.lastIndex(of: "/") {
            directoryPart = String(query[...slash])
            namePrefix = String(query[query.index(after: slash)...])
        } else {
            directoryPart = ""
            namePrefix = query
        }
        return ComposerMentionQuery(tokenRange: at..<draft.endIndex, query: query, directoryPart: directoryPart, namePrefix: namePrefix)
    }

    /// The draft with the token replaced by `@` and the candidate's absolute path. A file is
    /// followed by a space, which ends the token and closes the menu, as in Claude Code; a
    /// directory ends with "/", so the menu goes on listing its contents.
    static func insertion(of candidate: ComposerMentionCandidate, into draft: String, query: ComposerMentionQuery) -> String {
        let path = candidate.isDirectory ? candidate.id + "/" : candidate.id + " "
        return draft.replacingCharacters(in: query.tokenRange, with: "@" + path)
    }
}

struct ComposerMentionCandidate: Identifiable, Equatable {
    /// Absolute path.
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
}

enum ComposerMentionProvider {
    static let listingLimit = 200

    /// Entries of one workspace directory (never a recursive scan) whose names match the
    /// prefix: names starting with it, then names containing it; directories first within
    /// each, then shorter paths.
    static func candidates(
        workspaceURL: URL,
        directoryPart: String,
        namePrefix: String,
        limit: Int = 30
    ) -> [ComposerMentionCandidate] {
        let root = workspaceURL.standardizedFileURL
        let directory: URL
        if directoryPart.hasPrefix("/") {
            directory = URL(fileURLWithPath: directoryPart, isDirectory: true).standardizedFileURL
        } else if directoryPart.isEmpty {
            directory = root
        } else {
            directory = root.appendingPathComponent(directoryPart, isDirectory: true).standardizedFileURL
        }
        guard WorkspacePathResolver.isInsideWorkspace(directory, workspaceURL: root) else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }
        let subpath = directory.path == root.path ? "." : String(directory.path.dropFirst(root.path.count + 1))
        let entries = (try? ResearchFileService().listFiles(
            in: root, subpath: subpath, recursive: false, maxDepth: 1, maxEntries: listingLimit
        )) ?? []

        let needle = namePrefix.lowercased()
        let ranked: [(rank: Int, candidate: ComposerMentionCandidate)] = entries.compactMap { entry in
            guard let relative = entry["path"] as? String else { return nil }
            let name = (relative as NSString).lastPathComponent
            let lower = name.lowercased()
            let rank: Int
            if needle.isEmpty || lower.hasPrefix(needle) {
                rank = 0
            } else if lower.contains(needle) {
                rank = 1
            } else {
                return nil
            }
            let absolute = root.appendingPathComponent(relative).standardizedFileURL.path
            return (rank, ComposerMentionCandidate(
                id: absolute, name: name, relativePath: relative, isDirectory: (entry["type"] as? String) == "directory"
            ))
        }
        return ranked.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.candidate.isDirectory != rhs.candidate.isDirectory { return lhs.candidate.isDirectory }
            if lhs.candidate.relativePath.count != rhs.candidate.relativePath.count {
                return lhs.candidate.relativePath.count < rhs.candidate.relativePath.count
            }
            return lhs.candidate.relativePath < rhs.candidate.relativePath
        }
        .prefix(limit)
        .map(\.candidate)
    }
}
