import Foundation

enum MessageCopyPayloadResolver {
    
    /// Determines whether the message qualifies for a formal "Copy Message" action.
    static func canCopy(message: ChatMessage) -> Bool {
        // Formal action is unavailable during active streaming
        guard message.state != .streaming else { return false }
        
        // Cannot copy if content is empty (e.g. attachment-only message or empty placeholder)
        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        return true
    }

    /// Resolves the raw copy payload for the given message.
    /// Returns raw Markdown source without including any speaker labels, attachments, tool calls, or reasoning.
    static func copyPayload(for message: ChatMessage) -> String? {
        guard canCopy(message: message) else { return nil }
        return message.content
    }
}
