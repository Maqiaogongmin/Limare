import Foundation

public enum ArtifactRetentionState: String, Codable, Sendable, Equatable {
    case available
    case missing
    case expired
}

public enum ArtifactRetentionClass: String, Codable, Sendable, Equatable {
    case conversationRetained
    case temporaryExtraction
    case evidencePinned
}

public enum ArtifactSemanticRole: String, Codable, Sendable, Equatable {
    case screenshot
    case generatedImage
    case extractedFrame
    case documentPage
    case deliverable
    case attachment
    case image
    case unspecified
}

public enum ArtifactProducerProvenance: String, Codable, Sendable, Equatable {
    case browserScreenshot = "browser_screenshot"
    case generatedImage = "generated_image"
    case mcpResource = "mcp_resource"
    case shellGenerated = "shell_generated"
    case hostAcquisition = "host_acquisition"
    case workspaceRegistration = "workspace_registration"
    case mediaExtraction = "media_extraction"
    case userAttachment = "user_attachment"
    case computerUseObservation = "computer_use_observation"
    case testing = "testing"
    case unspecified = "unspecified"
}

public enum MIMETypeHelper {
    public static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "pdf": return "application/pdf"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "txt", "text", "md", "markdown": return "text/plain"
        case "html", "htm": return "text/html"
        case "xml": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}

public struct ArtifactRef: Codable, Identifiable, Equatable, Sendable, Hashable {
    public let artifactID: UUID
    public let conversationID: UUID
    public var id: UUID { artifactID }

    public init(artifactID: UUID, conversationID: UUID) {
        self.artifactID = artifactID
        self.conversationID = conversationID
    }
}

public struct ConversionProvenance: Codable, Equatable, Sendable {
    public let parentResourceLocator: String
    public let converterID: String
    public let selectedRoute: ConversionRoute
    public let attemptID: UUID

    public init(
        parentResourceLocator: String,
        converterID: String,
        selectedRoute: ConversionRoute,
        attemptID: UUID
    ) {
        self.parentResourceLocator = parentResourceLocator
        self.converterID = converterID
        self.selectedRoute = selectedRoute
        self.attemptID = attemptID
    }
}

public struct ArtifactDescriptor: Codable, Identifiable, Equatable, Sendable {
    public let artifactID: UUID
    public var id: UUID { artifactID }
    public let conversationID: UUID
    public let filename: String
    public let relativePath: String
    public let mimeType: String
    public let byteCount: Int64
    public let sha256: String
    public let createdAt: Date
    public let producerProvenance: ArtifactProducerProvenance
    public let workspaceProvenance: URL?
    public let authorizationProvenance: String?
    public let parentResourceLocator: String?
    public let conversionRouteProvenance: String?
    public let conversionProvenance: ConversionProvenance?
    public let representationEpistemicLevel: RepresentationEpistemicLevel?
    public let representationProfile: RepresentationProfileIdentity?
    public var retentionState: ArtifactRetentionState
    public var retentionClass: ArtifactRetentionClass

    public init(
        artifactID: UUID = UUID(),
        conversationID: UUID,
        filename: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int64,
        sha256: String,
        createdAt: Date = Date(),
        producerProvenance: ArtifactProducerProvenance = .unspecified,
        workspaceProvenance: URL? = nil,
        authorizationProvenance: String? = nil,
        parentResourceLocator: String? = nil,
        conversionRouteProvenance: String? = nil,
        conversionProvenance: ConversionProvenance? = nil,
        representationEpistemicLevel: RepresentationEpistemicLevel? = nil,
        representationProfile: RepresentationProfileIdentity? = nil,
        retentionState: ArtifactRetentionState = .available,
        retentionClass: ArtifactRetentionClass = .conversationRetained
    ) {
        self.artifactID = artifactID
        self.conversationID = conversationID
        self.filename = filename
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.producerProvenance = producerProvenance
        self.workspaceProvenance = workspaceProvenance
        self.authorizationProvenance = authorizationProvenance
        self.parentResourceLocator = parentResourceLocator ?? conversionProvenance?.parentResourceLocator
        self.conversionRouteProvenance = conversionRouteProvenance ?? conversionProvenance?.selectedRoute.routeID
        self.conversionProvenance = conversionProvenance
        self.representationEpistemicLevel = representationEpistemicLevel
        self.representationProfile = representationProfile
        self.retentionState = retentionState
        self.retentionClass = retentionClass
    }
}
