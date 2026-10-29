import Foundation

/// What an open tool row shows: the built-in tools as a reader wants them (the command and its
/// terminal, the file, the diff, the list), every other call as its raw input and output.
///
/// Read from the call's input (decoded with the tool's own argument type), its typed fields and,
/// for `file_list` and `file_search` only, the JSON output the executor writes with fixed keys.
/// Nothing is looked up in free text: anything that does not decode is `.raw`.
enum ToolCallDetail: Equatable, Sendable {
    struct DiffLine: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case removed, added, unchanged }
        let kind: Kind
        let text: String
    }

    struct Entry: Equatable, Sendable {
        let path: String
        let isDirectory: Bool
    }

    struct Match: Equatable, Sendable {
        let path: String
        let line: Int?
        let snippet: String?
    }

    struct PlanItem: Equatable, Sendable {
        enum Status: Equatable, Sendable { case pending, inProgress, completed }
        let step: String
        let status: Status
    }

    case shell(command: String, cwd: String?, output: String, exitCode: Int32?)
    case fileContent(path: String, text: String)
    case diff(path: String, lines: [DiffLine])
    case entries(path: String, items: [Entry])
    case matches(query: String, items: [Match])
    case plan(items: [PlanItem])
    /// The answered questions, which the row itself shows.
    case questions
    case raw

    static func resolve(_ record: ToolCallRecord) -> ToolCallDetail {
        guard let tool = BuiltInTool(record.name), record.state.isTerminal else { return .raw }
        // A failed command's terminal is what the user wants to see; any other call that did
        // not succeed shows its error as it is, never as a file or a list.
        if tool == .shell {
            guard let arguments: ShellArguments = decode(record.input) else { return .raw }
            let cwd = arguments.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .shell(command: arguments.command, cwd: cwd?.isEmpty == false ? cwd : nil, output: record.output,
                          exitCode: record.mechanicalTerminalFact?.shellTerminal?.exitCode)
        }
        guard record.state == .completed else { return .raw }
        switch tool {
        case .shell:
            return .raw
        case .read:
            guard let arguments: ReadArguments = decode(record.input) else { return .raw }
            return .fileContent(path: arguments.path, text: record.output)
        case .write:
            guard let arguments: WriteArguments = decode(record.input) else { return .raw }
            return .fileContent(path: arguments.path, text: arguments.content)
        case .edit:
            guard let arguments: EditArguments = decode(record.input) else { return .raw }
            return .diff(path: arguments.path, lines: diffLines(old: arguments.oldText, new: arguments.newText))
        case .list:
            guard let arguments: FileListArguments = decode(record.input),
                  let output: FileListOutput = decode(record.output) else { return .raw }
            return .entries(path: arguments.path ?? ".", items: output.entries.map { Entry(path: $0.path, isDirectory: $0.type == "directory") })
        case .search:
            guard let output: FileSearchOutput = decode(record.output) else { return .raw }
            return .matches(query: output.query, items: output.results.map { Match(path: $0.path, line: $0.line, snippet: $0.snippet) })
        case .plan:
            guard let arguments: PlanArguments = decode(record.input) else { return .raw }
            var items: [PlanItem] = []
            for item in arguments.plan {
                guard let status = planStatus(item.status) else { return .raw }
                items.append(PlanItem(step: item.step, status: status))
            }
            return .plan(items: items)
        case .question:
            guard record.questionResolution != nil, UserQuestionArguments.questions(from: record.input) != nil else { return .raw }
            return .questions
        }
    }

    /// The few words a finished row adds before its duration, or nil.
    static func resultDigest(_ record: ToolCallRecord) -> String? {
        guard let tool = BuiltInTool(record.name) else { return nil }
        // A command that exits non-zero has failed, and its exit code is the news.
        if tool == .shell {
            guard record.state.isTerminal, let exitCode = record.mechanicalTerminalFact?.shellTerminal?.exitCode, exitCode != 0 else { return nil }
            return "exit \(exitCode)"
        }
        guard record.state == .completed else { return nil }
        switch tool {
        case .shell:
            return nil
        case .edit:
            // The path says which file; the diff is one click away. Line counts on every edit
            // row were noise.
            return nil
        case .write:
            guard let arguments: WriteArguments = decode(record.input) else { return nil }
            return String(localized: "\(lines(arguments.content).count) lines")
        case .read:
            guard let arguments: ReadArguments = decode(record.input), arguments.offset != nil || arguments.limit != nil,
                  let start = wholeNumber(arguments.offset ?? 1) else { return nil }
            guard let limit = arguments.limit else { return String(localized: "From line \(start)") }
            guard let count = wholeNumber(limit) else { return nil }
            return String(localized: "Lines \(start)–\(start + count - 1)")
        case .list:
            guard let output: FileListOutput = decode(record.output) else { return nil }
            return String(localized: "\(output.count) items")
        case .search:
            guard let output: FileSearchOutput = decode(record.output) else { return nil }
            return String(localized: "\(output.count) matches")
        case .plan:
            guard let arguments: PlanArguments = decode(record.input) else { return nil }
            return String(localized: "\(arguments.plan.filter { $0.status == "completed" }.count)/\(arguments.plan.count) done")
        case .question:
            switch record.questionResolution {
            case .answered: return String(localized: "Answered")
            case .skipped: return String(localized: "Skipped")
            case .superseded: return String(localized: "Not answered")
            case nil: return nil
            }
        }
    }

    /// `new` against `old`, line by line, in reading order.
    static func diffLines(old: String, new: String) -> [DiffLine] {
        let oldLines = lines(old), newLines = lines(new)
        let difference = newLines.difference(from: oldLines)
        let removed = Set(difference.removals.map(offset))
        let inserted = Set(difference.insertions.map(offset))
        var result: [DiffLine] = []
        var oldIndex = 0, newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removed.contains(oldIndex) {
                result.append(DiffLine(kind: .removed, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, inserted.contains(newIndex) {
                result.append(DiffLine(kind: .added, text: newLines[newIndex]))
                newIndex += 1
            } else {
                result.append(DiffLine(kind: .unchanged, text: oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        return result
    }

    private static func offset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }

    /// A text's lines; a final newline does not start another line.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    // MARK: - Decoding

    /// The built-in tools with their own details, by the name test the row's resolver uses. An MCP
    /// tool is never one of them, whatever its name ends with.
    private enum BuiltInTool: Equatable {
        case shell, read, write, edit, list, search, plan, question

        init?(_ name: String) {
            guard MCPToolNamespace.parse(exposedName: name) == nil else { return nil }
            func named(_ tool: String) -> Bool { name == tool || name.hasSuffix(tool) }
            if named("shell_execute") { self = .shell }
            else if named("file_read") { self = .read }
            else if named("file_write") { self = .write }
            else if named("file_edit") { self = .edit }
            else if named("file_list") { self = .list }
            else if named("file_search") { self = .search }
            else if named("update_plan") { self = .plan }
            else if named("ask_user_question") { self = .question }
            else { return nil }
        }
    }

    /// `file_list`'s output as the executor writes it.
    private struct FileListOutput: Decodable {
        struct Item: Decodable { let path: String; let type: String }
        let count: Int
        let entries: [Item]
    }

    /// `file_search`'s output as the executor writes it.
    private struct FileSearchOutput: Decodable {
        struct Item: Decodable { let path: String; let line: Int?; let snippet: String? }
        let query: String
        let count: Int
        let results: [Item]
    }

    private static func decode<T: Decodable>(_ text: String) -> T? {
        try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static func planStatus(_ status: String) -> PlanItem.Status? {
        switch status {
        case "pending": .pending
        case "in_progress": .inProgress
        case "completed": .completed
        default: nil
        }
    }

    /// A positive whole number, as `FileReadWindow` takes `offset` and `limit`.
    private static func wholeNumber(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() == value, value >= 1 else { return nil }
        return Int(exactly: value)
    }
}
