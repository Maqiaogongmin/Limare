import Foundation

/// A record of `git status --porcelain=v2 -z`.
struct GitStatusEntry: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case ordinary
        case renamed
        case unmerged
        case untracked
    }

    /// The `S<c><m><u>` field of a submodule.
    struct Submodule: Sendable, Equatable {
        var commitChanged: Bool
        var trackedChanges: Bool
        var untrackedChanges: Bool
    }

    var kind: Kind
    /// Index status; `.` when unchanged.
    var x: Character
    /// Working tree status; `.` when unchanged.
    var y: Character
    var submodule: Submodule?
    var path: String
    /// The path before a rename or copy in the index.
    var origPath: String?
    var score: Int?
    var pathIsLossy = false

    var isStaged: Bool { kind != .untracked && kind != .unmerged && x != "." }
    var isUnstaged: Bool { kind != .untracked && kind != .unmerged && y != "." }
}

/// The parsed output of `git status --porcelain=v2 -z --branch`.
struct GitStatusReport: Sendable, Equatable {
    /// `branch.oid`: a commit, or nil before the first commit.
    var oid: String?
    /// `branch.head`: a branch name, or nil when detached.
    var head: String?
    var entries: [GitStatusEntry]
}

/// A record of `git diff --name-status -z`.
struct GitNameStatusRecord: Sendable, Equatable {
    var status: GitFileStatus
    var path: String
    var oldPath: String?
    var similarity: Int?
    var pathIsLossy = false
}

/// A record of `git diff --numstat -z`. Binary files count as nil.
struct GitNumstatRecord: Sendable, Equatable {
    var additions: Int?
    var deletions: Int?
    var path: String
    var oldPath: String?

    var isBinary: Bool { additions == nil && deletions == nil }
}

enum GitParseError: Error, Equatable, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail): "Git printed output Limare couldn't read: \(detail)"
        }
    }
}

/// Pure parsers for the Git output the Changes surface reads. They reject what they can't account
/// for (a hunk whose line counts don't add up, a truncated record) instead of showing half of it.
enum GitDiffParser {
    // MARK: - NUL-separated fields

    /// Splits `-z` output into fields, decoding each as UTF-8 and noting the ones that weren't.
    /// A trailing NUL ends the last field rather than starting an empty one.
    static func fields(_ data: Data) -> [(text: String, lossy: Bool)] {
        var result: [(String, Bool)] = []
        var parts = data.split(separator: 0, omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        for part in parts {
            if let text = String(data: Data(part), encoding: .utf8) {
                result.append((text, false))
            } else {
                result.append((String(decoding: part, as: UTF8.self), true))
            }
        }
        return result
    }

    // MARK: - status --porcelain=v2

    static func parseStatus(_ data: Data) throws -> GitStatusReport {
        var report = GitStatusReport(oid: nil, head: nil, entries: [])
        let records = fields(data)
        var index = 0
        while index < records.count {
            let (record, lossy) = records[index]
            index += 1
            guard let tag = record.first else { continue }
            switch tag {
            case "#":
                let header = record.dropFirst(2)
                if header.hasPrefix("branch.oid ") {
                    let oid = String(header.dropFirst("branch.oid ".count))
                    report.oid = oid == "(initial)" ? nil : oid
                } else if header.hasPrefix("branch.head ") {
                    let head = String(header.dropFirst("branch.head ".count))
                    report.head = head == "(detached)" ? nil : head
                }
            case "1":
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9 else { throw GitParseError.malformed("status record \(record.prefix(40))") }
                report.entries.append(try entry(kind: .ordinary, xy: parts[1], sub: parts[2], path: String(parts[8]), lossy: lossy))
            case "2":
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard parts.count == 10, index < records.count else { throw GitParseError.malformed("rename record \(record.prefix(40))") }
                var item = try entry(kind: .renamed, xy: parts[1], sub: parts[2], path: String(parts[9]), lossy: lossy)
                let orig = records[index]
                index += 1
                item.origPath = orig.text
                item.pathIsLossy = item.pathIsLossy || orig.lossy
                item.score = Int(parts[8].dropFirst())
                report.entries.append(item)
            case "u":
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { throw GitParseError.malformed("unmerged record \(record.prefix(40))") }
                report.entries.append(try entry(kind: .unmerged, xy: parts[1], sub: parts[2], path: String(parts[10]), lossy: lossy))
            case "?":
                guard record.count > 2 else { throw GitParseError.malformed("untracked record") }
                report.entries.append(GitStatusEntry(kind: .untracked, x: "?", y: "?", submodule: nil,
                                                     path: String(record.dropFirst(2)), pathIsLossy: lossy))
            case "!":
                continue
            default:
                throw GitParseError.malformed("status record \(record.prefix(40))")
            }
        }
        return report
    }

    private static func entry(kind: GitStatusEntry.Kind, xy: Substring, sub: Substring, path: String, lossy: Bool) throws -> GitStatusEntry {
        guard xy.count == 2, let x = xy.first, let y = xy.last else { throw GitParseError.malformed("status XY \(xy)") }
        var submodule: GitStatusEntry.Submodule?
        if sub.first == "S" {
            let flags = Array(sub.dropFirst())
            guard flags.count == 3 else { throw GitParseError.malformed("submodule field \(sub)") }
            submodule = .init(commitChanged: flags[0] == "C", trackedChanges: flags[1] == "M", untrackedChanges: flags[2] == "U")
        }
        return GitStatusEntry(kind: kind, x: x, y: y, submodule: submodule, path: path, pathIsLossy: lossy)
    }

    // MARK: - diff --name-status

    /// `M\0path\0`, or `R100\0old\0new\0` for a rename or copy.
    static func parseNameStatus(_ data: Data) throws -> [GitNameStatusRecord] {
        let records = fields(data)
        var result: [GitNameStatusRecord] = []
        var index = 0
        while index < records.count {
            let code = records[index].text
            index += 1
            guard let letter = code.first, let status = GitFileStatus(gitLetter: letter) else {
                throw GitParseError.malformed("name-status code \(code.prefix(8))")
            }
            if status == .renamed || status == .copied {
                guard index + 1 < records.count else { throw GitParseError.malformed("truncated rename") }
                let old = records[index], new = records[index + 1]
                index += 2
                result.append(GitNameStatusRecord(status: status, path: new.text, oldPath: old.text,
                                                  similarity: Int(code.dropFirst()), pathIsLossy: old.lossy || new.lossy))
            } else {
                guard index < records.count else { throw GitParseError.malformed("truncated name-status") }
                let path = records[index]
                index += 1
                result.append(GitNameStatusRecord(status: status, path: path.text, pathIsLossy: path.lossy))
            }
        }
        return result
    }

    // MARK: - diff --numstat

    /// `add\tdel\tpath\0`, or `add\tdel\t\0old\0new\0` for a rename: the empty third column is not
    /// a path. Binary files print `-\t-`.
    static func parseNumstat(_ data: Data) throws -> [GitNumstatRecord] {
        let records = fields(data)
        var result: [GitNumstatRecord] = []
        var index = 0
        while index < records.count {
            let record = records[index].text
            index += 1
            let columns = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { throw GitParseError.malformed("numstat record \(record.prefix(40))") }
            let additions = columns[0] == "-" ? nil : Int(columns[0])
            let deletions = columns[1] == "-" ? nil : Int(columns[1])
            guard (columns[0] == "-") == (additions == nil), (columns[1] == "-") == (deletions == nil) else {
                throw GitParseError.malformed("numstat counts \(record.prefix(40))")
            }
            if columns[2].isEmpty {
                guard index + 1 < records.count else { throw GitParseError.malformed("truncated numstat rename") }
                result.append(GitNumstatRecord(additions: additions, deletions: deletions,
                                               path: records[index + 1].text, oldPath: records[index].text))
                index += 2
            } else {
                result.append(GitNumstatRecord(additions: additions, deletions: deletions, path: String(columns[2])))
            }
        }
        return result
    }

    // MARK: - Unified patch

    /// Parses one file's `git diff` output. Every hunk's lines must add up to its header's counts.
    static func parsePatch(_ text: String) throws -> GitDiffDocument {
        var sections: [GitDiffSection] = []
        var section: GitDiffSection?
        var hunk: GitDiffHunk?
        var oldRemaining = 0, newRemaining = 0, oldNumber = 0, newNumber = 0

        func closeHunk() throws {
            guard let open = hunk else { return }
            guard oldRemaining == 0, newRemaining == 0 else {
                throw GitParseError.malformed("hunk \(open.header) ends early")
            }
            section?.hunks.append(open)
            hunk = nil
        }
        func closeSection() throws {
            try closeHunk()
            if let open = section { sections.append(open) }
            section = nil
        }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        for raw in lines {
            if hunk != nil, oldRemaining > 0 || newRemaining > 0 {
                // Inside a hunk: every line belongs to it until its counts are used up.
                // By scalar: a combining mark after the marker would join it into one Character.
                let marker = raw.unicodeScalars.first
                let body = raw.isEmpty ? "" : String(raw.unicodeScalars.dropFirst())
                switch marker {
                case " ", nil:
                    // An empty line is a blank context line when diff.suppressBlankEmpty is set.
                    guard oldRemaining > 0, newRemaining > 0 else { throw GitParseError.malformed("context line past hunk counts") }
                    hunk?.lines.append(GitDiffLine(kind: .context, oldLine: oldNumber, newLine: newNumber, text: body))
                    oldNumber += 1; newNumber += 1; oldRemaining -= 1; newRemaining -= 1
                case "-":
                    guard oldRemaining > 0 else { throw GitParseError.malformed("removed line past hunk counts") }
                    hunk?.lines.append(GitDiffLine(kind: .removed, oldLine: oldNumber, newLine: nil, text: body))
                    oldNumber += 1; oldRemaining -= 1
                case "+":
                    guard newRemaining > 0 else { throw GitParseError.malformed("added line past hunk counts") }
                    hunk?.lines.append(GitDiffLine(kind: .added, oldLine: nil, newLine: newNumber, text: body))
                    newNumber += 1; newRemaining -= 1
                case "\\":
                    try markNoNewline(&hunk)
                default:
                    throw GitParseError.malformed("unexpected line inside hunk")
                }
                continue
            }

            if raw.hasPrefix("\\"), hunk != nil {
                // "\ No newline at end of file" after a hunk's last line.
                try markNoNewline(&hunk)
                continue
            }
            if raw.hasPrefix("diff --git ") {
                try closeSection()
                section = GitDiffSection(hunks: [])
                continue
            }
            if raw.hasPrefix("@@") {
                guard section != nil else { throw GitParseError.malformed("hunk before file header") }
                try closeHunk()
                let header = try parseHunkHeader(raw)
                hunk = GitDiffHunk(oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart,
                                   newCount: header.newCount, section: header.section, lines: [])
                oldRemaining = header.oldCount
                newRemaining = header.newCount
                oldNumber = header.oldStart
                newNumber = header.newStart
                continue
            }
            guard section != nil else {
                if raw.isEmpty { continue }
                throw GitParseError.malformed("text before file header")
            }
            guard hunk == nil else {
                if raw.isEmpty { continue }
                throw GitParseError.malformed("text after a hunk")
            }
            applyExtendedHeader(raw, to: &section!)
        }
        try closeSection()
        return GitDiffDocument(sections: sections)
    }

    private static func markNoNewline(_ hunk: inout GitDiffHunk?) throws {
        guard let count = hunk?.lines.count, count > 0 else { throw GitParseError.malformed("stray no-newline marker") }
        hunk?.lines[count - 1].noNewlineAtEnd = true
    }

    private static func applyExtendedHeader(_ line: String, to section: inout GitDiffSection) {
        func value(_ prefix: String) -> String? {
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        if let mode = value("old mode ") {
            section.oldMode = mode
        } else if let mode = value("new mode ") {
            section.newMode = mode
        } else if let mode = value("new file mode ") {
            section.isNewFile = true
            section.newMode = mode
        } else if let mode = value("deleted file mode ") {
            section.isDeletedFile = true
            section.oldMode = mode
        } else if let score = value("similarity index ") {
            section.similarity = Int(score.trimmingCharacters(in: CharacterSet(charactersIn: "%")))
        } else if let path = value("rename from ") {
            section.renameFrom = unquote(path)
        } else if let path = value("rename to ") {
            section.renameTo = unquote(path)
        } else if let path = value("copy from ") {
            section.copyFrom = unquote(path)
        } else if let path = value("copy to ") {
            section.copyTo = unquote(path)
        } else if let rest = value("index ") {
            // `index abc..def 100644`: the mode of an unchanged-mode file.
            let parts = rest.split(separator: " ")
            if parts.count == 2, section.oldMode == nil, section.newMode == nil {
                section.oldMode = String(parts[1])
                section.newMode = String(parts[1])
            }
        } else if let path = value("--- ") {
            section.oldPath = strippedPath(path, prefix: "a/")
        } else if let path = value("+++ ") {
            section.newPath = strippedPath(path, prefix: "b/")
        } else if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
            section.isBinary = true
        }
    }

    private static func strippedPath(_ raw: String, prefix: String) -> String? {
        let path = unquote(raw.hasSuffix("\t") ? String(raw.dropLast()) : raw)
        if path == "/dev/null" { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Undoes Git's C-style quoting of a header path (`"a/\303\251.txt"`).
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var bytes: [UInt8] = []
        var chars = Array(raw.dropFirst().dropLast().utf8)[...]
        while let byte = chars.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = chars.popFirst() else {
                bytes.append(byte)
                continue
            }
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = chars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    chars.removeFirst()
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    struct HunkHeader: Equatable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var section: String
    }

    /// `@@ -a[,b] +c[,d] @@[ section]`; a missing count is 1.
    static func parseHunkHeader(_ line: String) throws -> HunkHeader {
        guard line.hasPrefix("@@ -") else { throw GitParseError.malformed("hunk header") }
        let afterOpen = line.dropFirst(3)
        guard let close = afterOpen.range(of: " @@") else { throw GitParseError.malformed("hunk header") }
        let ranges = afterOpen[..<close.lowerBound].split(separator: " ")
        guard ranges.count == 2, ranges[0].hasPrefix("-"), ranges[1].hasPrefix("+") else {
            throw GitParseError.malformed("hunk header ranges")
        }
        func range(_ text: Substring) throws -> (Int, Int) {
            let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]), parts.count <= 2 else { throw GitParseError.malformed("hunk range \(text)") }
            if parts.count == 1 { return (start, 1) }
            guard let count = Int(parts[1]) else { throw GitParseError.malformed("hunk range \(text)") }
            return (start, count)
        }
        let old = try range(ranges[0]), new = try range(ranges[1])
        var section = String(afterOpen[close.upperBound...])
        if section.hasPrefix(" ") { section.removeFirst() }
        return HunkHeader(oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }

    // MARK: - Untracked files

    /// An untracked text file as Git would show it once added: one hunk of new lines.
    static func untrackedDocument(path: String, text: String) -> GitDiffDocument {
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        var diffLines = lines.enumerated().map { offset, line in
            GitDiffLine(kind: .added, oldLine: nil, newLine: offset + 1, text: line)
        }
        if !endsWithNewline, !diffLines.isEmpty { diffLines[diffLines.count - 1].noNewlineAtEnd = true }
        let hunks = diffLines.isEmpty ? [] : [GitDiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: diffLines.count,
                                                          section: "", lines: diffLines)]
        return GitDiffDocument(sections: [GitDiffSection(oldPath: nil, newPath: path, isNewFile: true, hunks: hunks)])
    }
}
