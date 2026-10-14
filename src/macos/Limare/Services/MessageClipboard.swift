import Foundation
import AppKit

enum MessageClipboard {
    @discardableResult
    static func copy(text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    static func copyMessage(_ message: ChatMessage) -> Bool {
        guard let payload = MessageCopyPayloadResolver.copyPayload(for: message) else {
            return false
        }
        return copy(text: payload)
    }
}
