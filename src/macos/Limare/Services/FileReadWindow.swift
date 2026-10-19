import Foundation

/// The part of a text file one file_read returns, as Claude Code's and opencode's Read tools page
/// a file: whole when it fits, otherwise by lines from `offset` for `limit` lines, cut at a line
/// boundary within the byte limit with a note that says where to continue. A line longer than
/// the limit is cut and reading moves past it, so following the notes always reaches the end.
enum FileReadWindow {
    enum Failure: Error, Equatable {
        case invalidOffset
        case invalidLimit
        case offsetPastEnd(offset: Int, lineCount: Int)

        var message: String {
            switch self {
            case .invalidOffset: return "offset must be a whole number of at least 1."
            case .invalidLimit: return "limit must be a whole number of at least 1."
            case .offsetPastEnd(let offset, let lineCount): return "offset \(offset) is past the end; the file has \(lineCount) lines."
            }
        }
    }

    static func apply(_ content: String, offset: Double?, limit: Double?, maximumBytes: Int) -> Result<String, Failure> {
        guard let start = whole(offset, default: 1) else { return .failure(.invalidOffset) }
        guard let count = whole(limit, default: Int.max) else { return .failure(.invalidLimit) }
        if offset == nil, limit == nil, content.utf8.count <= maximumBytes { return .success(content) }

        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        let lineCount = lines.count
        guard start <= max(lineCount, 1) else { return .failure(.offsetPastEnd(offset: start, lineCount: lineCount)) }
        let (sum, overflow) = (start - 1).addingReportingOverflow(count)
        let end = overflow ? lineCount : min(sum, lineCount)

        var output = ""
        var used = 0
        var index = start - 1
        while index < end {
            let line = lines[index]
            let separator = index == start - 1 ? 0 : 1
            if used + separator + line.utf8.count > maximumBytes {
                guard index == start - 1 else {
                    return .success(output + "\n… stopped at line \(index) of \(lineCount); continue with offset \(index + 1) …")
                }
                let cut = prefix(line, maximumBytes: maximumBytes)
                var note = "\n… line \(index + 1) is longer than the read limit and was cut at \(cut.utf8.count) of \(line.utf8.count) bytes; read the rest of it with shell_execute"
                note += index + 1 < lineCount ? "; continue with offset \(index + 2) …" : " …"
                return .success(cut + note)
            }
            output += (separator == 1 ? "\n" : "") + line
            used += separator + line.utf8.count
            index += 1
        }
        if end < lineCount {
            output += "\n… lines \(start)–\(end) of \(lineCount); continue with offset \(end + 1) …"
        }
        return .success(output)
    }

    /// A positive whole number; one too large for `Int` reads as "to the end".
    private static func whole(_ value: Double?, default fallback: Int) -> Int? {
        guard let value else { return fallback }
        guard value.isFinite, value.rounded() == value, value >= 1 else { return nil }
        return Int(exactly: value) ?? Int.max
    }

    /// The longest start of `line` within `maximumBytes`, never splitting a character.
    private static func prefix(_ line: String, maximumBytes: Int) -> String {
        var used = 0
        var end = line.startIndex
        for character in line {
            let size = character.utf8.count
            if used + size > maximumBytes { break }
            used += size
            end = line.index(after: end)
        }
        return String(line[..<end])
    }
}
