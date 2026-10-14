import Foundation

/// A command typed in the composer after "/", as in Claude Code and Codex. Typing "/" opens a
/// menu of the commands that match what follows it.
struct ComposerCommand: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String

    var id: String { name }
    var invocation: String { "/" + name }

    static let compact = ComposerCommand(
        name: "compact",
        summary: "Summarize the conversation so far, so each request sends less"
    )

    static let all: [ComposerCommand] = [compact]

    /// The commands the draft is typing: a "/" then part of a name, nothing else. Names that
    /// start with the typed text come first, then names that contain it.
    static func matches(forDraft draft: String) -> [ComposerCommand] {
        guard draft.hasPrefix("/") else { return [] }
        let query = draft.dropFirst().lowercased()
        guard !query.contains(where: { $0.isWhitespace || $0 == "/" }) else { return [] }
        guard !query.isEmpty else { return all }
        let prefixed = all.filter { $0.name.lowercased().hasPrefix(query) }
        let containing = all.filter { !$0.name.lowercased().hasPrefix(query) && $0.name.lowercased().contains(query) }
        return prefixed + containing
    }
}
