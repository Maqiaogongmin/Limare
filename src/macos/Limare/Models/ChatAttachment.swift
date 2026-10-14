import Foundation

public enum ChatAttachmentKind: String, Codable, Sendable {
    case image
    case text
    case pdf
    case audio
    case video
    case archive
    case other
}

extension ChatAttachmentKind {
    public var systemImageName: String {
        switch self {
        case .image: "photo"
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        case .video: "film"
        case .archive: "archivebox"
        case .other: "document"
        }
    }
}

public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ChatAttachmentKind
    public let filename: String
    public let relativePath: String
    public let mimeType: String
    public let byteCount: Int
    public let width: Int?
    public let height: Int?
    public let contentTypeIdentifier: String?
    public let representationProfile: RepresentationProfileIdentity?

    public init(
        id: UUID = UUID(),
        kind: ChatAttachmentKind = .image,
        filename: String,
        relativePath: String,
        mimeType: String,
        byteCount: Int,
        width: Int? = nil,
        height: Int? = nil,
        contentTypeIdentifier: String? = nil,
        representationProfile: RepresentationProfileIdentity? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.contentTypeIdentifier = contentTypeIdentifier
        self.representationProfile = representationProfile
    }
}
