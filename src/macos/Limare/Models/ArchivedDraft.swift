import Foundation

/// Composer content kept so it can be brought back: a retracted user message, or a draft that
/// would otherwise have been replaced or discarded.
struct ArchivedDraft: Identifiable, Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case retractedMessage
        case composerDraft
    }

    let id: UUID
    let text: String
    let attachments: [ChatAttachment]
    let origin: Origin
    /// The retracted message this draft came from, for `.retractedMessage`.
    let sourceMessageID: UUID?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        attachments: [ChatAttachment],
        origin: Origin,
        sourceMessageID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.origin = origin
        self.sourceMessageID = sourceMessageID
        self.createdAt = createdAt
    }

    /// Same visible content as a composer holding `text` and `attachments`.
    func matches(text: String, attachments: [ChatAttachment]) -> Bool {
        self.text == text && self.attachments.map(\.id) == attachments.map(\.id)
    }
}
