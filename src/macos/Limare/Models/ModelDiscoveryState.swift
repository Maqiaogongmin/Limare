import Foundation

public enum ModelDiscoveryCompleteness: String, Codable, Hashable, Sendable {
    case complete, pagination, emptyAfterNonEmpty, decodeTruncated
    public var isComplete: Bool { self == .complete }
}
public struct ProviderModelRejection: Codable, Hashable, Sendable {
    public var at: Date
    public var httpStatus: Int
    public var code: String
}
public struct ModelDiscoveryState: Codable, Hashable, Sendable {
    public var lastSeenAt: Date?
    public var lastCompleteListedAt: Date?
    public var notListedSince: Date?
    public var consecutiveMisses = 0
    public var providerRejection: ProviderModelRejection?
    public init() {}
    public var availability: String {
        guard notListedSince != nil else { return lastCompleteListedAt == nil ? "unknown" : "listed" }
        return providerRejection == nil ? "not_listed" : "removed_by_provider"
    }
    public var isRemoved: Bool { availability == "removed_by_provider" }
    public var isAbsent: Bool { notListedSince != nil }
    public var badge: String? {
        isRemoved ? "Removed by provider" : isAbsent ? "Not listed by provider" : nil
    }
}
public struct ProviderDiscoveryObservation: Codable, Hashable, Sendable {
    public var fetchedAt: Date?
    public var completeness: ModelDiscoveryCompleteness?
    public var listedCount: Int?
    public var lastFailureAt: Date?
    public var lastFailure: String?
    public init() {}
}
struct ModelDiscoveryResult: Sendable {
    var models: [ProviderModel]
    var completeness: ModelDiscoveryCompleteness
    var fetchedAt: Date
}
