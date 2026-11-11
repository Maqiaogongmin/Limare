import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class MemoryStore: @unchecked Sendable {
    private(set) var lastError: String?

    /// Immutable content/date/path capture; tool-dependent guidance is formatted at dispatch.
    struct PromptSnapshot {
        let globalPath: String
        let dailyDirectoryPath: String
        let todayFileName: String
        let sections: [String]
        let projectLongTermPath: String?
        let projectDailyPath: String?
        let projectResolutionFailed: Bool

        var memoryLocations: [URL] {
            [URL(fileURLWithPath: globalPath), URL(fileURLWithPath: dailyDirectoryPath)]
                + [projectLongTermPath, projectDailyPath].compactMap { $0.map { URL(fileURLWithPath: $0) } }
        }
        var longTermLocations: [URL] {
            [URL(fileURLWithPath: globalPath)] + [projectLongTermPath].compactMap { $0.map { URL(fileURLWithPath: $0) } }
        }

        @MainActor
        func fragment(includeWriteInstructions: Bool) -> String {
            let projectGuidance: String
            if let projectLongTermPath, let projectDailyPath {
                projectGuidance = """

            Current project memory: \(projectLongTermPath) is the project long-term file; \(projectDailyPath)/YYYY-MM-DD.md is the project daily directory. For project-specific experience and progress, use those project files instead of GLOBAL.md or the shared daily directory. Keep general personal preferences and cross-project knowledge in GLOBAL.md. The shared daily directory above contains older notes and is available for search, but is not automatically projected in this project.
            """
            } else if projectResolutionFailed {
                projectGuidance = "\nProject memory could not be resolved safely; only global memory is projected. Do not assume a project memory location or save project-specific memories to shared files while it is unresolved."
            } else { projectGuidance = "" }
            let writeInstructions = includeWriteInstructions ? MemoryStore.writeInstructions : ""
            return """
            <memory>
            You have a persistent memory that carries over between conversations. It is plain Markdown on this Mac:
            - \(globalPath) — long-term memory: lasting facts about the user and their work — who they are, their preferences, how they want you to work (including corrections they have given you), ongoing projects and their constraints. Keep it short and organized by topic; it is loaded into every conversation.
            - \(dailyDirectoryPath)/YYYY-MM-DD.md — daily notes, one file per local date (today is \(todayFileName)): what happened that may matter later — decisions, work done and where it stands, things the user wants kept in mind for now.\(writeInstructions)
            Older daily notes are not shown below; read or search \(dailyDirectoryPath) when earlier context would help.\(projectGuidance)

            The notes below were written in earlier conversations and may be out of date.
            - If they conflict with the user's latest message, follow the user.
            - Daily notes describe PAST work. Do not resume or continue an earlier task unless the user asks.

            \(sections.joined(separator: "\n\n"))
            </memory>
            """
        }
    }

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored let rootURL: URL
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let nowProvider: @Sendable () -> Date

    nonisolated static let maximumSectionLines = 200
    nonisolated static let maximumTotalBytes = 65_536
    enum RetentionDirection { case head, tail }

    nonisolated static let maximumSectionBytes = 32_768 // 32 KB safety ceiling
    nonisolated static let truncationMarker = "[... remaining memory truncated for context budget ...]"

    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        calendar: Calendar = .current,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        logs: DebugLogStore
    ) {
        self.fileManager = fileManager
        self.logs = logs
        self.calendar = calendar
        self.nowProvider = nowProvider
        rootURL = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent("\(LimareStorage.bundleIdentifier)/memory", isDirectory: true)
        prepareStorage()
    }

    var todayFileName: String { dailyFileName(for: nowProvider()) }

    private func dailyFileName(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    var globalFileURL: URL { rootURL.appendingPathComponent("GLOBAL.md") }

    var dailyDirectoryURL: URL {
        rootURL.appendingPathComponent("daily", isDirectory: true)
    }

    /// Non-run previews read current disk contents; running requests use their captured snapshot.
    func projectPromptFragment(enabled: Bool, includeWriteInstructions: Bool) -> String? {
        projectPromptSnapshot(enabled: enabled)?.fragment(includeWriteInstructions: includeWriteInstructions)
    }

    struct ProjectScope {
        let longTerm: URL
        let daily: URL
    }

    /// Resolve identity from the shared Git directory, never a repository name or remote.
    func projectScope(for workspace: URL) throws -> ProjectScope {
        let canonical = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var cursor = canonical
        var identity = "directory:" + canonical.path
        while true {
            let dotGit = cursor.appendingPathComponent(".git")
            let attrs: [FileAttributeKey: Any]?
            do { attrs = try fileManager.attributesOfItem(atPath: dotGit.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { attrs = nil }
            if let attrs {
                let gitDir: URL
                if attrs[.type] as? FileAttributeType == .typeDirectory {
                    gitDir = dotGit.resolvingSymlinksInPath()
                } else if attrs[.type] as? FileAttributeType == .typeRegular {
                    let value = try String(contentsOf: dotGit, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.hasPrefix("gitdir: ") else { throw CocoaError(.fileReadCorruptFile) }
                    let path = String(value.dropFirst(8))
                    guard !path.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    gitDir = URL(fileURLWithPath: path, relativeTo: cursor).standardizedFileURL.resolvingSymlinksInPath()
                } else { throw CocoaError(.fileReadCorruptFile) }
                var directory: ObjCBool = false
                guard fileManager.fileExists(atPath: gitDir.path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
                let commonFile = gitDir.appendingPathComponent("commondir")
                let common: URL
                do {
                    let raw = try String(contentsOf: commonFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    common = URL(fileURLWithPath: raw, relativeTo: gitDir).standardizedFileURL.resolvingSymlinksInPath()
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile { common = gitDir }
                guard fileManager.fileExists(atPath: common.path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
                // Refuse arbitrary .git pointers: a valid repository has a readable HEAD and
                // object database. Linked worktrees must point back to this worktree's .git.
                let head = try String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                guard !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      fileManager.fileExists(atPath: common.appendingPathComponent("objects").path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
                if common != gitDir {
                    let backlink = try String(contentsOf: gitDir.appendingPathComponent("gitdir"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !backlink.isEmpty,
                          URL(fileURLWithPath: backlink, relativeTo: gitDir).standardizedFileURL.resolvingSymlinksInPath() == dotGit.resolvingSymlinksInPath() else { throw CocoaError(.fileReadCorruptFile) }
                }
                identity = "git:" + common.path
                break
            }
            if cursor.path == "/" { break }
            let parentPath = (cursor.path as NSString).deletingLastPathComponent
            guard !parentPath.isEmpty, parentPath != cursor.path else { break }
            cursor = URL(fileURLWithPath: parentPath, isDirectory: true)
        }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = rootURL.resolvingSymlinksInPath().appendingPathComponent("projects", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
        let longTerm = dir.appendingPathComponent("PROJECT.md")
        let daily = dir.appendingPathComponent("daily", isDirectory: true)
        for url in [dir, longTerm, daily] {
            guard WorkspacePathResolver.canonicalPath(url) == url.standardizedFileURL.path else { throw CocoaError(.fileReadCorruptFile) }
        }
        return ProjectScope(longTerm: longTerm, daily: daily)
    }

    /// Reads canonical files once when a full run or non-run preview captures memory.
    func projectPromptSnapshot(enabled: Bool, workspace: URL? = nil) -> PromptSnapshot? {
        guard enabled else { return nil }
        let capturedDate = nowProvider()
        let todayFileName = dailyFileName(for: capturedDate)
        let global: String
        do {
            global = try String(contentsOf: globalFileURL, encoding: .utf8)
            lastError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Absence is an empty memory, not a failed read. The next file_write recreates it.
            global = ""
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logs.error("Memory", "Could not load GLOBAL.md: \(error.localizedDescription)")
            return nil
        }
        var project: ProjectScope?
        var resolutionFailed = false
        if let workspace {
            do { project = try projectScope(for: workspace) }
            catch {
                resolutionFailed = true
                logs.error("Memory", "Could not resolve project memory: \(error.localizedDescription)")
            }
        }
        let globalSection = Self.boundedSection(global) ?? "(empty)"
        var sections = ["### GLOBAL.md\n\(globalSection)"]
        var remaining = Self.maximumTotalBytes - (global.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : globalSection.utf8.count)
        if let project, remaining >= 1024 {
            do {
                let raw = try String(contentsOf: project.longTerm, encoding: .utf8)
                if let content = Self.boundedSection(raw, byteLimit: min(remaining, Self.maximumSectionBytes)) {
                    sections.append("### PROJECT.md\n\(content)")
                    remaining -= content.utf8.count
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
            catch {
                lastError = error.localizedDescription
                logs.error("Memory", "Could not load PROJECT.md: \(error.localizedDescription)")
                return nil
            }
        }
        let today = calendar.startOfDay(for: capturedDate)
        let earliest = calendar.date(byAdding: .day, value: -30, to: today)!
        let files: [URL]
        do {
            if resolutionFailed { files = [] }
            else { files = try fileManager.contentsOfDirectory(at: project?.daily ?? dailyDirectoryURL, includingPropertiesForKeys: nil) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && project != nil {
            files = []
        } catch {
            logs.error("Memory", "Could not list daily memory: \(error.localizedDescription)")
            files = []
        }
        let candidates = files.filter { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil else { return false }
            let parts = name.dropLast(3).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard components.year == parts[0], components.month == parts[1], components.day == parts[2] else { return false }
            return date >= earliest && date <= today
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var dailyCount = 0
        for url in candidates {
            guard dailyCount < 3, remaining >= 1024 else { break }
            if let project, (WorkspacePathResolver.canonicalPath(project.daily) != project.daily.standardizedFileURL.path || !WorkspacePathResolver.isInsideWorkspace(url, workspaceURL: project.daily)) {
                logs.error("Memory", "Skipping project daily note outside its directory: \(url.lastPathComponent)")
                continue
            }
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                guard let content = Self.boundedSection(raw, direction: .tail, byteLimit: min(remaining, Self.maximumSectionBytes)) else { continue }
                sections.append("### daily/\(url.lastPathComponent)\n\(content)")
                remaining -= content.utf8.count
                dailyCount += 1
            } catch {
                logs.error("Memory", "Skipping unreadable daily note \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return PromptSnapshot(
            globalPath: globalFileURL.standardizedFileURL.path,
            dailyDirectoryPath: dailyDirectoryURL.standardizedFileURL.path,
            todayFileName: todayFileName,
            sections: sections,
            projectLongTermPath: project?.longTerm.path,
            projectDailyPath: project?.daily.path,
            projectResolutionFailed: resolutionFailed
        )
    }

    private static let writeInstructions = """

Keep this memory up to date as part of your normal work. Reading and writing GLOBAL.md and the daily notes needs no approval.
- When the user asks you to remember something, save it right away. When they ask you to forget something, find it in GLOBAL.md and the daily notes and delete it.
- When you learn something that will still be useful in a later conversation, save it: to the long-term file if it stays true, to today's daily note if it belongs to this period. Do not wait to be asked.
- Before adding, check whether an entry already covers it. Update or delete entries that are outdated or wrong instead of adding contradictions.
- Change an existing memory file with file_edit. Use file_write only to create a new file, or to rewrite a file you have just read in full with file_read: the copies shown below may be truncated, and rewriting from them would lose the rest.
- Tell the user something is remembered or forgotten only after the write succeeded; if it failed, say so.
- Never save passwords, API keys, tokens, private keys or other credentials; copies of the conversation; or things you can simply look up again (file contents, command output, web pages).
- Add each daily-note entry at the end of the file, under a "## HH:mm" heading in local time.
"""

    private nonisolated static func projectionMetrics(_ raw: String) -> (text: String, lines: [String], bytes: Int) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, text.isEmpty ? [] : text.components(separatedBy: "\n"), text.utf8.count)
    }

    nonisolated static func capacityWarning(for raw: String) -> String? {
        let metrics = projectionMetrics(raw)
        if metrics.lines.count > maximumSectionLines || metrics.bytes > maximumSectionBytes {
            return "Memory capacity warning: the file was written successfully, but future automatic projection will be incomplete. Please organize the memory. The overall projection budget can also limit loading."
        }
        if metrics.lines.count >= maximumSectionLines * 9 / 10 || metrics.bytes >= (maximumSectionBytes * 9 + 9) / 10 {
            return "Memory capacity warning: this file is approaching its automatic projection limit. Please organize the memory. The overall projection budget can also limit loading."
        }
        return nil
    }

    /// Bounds memory section text to at most 200 lines and at most 32 KB, whichever is reached first.
    /// Appends deterministic truncation marker only when truncation occurs.
    /// Operates purely on derived projection without modifying canonical cached content or disk files.
    static func boundedSection(_ rawContent: String, direction: RetentionDirection = .head, byteLimit: Int = maximumSectionBytes) -> String? {
        let limit = min(maximumSectionBytes, max(0, byteLimit))
        let metrics = projectionMetrics(rawContent)
        let trimmed = metrics.text
        guard !trimmed.isEmpty else { return nil }

        let lines = metrics.lines
        let needsLineTruncation = lines.count > maximumSectionLines
        let needsByteTruncation = metrics.bytes > limit

        if !needsLineTruncation && !needsByteTruncation {
            return trimmed
        }

        let markerWithNewline = "\n" + truncationMarker
        let markerBytes = markerWithNewline.utf8.count
        let maxContentBytes = max(0, limit - markerBytes)

        var candidateText: String
        if needsLineTruncation {
            let selectedLines = Array(direction == .head ? lines.prefix(maximumSectionLines) : lines.suffix(maximumSectionLines))
            candidateText = selectedLines.joined(separator: "\n")
        } else {
            candidateText = trimmed
        }

        if candidateText.utf8.count > maxContentBytes {
            candidateText = direction == .head
                ? utf8Prefix(candidateText, maxBytes: maxContentBytes)
                : String(utf8Prefix(String(candidateText.reversed()), maxBytes: maxContentBytes).reversed())
        }

        return direction == .head ? candidateText + markerWithNewline : truncationMarker + "\n" + candidateText
    }

    /// Safely slices a String to at most maxBytes without splitting multi-byte Unicode scalars.
    private static func utf8Prefix(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var byteCount = 0
        var lastValidIndex = string.startIndex
        for index in string.indices {
            let charBytes = string[index].utf8.count
            if byteCount + charBytes > maxBytes {
                break
            }
            byteCount += charBytes
            lastValidIndex = string.index(after: index)
        }
        return String(string[..<lastValidIndex])
    }

    private func prepareStorage() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: dailyDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for url in [globalFileURL] {
                if !fileManager.fileExists(atPath: url.path) {
                    try Data().write(to: url, options: .atomic)
                    do {
                        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    } catch {
                        logs.error("Memory", "Created \(url.lastPathComponent) during storage preparation, but failed to apply 0600 permissions: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            lastError = error.localizedDescription
            logs.error("Memory", "Could not prepare local memory storage: \(error.localizedDescription)")
        }
    }

}
