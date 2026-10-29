import Foundation

/// Turns review comments into the plain text that goes into the composer. Plain text, not a
/// message type of its own, so the phone page and a resumed conversation read it the same way.
/// Model-facing, so English.
enum GitReviewMessageBuilder {
    struct Context: Sendable, Equatable {
        var projectName: String
        var branch: GitBranchState?
        var readAt: Date?
    }

    /// The message for `comments`, or nil when none has any text.
    static func message(for comments: [GitReviewComment], context: Context) -> String? {
        let written = comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !written.isEmpty else { return nil }

        var header = "Project: \(context.projectName)"
        if let branch = context.branch { header += "  Branch: \(branchLabel(branch))" }
        if let readAt = context.readAt { header += "  Read at: \(timeFormatter.string(from: readAt))" }
        var lines = ["Review comments on the current changes", header]

        let byPath = Dictionary(grouping: written, by: \.anchor.path)
        for path in byPath.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            lines.append("")
            lines.append(path)
            for comment in byPath[path]!.sorted(by: order) {
                lines.append(entryLine(comment))
                for bodyLine in comment.body.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") {
                    lines.append("  " + bodyLine)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `draft` with `message` after it, a blank line between; an empty draft gives just the message.
    static func appending(_ message: String, to draft: String) -> String {
        var kept = draft
        while kept.last?.isNewline == true { kept.removeLast() }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message : kept + "\n\n" + message
    }

    static func branchLabel(_ branch: GitBranchState) -> String {
        switch branch {
        case .branch(let name): name
        case .detached(let sha): "detached at \(sha)"
        case .unborn(let name): name.isEmpty ? "no commits yet" : "\(name) (no commits yet)"
        }
    }

    private static func order(_ lhs: GitReviewComment, _ rhs: GitReviewComment) -> Bool {
        let scopes = GitReviewScope.allCases
        let l = (scopes.firstIndex(of: lhs.anchor.scope) ?? 0, lhs.anchor.line, lhs.anchor.side == .old ? 0 : 1)
        let r = (scopes.firstIndex(of: rhs.anchor.scope) ?? 0, rhs.anchor.line, rhs.anchor.side == .old ? 0 : 1)
        return l < r
    }

    private static func entryLine(_ comment: GitReviewComment) -> String {
        let anchor = comment.anchor
        let side: String
        switch (anchor.side, anchor.lineKind) {
        case (.old, .removed): side = "old, removed"
        case (.old, _): side = "old"
        case (.new, .added): side = "new, added"
        case (.new, _): side = "new"
        }
        let scope = anchor.base.map { "\(anchor.scope.messageLabel) vs \($0)" } ?? anchor.scope.messageLabel
        var line = "- [\(scope)] line \(anchor.line) (\(side)): \(quoted(anchor.quote))"
        if comment.isOutdated { line += " (outdated, line may have moved)" }
        return line
    }

    /// The line's text in a code span long enough for the backticks it contains.
    private static func quoted(_ text: String) -> String {
        var quote = text
        if quote.hasSuffix("\r") { quote.removeLast() }
        if quote.trimmingCharacters(in: .whitespaces).isEmpty { return "(blank line)" }
        guard quote.contains("`") else { return "`\(quote)`" }
        return "`` \(quote) ``"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
