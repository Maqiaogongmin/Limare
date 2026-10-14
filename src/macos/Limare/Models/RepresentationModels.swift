import Foundation

public enum RepresentationEpistemicLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case inferred = "inferred"
    case declared = "declared"
    case verified = "verified"
}

public enum RepresentationFamily: String, Codable, Sendable, Equatable, CaseIterable {
    case image
    case audio
    case video
    case document
    case text
    case binary
    case unspecified
}

/// Stable, consumer-owned identity for a representation property set. The
/// generic representation seam compares this value but never interprets it.
public struct RepresentationProfileIdentity: Codable, Equatable, Hashable, Sendable {
    public let namespace: String
    public let name: String
    public let version: Int

    public init(namespace: String, name: String, version: Int) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }
}

public struct RepresentationDescriptor: Codable, Equatable, Sendable {
    public let mimeType: String
    public let family: RepresentationFamily
    public let epistemicLevel: RepresentationEpistemicLevel
    public let establishedProfile: RepresentationProfileIdentity?

    public var isVerified: Bool {
        epistemicLevel == .verified
    }

    public init(
        mimeType: String,
        family: RepresentationFamily? = nil,
        epistemicLevel: RepresentationEpistemicLevel = .inferred,
        establishedProfile: RepresentationProfileIdentity? = nil
    ) {
        self.mimeType = mimeType
        if let family = family {
            self.family = family
        } else {
            self.family = RepresentationDescriptor.inferFamily(from: mimeType)
        }
        self.epistemicLevel = epistemicLevel
        self.establishedProfile = establishedProfile
    }

    public static func inferFamily(from mimeType: String) -> RepresentationFamily {
        let lower = mimeType.lowercased()
        if lower.starts(with: "image/") { return .image }
        if lower.starts(with: "audio/") { return .audio }
        if lower.starts(with: "video/") { return .video }
        if lower.starts(with: "text/") { return .text }
        if lower == "application/pdf" || lower.contains("document") || lower.contains("msword") || lower.contains("officedocument") {
            return .document
        }
        return .binary
    }
}

public struct ConversionBudget: Codable, Equatable, Sendable {
    public let maxInputBytes: Int64?
    public let maxOutputBytes: Int64?
    public let timeoutSeconds: TimeInterval?

    public init(
        maxInputBytes: Int64? = nil,
        maxOutputBytes: Int64? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct RepresentationRequirement: Codable, Equatable, Sendable {
    public let acceptedMIMETypes: Set<String>
    public let acceptedFamilies: Set<RepresentationFamily>
    public let requiresVerified: Bool
    public let requiredProfile: RepresentationProfileIdentity?
    public let budget: ConversionBudget

    public init(
        acceptedMIMETypes: Set<String> = [],
        acceptedFamilies: Set<RepresentationFamily> = [],
        requiresVerified: Bool = false,
        budget: ConversionBudget = ConversionBudget(),
        requiredProfile: RepresentationProfileIdentity? = nil
    ) {
        self.acceptedMIMETypes = acceptedMIMETypes
        self.acceptedFamilies = acceptedFamilies
        self.requiresVerified = requiresVerified
        self.budget = budget
        self.requiredProfile = requiredProfile
    }

    public func matches(descriptor: RepresentationDescriptor) -> Bool {
        if requiresVerified && descriptor.epistemicLevel != .verified {
            return false
        }
        if let requiredProfile, descriptor.establishedProfile != requiredProfile {
            return false
        }
        return acceptsFormat(mimeType: descriptor.mimeType, family: descriptor.family)
    }

    public func acceptsFormat(mimeType: String?, family: RepresentationFamily? = nil) -> Bool {
        if let mime = mimeType {
            if acceptedMIMETypes.contains(mime) {
                return true
            }
            let inferred = family ?? RepresentationDescriptor.inferFamily(from: mime)
            if acceptedFamilies.contains(inferred) {
                return true
            }
        }
        if let fam = family, acceptedFamilies.contains(fam) {
            return true
        }
        return false
    }
}

public struct ConversionRoute: Codable, Equatable, Sendable, Hashable {
    public let sourceMIME: String
    public let targetMIME: String
    public let priority: Int

    public var routeID: String {
        "\(sourceMIME)->\(targetMIME)"
    }

    public init(sourceMIME: String, targetMIME: String, priority: Int = 0) {
        self.sourceMIME = sourceMIME
        self.targetMIME = targetMIME
        self.priority = priority
    }
}

public struct ConverterCapability: Codable, Equatable, Sendable {
    public let id: String
    public let supportedRoutes: [ConversionRoute]
    public let maxInputBytes: Int64?

    public init(id: String, supportedRoutes: [ConversionRoute], maxInputBytes: Int64? = nil) {
        self.id = id
        self.supportedRoutes = supportedRoutes
        self.maxInputBytes = maxInputBytes
    }
}

public enum RepresentationCleanupStatus: String, Codable, Sendable, Equatable {
    case notRequired = "not_required"
    case completed = "completed"
    case pending = "pending"
    case failed = "failed"
}

public enum RepresentationTerminalState: String, Codable, Sendable, Equatable {
    case satisfied = "satisfied"
    case converted = "converted"
    case unsupported = "unsupported"
    case missing = "missing"
    case denied = "denied"
    case overBudget = "over_budget"
    case cancelled = "cancelled"
    case failed = "failed"
}

public struct ConversionExecutionError: Error, LocalizedError, Sendable, Equatable {
    public let reason: String
    public let cleanupStatus: RepresentationCleanupStatus

    public init(reason: String, cleanupStatus: RepresentationCleanupStatus = .pending) {
        self.reason = reason
        self.cleanupStatus = cleanupStatus
    }

    public var errorDescription: String? {
        return reason
    }
}

public struct RepresentationAttemptRecord: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let sourceRepresentation: RepresentationDescriptor
    public let targetRequirement: RepresentationRequirement
    public let selectedConverterID: String?
    public let selectedRoute: ConversionRoute?
    public let budgetLimits: ConversionBudget
    public let terminalState: RepresentationTerminalState
    public let cleanupStatus: RepresentationCleanupStatus
    public let derivedArtifactRef: ArtifactRef?
    public let failureReason: String?

    public init(
        attemptID: UUID = UUID(),
        sourceRepresentation: RepresentationDescriptor,
        targetRequirement: RepresentationRequirement,
        selectedConverterID: String? = nil,
        selectedRoute: ConversionRoute? = nil,
        budgetLimits: ConversionBudget,
        terminalState: RepresentationTerminalState,
        cleanupStatus: RepresentationCleanupStatus,
        derivedArtifactRef: ArtifactRef? = nil,
        failureReason: String? = nil
    ) {
        self.attemptID = attemptID
        self.sourceRepresentation = sourceRepresentation
        self.targetRequirement = targetRequirement
        self.selectedConverterID = selectedConverterID
        self.selectedRoute = selectedRoute
        self.budgetLimits = budgetLimits
        self.terminalState = terminalState
        self.cleanupStatus = cleanupStatus
        self.derivedArtifactRef = derivedArtifactRef
        self.failureReason = failureReason
    }
}

public struct ConversionOutput: Sendable, Equatable {
    public let data: Data
    public let representation: RepresentationDescriptor
    public let filename: String?
    public let cleanupStatus: RepresentationCleanupStatus?

    public var mimeType: String {
        representation.mimeType
    }

    public var epistemicLevel: RepresentationEpistemicLevel {
        representation.epistemicLevel
    }

    public init(
        data: Data,
        representation: RepresentationDescriptor,
        filename: String? = nil,
        cleanupStatus: RepresentationCleanupStatus? = nil
    ) {
        self.data = data
        self.representation = representation
        self.filename = filename
        self.cleanupStatus = cleanupStatus
    }

    public init(
        data: Data,
        mimeType: String,
        epistemicLevel: RepresentationEpistemicLevel = .declared,
        filename: String? = nil,
        cleanupStatus: RepresentationCleanupStatus? = nil
    ) {
        let desc = RepresentationDescriptor(mimeType: mimeType, epistemicLevel: epistemicLevel)
        self.init(
            data: data,
            representation: desc,
            filename: filename,
            cleanupStatus: cleanupStatus
        )
    }
}

public enum RepresentationTerminalResult: Sendable, Equatable {
    case satisfied(content: ResourceResolvedContent, attempt: RepresentationAttemptRecord)
    case converted(artifactRef: ArtifactRef, descriptor: ArtifactDescriptor, attempt: RepresentationAttemptRecord)
    case directUse(DirectUseConversionResult, attempt: RepresentationAttemptRecord)
    case unsupported(reason: String, attempt: RepresentationAttemptRecord)
    case missing(reason: String, attempt: RepresentationAttemptRecord)
    case denied(reason: String, attempt: RepresentationAttemptRecord)
    case overBudget(reason: String, attempt: RepresentationAttemptRecord)
    case cancelled(reason: String, cleanupStatus: RepresentationCleanupStatus, attempt: RepresentationAttemptRecord)
    case failed(reason: String, cleanupStatus: RepresentationCleanupStatus, attempt: RepresentationAttemptRecord)

    public var isSatisfiedOrConverted: Bool {
        switch self {
        case .satisfied, .converted, .directUse: return true
        default: return false
        }
    }

    public var attempt: RepresentationAttemptRecord {
        switch self {
        case .satisfied(_, let a): return a
        case .converted(_, _, let a): return a
        case .directUse(_, let a): return a
        case .unsupported(_, let a): return a
        case .missing(_, let a): return a
        case .denied(_, let a): return a
        case .overBudget(_, let a): return a
        case .cancelled(_, _, let a): return a
        case .failed(_, _, let a): return a
        }
    }

    public var cleanupStatus: RepresentationCleanupStatus {
        attempt.cleanupStatus
    }

    public var derivedArtifactRef: ArtifactRef? {
        switch self {
        case .converted(let artRef, _, _): return artRef
        default: return nil
        }
    }
}

public enum RepresentationRetentionIntent: Sendable, Equatable {
    case directUse
    case materialized(retentionClass: ArtifactRetentionClass)
}

/// Transient output for the immediate consumer. It deliberately carries no
/// ArtifactRef and creates no durable authority by itself.
public struct DirectUseConversionResult: Sendable, Equatable {
    public let data: Data
    public let representation: RepresentationDescriptor
    public let sourceRef: ResourceRef
    public let converterID: String
    public let selectedRoute: ConversionRoute
    public let attemptID: UUID
    public let cleanupStatus: RepresentationCleanupStatus
    public let filename: String?

    public init(data: Data, representation: RepresentationDescriptor, sourceRef: ResourceRef, converterID: String, selectedRoute: ConversionRoute, attemptID: UUID, cleanupStatus: RepresentationCleanupStatus, filename: String?) {
        self.data = data
        self.representation = representation
        self.sourceRef = sourceRef
        self.converterID = converterID
        self.selectedRoute = selectedRoute
        self.attemptID = attemptID
        self.cleanupStatus = cleanupStatus
        self.filename = filename
    }
}

public protocol RepresentationConverter: Sendable {
    var capability: ConverterCapability { get }
    func canConvert(sourceMIME: String, targetMIME: String) -> Bool
    func applicableRoutes(source: ResourceResolvedContent, requirement: RepresentationRequirement) throws -> [ConversionRoute]
    func convert(
        source: ResourceResolvedContent,
        route: ConversionRoute,
        budget: ConversionBudget
    ) async throws -> ConversionOutput
}

extension RepresentationConverter {
    public func canConvert(sourceMIME: String, targetMIME: String) -> Bool {
        return capability.supportedRoutes.contains { route in
            route.sourceMIME.lowercased() == sourceMIME.lowercased() &&
            route.targetMIME.lowercased() == targetMIME.lowercased()
        }
    }

    public func applicableRoutes(source: ResourceResolvedContent, requirement: RepresentationRequirement) throws -> [ConversionRoute] {
        capability.supportedRoutes.filter {
            $0.sourceMIME.caseInsensitiveCompare(source.representation.mimeType) == .orderedSame &&
            requirement.acceptsFormat(mimeType: $0.targetMIME)
        }
    }
}
