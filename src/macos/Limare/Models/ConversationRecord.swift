import Foundation

enum ConversationModelSource: Codable, Equatable, Hashable, Sendable {
    case direct(providerID: UUID, modelID: String)
    case group(groupID: String)

    private enum CodingKeys: String, CodingKey {
        case type, providerID, modelID, groupID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "direct":
            let providerID = try container.decode(UUID.self, forKey: .providerID)
            let modelID = try container.decode(String.self, forKey: .modelID)
            self = .direct(providerID: providerID, modelID: modelID)
        case "group":
            let groupID = try container.decode(String.self, forKey: .groupID)
            self = .group(groupID: groupID)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown model source type: \(type)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct(let providerID, let modelID):
            try container.encode("direct", forKey: .type)
            try container.encode(providerID, forKey: .providerID)
            try container.encode(modelID, forKey: .modelID)
        case .group(let groupID):
            try container.encode("group", forKey: .type)
            try container.encode(groupID, forKey: .groupID)
        }
    }
}

/// A Compact command that finished: the transcript shows it as a line after the message that
/// was last when it ran, as Claude Code and Codex show theirs. Display only; what the model
/// reads is the context lifecycle's state.
struct CompactionMarker: Codable, Equatable, Sendable {
    let afterMessageID: UUID
    let tokensBefore: Int
    let tokensAfter: Int
    let date: Date
}

struct ConversationRecord: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5
    static let defaultTitle = "New Conversation"

    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var projectID: UUID?
    var workspace: WorkspaceConfiguration?
    var providerID: UUID?
    var modelID: String?
    var modelSource: ConversationModelSource?
    var subModelSource: ConversationModelSource?
    /// Conversation policy: may this Primary conversation admit new delegated Children?
    /// Orthogonal to `subModelSource` (which helper model a Child would use). Turning it off
    /// never clears `subModelSource` and never cancels existing Children. A new conversation
    /// starts with it off (`defaultSubagentEnabled`); records from before schema 5 decode as
    /// `true`, the policy they ran under. Ignored for Native Children, which never delegate.
    var subagentEnabled: Bool
    /// Delegation spends extra tokens on a helper model, so a new conversation asks for it.
    static let defaultSubagentEnabled = false
    var thinkingLevelOverride: ThinkingLevel?
    var messages: [ChatMessage]
    var memoryEnabled: Bool
    var status: String?
    var pinnedAt: Date?
    var archivedAt: Date?
    var nativeDelegationTaskID: UUID?
    var nativeDelegationParentID: UUID?
    /// The user message an automatically generated title was derived from; nil for titles the
    /// user set and for records written before titles carried provenance. Retracting that
    /// message resets the title, and a late generation result for a retracted message is dropped.
    var generatedTitleSourceMessageID: UUID?
    /// Fence written in the same save that retracts a turn whose interrupted run still had a
    /// recovery record. Startup reconciliation never offers recovery for this run, even when
    /// the separate discard of its recovery record failed or never happened.
    var retractedRecoveryRunID: UUID?
    /// Finished Compact commands, oldest first.
    var compactionMarkers: [CompactionMarker] = []
    var isNativeDelegationChild: Bool { nativeDelegationTaskID != nil }
    var schemaVersion: Int

    var isPinned: Bool {
        pinnedAt != nil
    }

    var isArchived: Bool {
        archivedAt != nil
    }

    /// Semantic accessor for conversation-scoped Memory projection policy (MEM-G04).
    /// Preserves underlying Codable `memoryEnabled` schema field for backwards compatibility.
    var shouldProjectMemory: Bool {
        !isNativeDelegationChild
    }

    var effectiveModelSource: ConversationModelSource? {
        if let modelSource {
            return modelSource
        }
        if let providerID, let modelID, !modelID.isEmpty {
            return .direct(providerID: providerID, modelID: modelID)
        }
        return nil
    }

    init(
        id: UUID = UUID(),
        title: String = ConversationRecord.defaultTitle,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectID: UUID? = nil,
        workspace: WorkspaceConfiguration? = nil,
        providerID: UUID? = nil,
        modelID: String? = nil,
        modelSource: ConversationModelSource? = nil,
        subModelSource: ConversationModelSource? = nil,
        subagentEnabled: Bool = ConversationRecord.defaultSubagentEnabled,
        thinkingLevelOverride: ThinkingLevel? = nil,
        messages: [ChatMessage] = [],
        memoryEnabled: Bool = true,
        status: String? = nil,
        pinnedAt: Date? = nil,
        archivedAt: Date? = nil,
        nativeDelegationTaskID: UUID? = nil,
        nativeDelegationParentID: UUID? = nil,
        generatedTitleSourceMessageID: UUID? = nil,
        retractedRecoveryRunID: UUID? = nil,
        schemaVersion: Int = ConversationRecord.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectID = projectID
        self.workspace = workspace
        if case .direct(let pID, let mID) = modelSource {
            self.providerID = providerID ?? pID
            self.modelID = modelID ?? mID
        } else {
            self.providerID = providerID
            self.modelID = modelID
        }
        self.modelSource = modelSource ?? (providerID != nil && modelID != nil ? .direct(providerID: providerID!, modelID: modelID!) : nil)
        self.subModelSource = subModelSource
        self.subagentEnabled = subagentEnabled
        self.thinkingLevelOverride = thinkingLevelOverride
        self.messages = messages
        self.memoryEnabled = memoryEnabled
        self.status = status
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.nativeDelegationTaskID = nativeDelegationTaskID
        self.nativeDelegationParentID = nativeDelegationParentID
        self.generatedTitleSourceMessageID = generatedTitleSourceMessageID
        self.retractedRecoveryRunID = retractedRecoveryRunID
        self.schemaVersion = schemaVersion
    }

    var isDisposablePlaceholder: Bool {
        !isNativeDelegationChild && messages.isEmpty
            && (title.isEmpty || title == Self.defaultTitle)
            && pinnedAt == nil
            && archivedAt == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, projectID, workspace, providerID, modelID, modelSource, subModelSource, subagentEnabled
        case thinkingLevelOverride, messages, memoryEnabled, status, pinnedAt, archivedAt, schemaVersion
        case nativeDelegationTaskID, nativeDelegationParentID, generatedTitleSourceMessageID
        case retractedRecoveryRunID, compactionMarkers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        workspace = try container.decodeIfPresent(WorkspaceConfiguration.self, forKey: .workspace)
        providerID = try container.decodeIfPresent(UUID.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        modelSource = try container.decodeIfPresent(ConversationModelSource.self, forKey: .modelSource)
        subModelSource = try container.decodeIfPresent(ConversationModelSource.self, forKey: .subModelSource)
        subagentEnabled = try container.decodeIfPresent(Bool.self, forKey: .subagentEnabled) ?? true
        thinkingLevelOverride = try container.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevelOverride)
        if modelSource == nil, let providerID, let modelID, !modelID.isEmpty {
            modelSource = .direct(providerID: providerID, modelID: modelID)
        }
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        memoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        status = try container.decodeIfPresent(String.self, forKey: .status)
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        nativeDelegationTaskID = try container.decodeIfPresent(UUID.self, forKey: .nativeDelegationTaskID)
        nativeDelegationParentID = try container.decodeIfPresent(UUID.self, forKey: .nativeDelegationParentID)
        generatedTitleSourceMessageID = try container.decodeIfPresent(UUID.self, forKey: .generatedTitleSourceMessageID)
        retractedRecoveryRunID = try container.decodeIfPresent(UUID.self, forKey: .retractedRecoveryRunID)
        compactionMarkers = try container.decodeIfPresent([CompactionMarker].self, forKey: .compactionMarkers) ?? []
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}
