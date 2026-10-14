import Foundation

public struct ResponsesReasoningEcho: Codable, Equatable, Sendable {
    public let providerID: UUID
    public let modelID: String
    public let items: [ResponsesReasoningItem]

    public init(
        providerID: UUID,
        modelID: String,
        items: [ResponsesReasoningItem]
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.items = items
    }
}

public struct ResponsesReasoningItem: Codable, Equatable, Sendable {
    public let id: String
    public let encryptedContent: String?
    public let summary: [String]

    public init(
        id: String,
        encryptedContent: String? = nil,
        summary: [String] = []
    ) {
        self.id = id
        self.encryptedContent = encryptedContent
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case encryptedContent = "encrypted_content"
        case summary
    }
}
