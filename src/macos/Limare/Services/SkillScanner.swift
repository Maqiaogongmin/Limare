import Foundation

struct SkillScanner {
    private let fileManager: FileManager
    private let customGlobalRoots: [URL]?

    init(fileManager: FileManager = .default, customGlobalRoots: [URL]? = nil) {
        self.fileManager = fileManager
        self.customGlobalRoots = customGlobalRoots
    }

    func scan(workspaceURL: URL?) -> [Skill] {
        var discovered: [Skill] = []
        var seenCanonicalPaths = Set<String>()
        var seenIDs = Set<String>()

        if let workspaceURL {
            let workspaceRoots = [
                workspaceURL.appendingPathComponent(".agents/skills", isDirectory: true),
                workspaceURL.appendingPathComponent(".claude/skills", isDirectory: true),
                workspaceURL.appendingPathComponent(".cline/skills", isDirectory: true),
                workspaceURL.appendingPathComponent(".skills", isDirectory: true),
                workspaceURL.appendingPathComponent("skills", isDirectory: true)
            ]
            for root in workspaceRoots {
                scanRoot(root, location: .workspace(root), into: &discovered, seenCanonicalPaths: &seenCanonicalPaths, seenIDs: &seenIDs)
            }
        }

        let globalRoots: [URL]
        if let customGlobalRoots {
            globalRoots = customGlobalRoots
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            globalRoots = [
                home.appendingPathComponent(".agents/skills", isDirectory: true),
                home.appendingPathComponent(".claude/skills", isDirectory: true),
                home.appendingPathComponent(".config/skills", isDirectory: true),
                home.appendingPathComponent(".limare/skills", isDirectory: true),
                home.appendingPathComponent("Library/Application Support/Limare/skills", isDirectory: true),
                home.appendingPathComponent(".gemini/antigravity/builtin/skills", isDirectory: true)
            ]
        }
        for root in globalRoots {
            scanRoot(root, location: .global(root), into: &discovered, seenCanonicalPaths: &seenCanonicalPaths, seenIDs: &seenIDs)
        }

        return discovered
    }

    private func scanRoot(
        _ rootURL: URL,
        location: SkillLocation,
        into discovered: inout [Skill],
        seenCanonicalPaths: inout Set<String>,
        seenIDs: inout Set<String>
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let canonicalDir = entry.resolvingSymlinksInPath().standardizedFileURL
            guard seenCanonicalPaths.insert(canonicalDir.path).inserted else {
                continue
            }

            guard let skillFileURL = findSkillFile(in: canonicalDir) else {
                continue
            }

            guard let content = try? String(contentsOf: skillFileURL, encoding: .utf8) else {
                continue
            }

            let folderName = canonicalDir.lastPathComponent
            let parsed = SkillParser.parse(skillMD: content, fallbackName: folderName)
            let rawID = Self.slugify(parsed.name.isEmpty ? folderName : parsed.name)
            let id = rawID.isEmpty ? Self.slugify(folderName) : rawID

            guard seenIDs.insert(id).inserted else {
                continue
            }

            let modDate = (try? skillFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

            let skill = Skill(
                id: id,
                name: parsed.name,
                description: parsed.description,
                version: parsed.version,
                directoryURL: canonicalDir,
                fileURL: skillFileURL,
                location: location,
                isEnabled: true,
                updatedAt: modDate,
                body: parsed.body
            )
            discovered.append(skill)
        }
    }

    private func findSkillFile(in directory: URL) -> URL? {
        let candidates = ["SKILL.md", "skill.md", "Skill.md"]
        for name in candidates {
            let fileURL = directory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: fileURL.path) {
                return fileURL.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return nil
    }

    static func slugify(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = lower.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined(separator: "-")
        return replaced.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
    }
}
