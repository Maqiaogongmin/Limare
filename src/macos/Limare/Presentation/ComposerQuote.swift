import Foundation

/// Adds selected reply text as an editable Markdown blockquote, preserving the current draft.
enum ComposerQuote {
    static func appending(_ selection: String, to draft: String) -> String {
        let text = selection.trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return draft }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let quote = normalized.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        let separator = draft.isEmpty ? "" : (draft.hasSuffix("\n\n") ? "" : (draft.hasSuffix("\n") ? "\n" : "\n\n"))
        return draft + separator + quote + "\n\n"
    }
}
