import Foundation
import UniformTypeIdentifiers

public struct AttachmentClassification: Sendable, Equatable {
    public let kind: ChatAttachmentKind
    public let mimeType: String
    public let contentTypeIdentifier: String?
}

public enum AttachmentClassifier {
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "yaml", "yml", "xml", "csv", "log",
        "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java",
        "kt", "c", "cpp", "h", "hpp", "css", "html", "sh"
    ]

    public static func classify(url: URL) -> AttachmentClassification {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let kind: ChatAttachmentKind
        if type?.conforms(to: .image) == true { kind = .image }
        else if type?.conforms(to: .pdf) == true { kind = .pdf }
        else if type?.conforms(to: .audio) == true { kind = .audio }
        else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
        else if type?.conforms(to: .archive) == true { kind = .archive }
        else if type?.conforms(to: .text) == true || textExtensions.contains(ext) { kind = .text }
        else { kind = .other }
        return AttachmentClassification(
            kind: kind,
            mimeType: type?.preferredMIMEType ?? fallbackMIME(kind: kind),
            contentTypeIdentifier: type?.identifier
        )
    }

    private static func fallbackMIME(kind: ChatAttachmentKind) -> String {
        switch kind {
        case .image: "image/*"
        case .text: "text/plain"
        case .pdf: "application/pdf"
        case .audio: "audio/*"
        case .video: "video/*"
        case .archive: "application/octet-stream"
        case .other: "application/octet-stream"
        }
    }
}
