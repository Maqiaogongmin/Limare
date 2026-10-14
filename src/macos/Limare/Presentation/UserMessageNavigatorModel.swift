import CoreGraphics
import Foundation

/// Presentation model for the transcript's user-message navigator: one tick per user message,
/// magnified by pointer proximity, that jumps the transcript to the selected message.
enum UserMessageNavigatorModel {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let preview: String
    }

    /// The navigator only earns its place once there is more than one message to move between.
    static let minimumEntryCount = 2
    static let previewCharacterLimit = 160

    static func entries(from messages: [ChatMessage]) -> [Entry] {
        messages.compactMap { message in
            guard message.role == .user else { return nil }
            let preview = previewText(for: message)
            guard !preview.isEmpty else { return nil }
            return Entry(id: message.id, preview: preview)
        }
    }

    static func previewText(for message: ChatMessage) -> String {
        let collapsed = message.content
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if !collapsed.isEmpty {
            return collapsed.count > previewCharacterLimit
                ? String(collapsed.prefix(previewCharacterLimit)) + "…"
                : collapsed
        }
        return message.attachments.map(\.filename).joined(separator: ", ")
    }

    /// The user message whose turn the reader is in: the last user message at or above the
    /// topmost visible transcript row. Returns `nil` when no tracked row is visible, so callers
    /// keep their previous answer instead of flickering.
    static func activeEntryID(visibleIDs: [UUID], messages: [ChatMessage]) -> UUID? {
        let visible = Set(visibleIDs)
        guard let topIndex = messages.firstIndex(where: { visible.contains($0.id) }) else { return nil }
        if let owner = messages[...topIndex].last(where: { $0.role == .user }) {
            return owner.id
        }
        return messages.first(where: { $0.role == .user })?.id
    }

    /// The entry `step` positions away from `activeID`, clamped to the list; `nil` when already at
    /// that end. Without an active entry, stepping starts from the latest message.
    static func adjacentEntryID(from activeID: UUID?, step: Int, in entries: [Entry]) -> UUID? {
        guard !entries.isEmpty else { return nil }
        let current = activeID.flatMap { id in entries.firstIndex(where: { $0.id == id }) } ?? entries.count - 1
        let target = min(max(current + step, 0), entries.count - 1)
        return target == current ? nil : entries[target].id
    }

    /// Distance between tick centers: comfortable by default, compressed to fit long sessions.
    static func tickPitch(entryCount: Int, availableHeight: CGFloat, preferred: CGFloat = 10, minimum: CGFloat = 3) -> CGFloat {
        guard entryCount > 0, availableHeight > 0 else { return preferred }
        return max(minimum, min(preferred, availableHeight / CGFloat(entryCount)))
    }

    /// 1 at the pointer, falling smoothly to 0 at `radius`; 0 without a pointer.
    static func proximity(distance: CGFloat?, radius: CGFloat = 36) -> CGFloat {
        guard let distance, radius > 0 else { return 0 }
        let t = min(max(distance / radius, 0), 1)
        return 0.5 * (1 + cos(t * .pi))
    }

    /// The tick under the pointer, clamped to the list.
    static func index(atY y: CGFloat, pitch: CGFloat, entryCount: Int) -> Int? {
        guard entryCount > 0, pitch > 0 else { return nil }
        return min(max(Int(y / pitch), 0), entryCount - 1)
    }
}
