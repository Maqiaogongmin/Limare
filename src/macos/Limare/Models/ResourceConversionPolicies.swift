import Foundation

/// The `resource_convert` consumer's requirement for exactly one representation
/// conversion.
///
/// This is a consumer-owned, immutable *value*: it says which source
/// representations the tool accepts, which representation it wants back, which
/// consumer-owned profile must be established, how much work is bounded, and how
/// the derived artifact is retained.
///
/// It is deliberately **not** an authority, registry, manager, store or runtime.
/// It owns no converter identity, no route priority, no ArtifactStore, no
/// permission, no conversation state and no runtime availability. Converter
/// selection stays with `RepresentationResolver`.
public struct ResourceConversionConsumerPolicy: Sendable, Equatable {
    public let resultProjection: ResourceConversionResultProjection
    /// Stable, consumer-owned identity for this requirement value. It names the
    /// requirement, never a converter or a route.
    public let policyID: String
    /// Exact source MIME types this consumer accepts. Wildcards are not used:
    /// route selection is exact-MIME semantics.
    public let acceptedSourceMIMETypes: Set<String>
    /// The single target MIME this consumer wants back.
    public let targetMIME: String
    /// Whether the returned representation must be `verified`.
    public let requiresVerified: Bool
    /// The consumer-owned profile the returned representation must establish.
    public let requiredProfile: RepresentationProfileIdentity?
    /// Bounded conversion budget for this requirement.
    public let budget: ConversionBudget
    /// Retention class for a materialized derived artifact.
    public let retentionClass: ArtifactRetentionClass

    public init(
        policyID: String,
        acceptedSourceMIMETypes: Set<String>,
        targetMIME: String,
        requiresVerified: Bool,
        requiredProfile: RepresentationProfileIdentity?,
        budget: ConversionBudget,
        retentionClass: ArtifactRetentionClass,
        resultProjection: ResourceConversionResultProjection = .text
    ) {
        self.policyID = policyID
        self.acceptedSourceMIMETypes = acceptedSourceMIMETypes
        self.targetMIME = targetMIME
        self.requiresVerified = requiresVerified
        self.requiredProfile = requiredProfile
        self.budget = budget
        self.retentionClass = retentionClass
        self.resultProjection = resultProjection
    }

    /// Exact-MIME matching on both the source and the target.
    public func matches(sourceMIME: String, targetMIME: String) -> Bool {
        let source = sourceMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = targetMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !source.isEmpty, !target.isEmpty else { return false }
        guard self.targetMIME.lowercased() == target else { return false }
        return acceptedSourceMIMETypes.contains { $0.lowercased() == source }
    }

    /// The generic representation requirement this consumer requirement implies.
    public var requirement: RepresentationRequirement {
        RepresentationRequirement(
            acceptedMIMETypes: [targetMIME],
            requiresVerified: requiresVerified,
            budget: budget,
            requiredProfile: requiredProfile
        )
    }
}

/// Consumer-owned projection of an integrity-verified derived Artifact.
public enum ResourceConversionResultProjection: Sendable, Equatable {
    case text
    case artifact(ArtifactSemanticRole)
}

/// Outcome of selecting exactly one consumer policy for a source/target pair.
public enum ResourceConversionPolicySelection: Sendable, Equatable {
    case matched(ResourceConversionConsumerPolicy)
    case unsupported(reason: String)
    case ambiguous(reason: String)
}

/// Immutable, bounded composition of the built-in `resource_convert` consumer
/// policies.
///
/// This is a fixed value list built once at the composition root — not a dynamic
/// registry. Selection is exact: one match executes, zero matches is
/// `unsupported`, and more than one match fails closed as `ambiguous`. Array
/// order never decides behavior.
public struct ResourceConversionConsumerPolicies: Sendable, Equatable {
    public let policies: [ResourceConversionConsumerPolicy]

    public init(policies: [ResourceConversionConsumerPolicy]) {
        self.policies = policies
    }

    /// Frozen PDF text v1 requirement. The numbers stay owned by
    /// `PDFTextExtractionPolicy`; this value only restates the consumer
    /// requirement in the neutral policy vocabulary.
    public static let pdfTextV1 = ResourceConversionConsumerPolicy(
        policyID: "limare.resource_convert.pdf-text.v1",
        acceptedSourceMIMETypes: ["application/pdf"],
        targetMIME: "text/plain",
        requiresVerified: true,
        requiredProfile: PDFTextRepresentationProfile.extractedV1,
        budget: ConversionBudget(
            maxInputBytes: PDFTextExtractionPolicy.maxInputBytes,
            maxOutputBytes: PDFTextExtractionPolicy.maxOutputBytes,
            timeoutSeconds: PDFTextExtractionPolicy.timeoutSeconds
        ),
        retentionClass: .temporaryExtraction
    )

    /// Video metadata v1 requirement. The numbers stay owned by
    /// `VideoMetadataExtractionPolicy`.
    public static let videoMetadataV1 = ResourceConversionConsumerPolicy(
        policyID: "limare.resource_convert.video-metadata.v1",
        acceptedSourceMIMETypes: ["video/mp4", "video/quicktime"],
        targetMIME: "application/json",
        requiresVerified: true,
        requiredProfile: VideoMetadataRepresentationProfile.metadataV1,
        budget: ConversionBudget(
            maxInputBytes: VideoMetadataExtractionPolicy.maxInputBytes,
            maxOutputBytes: VideoMetadataExtractionPolicy.maxOutputBytes,
            timeoutSeconds: VideoMetadataExtractionPolicy.timeoutSeconds
        ),
        retentionClass: .temporaryExtraction
    )

    public static let videoFrameSheetV1 = ResourceConversionConsumerPolicy(
        policyID: "limare.resource_convert.video-frame-sheet.v1",
        acceptedSourceMIMETypes: ["video/mp4", "video/quicktime"],
        targetMIME: "image/png",
        requiresVerified: true,
        requiredProfile: VideoFrameSheetProfile.frameSheetV1,
        budget: ConversionBudget(
            maxInputBytes: VideoFrameSheetPolicy.maxInputBytes,
            maxOutputBytes: VideoFrameSheetPolicy.maxOutputBytes,
            timeoutSeconds: VideoFrameSheetPolicy.timeoutSeconds
        ),
        retentionClass: .temporaryExtraction,
        resultProjection: .artifact(.extractedFrame)
    )

    /// The single built-in composition: PDF text, video metadata and frame sheet.
    public static let builtIn = ResourceConversionConsumerPolicies(
        policies: [pdfTextV1, videoMetadataV1, videoFrameSheetV1]
    )

    public func select(sourceMIME: String, targetMIME: String) -> ResourceConversionPolicySelection {
        let matched = policies.filter { $0.matches(sourceMIME: sourceMIME, targetMIME: targetMIME) }
        switch matched.count {
        case 1:
            return .matched(matched[0])
        case 0:
            return .unsupported(
                reason: "No consumer policy accepts source '\(sourceMIME)' with target '\(targetMIME)'."
            )
        default:
            return .ambiguous(
                reason: "Consumer policies are ambiguous for source '\(sourceMIME)' with target '\(targetMIME)': \(matched.map(\.policyID).sorted().joined(separator: ", "))."
            )
        }
    }
}
