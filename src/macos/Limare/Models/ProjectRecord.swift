import Foundation

struct ProjectRecord: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var workspace: WorkspaceConfiguration?
    var conversationIDs: [UUID]
    var pinnedAt: Date?
    var schemaVersion: Int

    var isPinned: Bool {
        pinnedAt != nil
    }

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        workspace: WorkspaceConfiguration? = nil,
        conversationIDs: [UUID] = [],
        pinnedAt: Date? = nil,
        schemaVersion: Int = ProjectRecord.currentSchemaVersion
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.workspace = workspace
        self.conversationIDs = conversationIDs
        self.pinnedAt = pinnedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, updatedAt, workspace, conversationIDs, pinnedAt, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        workspace = try container.decodeIfPresent(WorkspaceConfiguration.self, forKey: .workspace)
        conversationIDs = try container.decodeIfPresent([UUID].self, forKey: .conversationIDs) ?? []
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
