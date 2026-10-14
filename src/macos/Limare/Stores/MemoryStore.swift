import Foundation
import Observation

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

        @MainActor
        func fragment(includeWriteInstructions: Bool) -> String {
            let writeInstructions = includeWriteInstructions ? MemoryStore.writeInstructions : ""
            return """
            <memory>
            You have a persistent memory that carries over between conversations. It is plain Markdown on this Mac:
            - \(globalPath) — long-term memory: lasting facts about the user and their work — who they are, their preferences, how they want you to work (including corrections they have given you), ongoing projects and their constraints. Keep it short and organized by topic; it is loaded into every conversation.
            - \(dailyDirectoryPath)/YYYY-MM-DD.md — daily notes, one file per local date (today is \(todayFileName)): what happened that may matter later — decisions, work done and where it stands, things the user wants kept in mind for now.\(writeInstructions)
            Older daily notes are not shown below; read or search \(dailyDirectoryPath) when earlier context would help.

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

    /// Reads canonical files once when a full run or non-run preview captures memory.
    func projectPromptSnapshot(enabled: Bool) -> PromptSnapshot? {
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
        let globalSection = Self.boundedSection(global) ?? "(empty)"
        var sections = ["### GLOBAL.md\n\(globalSection)"]
        var remaining = Self.maximumTotalBytes - (global.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : globalSection.utf8.count)
        let today = calendar.startOfDay(for: capturedDate)
        let earliest = calendar.date(byAdding: .day, value: -30, to: today)!
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: dailyDirectoryURL, includingPropertiesForKeys: nil)
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
            sections: sections
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

    /// Bounds memory section text to at most 200 lines and at most 32 KB, whichever is reached first.
    /// Appends deterministic truncation marker only when truncation occurs.
    /// Operates purely on derived projection without modifying canonical cached content or disk files.
    static func boundedSection(_ rawContent: String, direction: RetentionDirection = .head, byteLimit: Int = maximumSectionBytes) -> String? {
        let limit = min(maximumSectionBytes, max(0, byteLimit))
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed.components(separatedBy: "\n")
        let needsLineTruncation = lines.count > maximumSectionLines
        let needsByteTruncation = trimmed.utf8.count > limit

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
