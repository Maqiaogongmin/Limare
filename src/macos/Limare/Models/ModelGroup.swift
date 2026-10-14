import Foundation

public enum RoutingStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case fallback
    case loadBalance

    public var displayName: String {
        switch self {
        case .fallback: "Fallback"
        case .loadBalance: "Load Balance"
        }
    }
}

public enum FallbackStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case limited
    case always

    public var displayName: String {
        switch self {
        case .limited: "Default"
        case .always: "Always"
        }
    }
}

public enum ThinkingLevel: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    /// Ultra is a persisted harness intent, never a provider effort or selectable tier.
    public static let supportsUltraOrchestration = false
    public static var selectableCases: [ThinkingLevel] { allCases.filter { $0 != .ultra } }

    public var isEnabled: Bool {
        self != .off
    }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }

    private var rank: Int {
        switch self {
        case .off: 0
        case .minimal: 1
        case .low: 2
        case .medium: 3
        case .high: 4
        case .xhigh: 5
        case .max: 6
        case .ultra: 7
        }
    }

    public static func < (lhs: ThinkingLevel, rhs: ThinkingLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ModelGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Ordered member IDs, each formatted as "{providerUUID}:{modelID}"
    public var memberEntryIds: [String]
    public var strategy: RoutingStrategy
    public var fallbackStrategy: FallbackStrategy
    public var defaultThinkingLevel: ThinkingLevel?
    public var contextLimitTokens: Int?

    public init(
        id: String = UUID().uuidString,
        name: String,
        memberEntryIds: [String] = [],
        strategy: RoutingStrategy = .fallback,
        fallbackStrategy: FallbackStrategy = .limited,
        defaultThinkingLevel: ThinkingLevel? = nil,
        contextLimitTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.memberEntryIds = memberEntryIds
        self.strategy = strategy
        self.fallbackStrategy = fallbackStrategy
        self.defaultThinkingLevel = defaultThinkingLevel
        self.contextLimitTokens = contextLimitTokens
    }

    public static func parseEntryId(_ entryId: String) -> (providerID: UUID, modelID: String)? {
        let parts = entryId.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let providerUUID = UUID(uuidString: String(parts[0])) else {
            return nil
        }
        return (providerUUID, String(parts[1]))
    }

    static func makeEntryId(providerID: UUID, modelID: String) -> String {
        "\(providerID.uuidString):\(modelID)"
    }
}

struct ModelGroupConfigFile: Codable, Sendable {
    var groups: [ModelGroup]
    var defaultPrimaryGroupId: String?
    var defaultSubGroupId: String?
    var voiceInputGroupId: String?
    var voiceOutputGroupId: String?
    var visionGroupId: String?
    var agentLoopModelEntryIds: [String]
    var agentLoopGroupIds: [String]

    init(
        groups: [ModelGroup] = [],
        defaultPrimaryGroupId: String? = nil,
        defaultSubGroupId: String? = nil,
        voiceInputGroupId: String? = nil,
        voiceOutputGroupId: String? = nil,
        visionGroupId: String? = nil,
        agentLoopModelEntryIds: [String] = [],
        agentLoopGroupIds: [String] = []
    ) {
        self.groups = groups
        self.defaultPrimaryGroupId = defaultPrimaryGroupId
        self.defaultSubGroupId = defaultSubGroupId
        self.voiceInputGroupId = voiceInputGroupId
        self.voiceOutputGroupId = voiceOutputGroupId
        self.visionGroupId = visionGroupId
        self.agentLoopModelEntryIds = agentLoopModelEntryIds
        self.agentLoopGroupIds = agentLoopGroupIds
    }

    private enum CodingKeys: String, CodingKey {
        case groups, defaultPrimaryGroupId, defaultSubGroupId, voiceInputGroupId, voiceOutputGroupId
        case visionGroupId, agentLoopModelEntryIds, agentLoopGroupIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([ModelGroup].self, forKey: .groups) ?? []
        defaultPrimaryGroupId = try container.decodeIfPresent(String.self, forKey: .defaultPrimaryGroupId)
        defaultSubGroupId = try container.decodeIfPresent(String.self, forKey: .defaultSubGroupId)
        voiceInputGroupId = try container.decodeIfPresent(String.self, forKey: .voiceInputGroupId)
        voiceOutputGroupId = try container.decodeIfPresent(String.self, forKey: .voiceOutputGroupId)
        visionGroupId = try container.decodeIfPresent(String.self, forKey: .visionGroupId)
        agentLoopModelEntryIds = try container.decodeIfPresent([String].self, forKey: .agentLoopModelEntryIds) ?? []
        agentLoopGroupIds = try container.decodeIfPresent([String].self, forKey: .agentLoopGroupIds) ?? []
    }
}

struct ModelPickerEntry: Identifiable, Sendable {
    let providerID: UUID
    let providerName: String
    let model: ProviderModel

    var id: String {
        ModelGroup.makeEntryId(providerID: providerID, modelID: model.id)
    }
}

struct ProviderPickerSection: Identifiable, Sendable {
    let provider: ProviderConfiguration
    let entries: [ModelPickerEntry]

    var id: UUID { provider.id }
}
