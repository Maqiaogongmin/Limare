import Foundation

/// P0 File Preview category classification.
public enum FilePreviewKind: Equatable, Sendable {
    case markdown
    case text
    case code(language: String)
    case image
    case pdf
    case html
    case unsupported(reason: String?)

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .text: "Text"
        case .code(let lang): "\(lang) Source"
        case .image: "Image"
        case .pdf: "PDF Document"
        case .html: "HTML"
        case .unsupported: "Unsupported"
        }
    }
}

/// Metadata describing a file being previewed or inspected.
public struct FileMetadata: Equatable, Sendable {
    public let url: URL
    public let filename: String
    public let fileExtension: String
    public let sizeBytes: Int64
    public let modifiedDate: Date?
    public let lineCount: Int?
    public let dimensions: CGSize?

    public init(
        url: URL,
        filename: String,
        fileExtension: String,
        sizeBytes: Int64,
        modifiedDate: Date? = nil,
        lineCount: Int? = nil,
        dimensions: CGSize? = nil
    ) {
        self.url = url
        self.filename = filename
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.modifiedDate = modifiedDate
        self.lineCount = lineCount
        self.dimensions = dimensions
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    public var formattedSubtitle: String {
        var parts: [String] = []
        if let lineCount {
            parts.append("\(lineCount) line\(lineCount == 1 ? "" : "s")")
        }
        if let dimensions {
            parts.append("\(Int(dimensions.width)) × \(Int(dimensions.height))")
        }
        parts.append(formattedSize)
        return parts.joined(separator: " • ")
    }
}

/// Content payload for a successfully loaded preview.
public enum FilePreviewContent: Equatable, Sendable {
    case markdown(String)
    case text(String)
    case code(code: String, language: String)
    case image(data: Data, isSVG: Bool)
    case pdf(URL)
    case html(source: String, fileURL: URL)

    /// Rendered from a source the user can switch to.
    public var hasSource: Bool {
        switch self {
        case .markdown, .html: return true
        case .text, .code, .image, .pdf: return false
        }
    }
}

/// Preview data holding kind, metadata, and concrete content.
public struct FilePreviewData: Equatable, Sendable {
    public let kind: FilePreviewKind
    public let metadata: FileMetadata
    public let content: FilePreviewContent

    public init(
        kind: FilePreviewKind,
        metadata: FileMetadata,
        content: FilePreviewContent
    ) {
        self.kind = kind
        self.metadata = metadata
        self.content = content
    }
}

/// State of the file preview inside Files Surface.
public enum FilePreviewState: Equatable, Sendable {
    case idle
    case loading(URL)
    case loaded(FilePreviewData)
    case emptyFile(FileMetadata)
    case tooLarge(FileMetadata)
    case unsupported(FileMetadata)
    case error(String)
}

/// Node representing a file or directory in the Workspace File Tree.
public struct FileTreeNode: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public var children: [FileTreeNode]?
    public var sfSymbol: String

    public init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool,
        children: [FileTreeNode]? = nil,
        sfSymbol: String? = nil
    ) {
        let nodeName = name ?? url.lastPathComponent
        self.id = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.url = url
        self.name = nodeName
        self.isDirectory = isDirectory
        self.children = children
        if let sfSymbol {
            self.sfSymbol = sfSymbol
        } else if isDirectory {
            self.sfSymbol = "folder.fill"
        } else {
            self.sfSymbol = Self.defaultSymbol(for: url.pathExtension)
        }
    }

    public static func defaultSymbol(for ext: String) -> String {
        switch ext.lowercased() {
        case "md", "markdown":
            return "doc.text"
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "rb", "java", "kt", "c", "cpp", "h", "hpp", "sh", "css":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "xml", "toml":
            return "curlybraces"
        case "txt", "log":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "webp", "gif", "svg":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "html", "htm":
            return "globe"
        default:
            return "doc"
        }
    }
}
