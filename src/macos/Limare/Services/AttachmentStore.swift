import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

public enum AttachmentStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidImageData
    case fileNotFound(String)
    case pathTraversalDetected(String)
    case storageUnavailable(String)
    case fileTooLarge(Int64, maxBytes: Int64)
    case maxPendingAttachmentsExceeded(Int)
    case totalSizeExceeded(Int64, maxBytes: Int64)
    case unsupportedSource(String)

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Unable to decode or normalize image data."
        case .fileNotFound(let path):
            return "Attachment file not found: \(path)"
        case .pathTraversalDetected(let path):
            return "Invalid attachment path detected: \(path)"
        case .storageUnavailable(let message):
            return "Attachment storage unavailable: \(message)"
        case .fileTooLarge(let size, let maxBytes):
            let sizeMB = Double(size) / 1_048_576.0
            let maxMB = Double(maxBytes) / 1_048_576.0
            return String(format: "Attachment is too large (%.1f MB). Maximum allowed size is %.0f MB.", sizeMB, maxMB)
        case .maxPendingAttachmentsExceeded(let max):
            return "Maximum \(max) attachments allowed per message."
        case .totalSizeExceeded(let size, let maxBytes):
            return String(format: "Attachments total %.1f MB exceeds the %.0f MB per-message limit.", Double(size) / 1_048_576, Double(maxBytes) / 1_048_576)
        case .unsupportedSource(let message):
            return message
        }
    }
}

public final class AttachmentStore: @unchecked Sendable {
    public let storageRootURL: URL
    private let attachmentsDirectoryURL: URL
    private let lock = NSLock()
    private var knownAttachments: [String: ChatAttachment] = [:]

    public static let maxImageDimension: CGFloat = ImageNormalizationKernel.maxDimension
    public static let jpegCompressionQuality: CGFloat = ImageNormalizationKernel.jpegQuality
    public static let maxPendingAttachments: Int = 8
    public static let maxSourceImageBytes: Int64 = 25 * 1024 * 1024 // 25 MB
    public static let maxGenericFileBytes: Int64 = 250 * 1024 * 1024 // 250 MB
    public static let maxAttachmentsPerMessageBytes: Int64 = 500 * 1024 * 1024 // 500 MB
    public static let maxGeneratedImageBytes: Int64 = 50 * 1024 * 1024 // 50 MB

    public init(
        storageRootURL: URL? = nil
    ) {
        let fileManager = FileManager.default
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        self.storageRootURL = root
        let attachDir = root.appendingPathComponent("attachments", isDirectory: true)
        self.attachmentsDirectoryURL = attachDir

        try? fileManager.createDirectory(
            at: attachDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Save and Normalize Image

    /// Normalizes and stores an image from in-memory Data.
    public func saveImage(
        data: Data,
        originalFilename: String? = nil
    ) throws -> ChatAttachment {
        if Int64(data.count) > Self.maxSourceImageBytes {
            throw AttachmentStoreError.fileTooLarge(Int64(data.count), maxBytes: Self.maxSourceImageBytes)
        }
        let normalized = try ImageNormalizationKernel.normalize(data)
        let normalizedData = normalized.data
        let mimeType = normalized.mimeType
        let width = normalized.width
        let height = normalized.height
        let isPNG = normalized.isPNG
        let attachmentID = UUID()
        let ext = isPNG ? "png" : "jpg"
        let filename = "\(attachmentID.uuidString).\(ext)"
        let relativePath = "attachments/\(filename)"
        let fileURL = attachmentsDirectoryURL.appendingPathComponent(filename)

        try normalizedData.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let displayName = originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? originalFilename!
            : "Image.\(ext)"

        let attachment = ChatAttachment(
            id: attachmentID,
            kind: .image,
            filename: displayName,
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: normalizedData.count,
            width: width,
            height: height,
            representationProfile: ChatImageRepresentationProfile.normalizedV1
        )
        register(attachment)
        return attachment
    }

    /// Commits an already-normalized transient representation. The resolver has
    /// no attachment authority; this is the only point that assigns identity,
    /// filename, permissions, and registry state.
    public func commitNormalizedImage(_ result: DirectUseConversionResult, originalFilename: String?) throws -> ChatAttachment {
        guard result.representation.establishedProfile == ChatImageRepresentationProfile.normalizedV1 else {
            throw AttachmentStoreError.invalidImageData
        }
        guard Int64(result.data.count) <= Self.maxSourceImageBytes else {
            throw AttachmentStoreError.fileTooLarge(Int64(result.data.count), maxBytes: Self.maxSourceImageBytes)
        }
        let probe = try ImageNormalizationKernel.probe(result.data)
        let id = UUID()
        let isPNG = result.representation.mimeType == "image/png"
        let ext = isPNG ? "png" : "jpg"
        let diskName = "\(id.uuidString).\(ext)"
        let fileURL = attachmentsDirectoryURL.appendingPathComponent(diskName)
        try result.data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let displayName = originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? originalFilename! : "Image.\(ext)"
        let attachment = ChatAttachment(id: id, kind: .image, filename: displayName, relativePath: "attachments/\(diskName)", mimeType: result.representation.mimeType, byteCount: result.data.count, width: probe.width, height: probe.height, representationProfile: result.representation.establishedProfile)
        register(attachment)
        return attachment
    }

    /// Reads, normalizes, and stores an image from a file URL.
    public func saveImage(url: URL) throws -> ChatAttachment {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attrs?[.size] as? NSNumber)?.int64Value, size > Self.maxSourceImageBytes {
            throw AttachmentStoreError.fileTooLarge(size, maxBytes: Self.maxSourceImageBytes)
        }
        let data = try Data(contentsOf: url)
        return try saveImage(data: data, originalFilename: url.lastPathComponent)
    }

    /// Imports a user-selected regular file. Images retain the normalization path;
    /// all other files are copied without loading their complete contents into memory.
    public func saveFile(url: URL) throws -> ChatAttachment {
        let source = url.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isDirectory != true, values.isPackage != true else {
            throw AttachmentStoreError.unsupportedSource("Folders are not supported as chat attachments yet.")
        }
        let classification = AttachmentClassifier.classify(url: source)
        if classification.kind == .image { return try saveImage(url: source) }
        let size = Int64(values.fileSize ?? 0)
        guard size <= Self.maxGenericFileBytes else {
            throw AttachmentStoreError.fileTooLarge(size, maxBytes: Self.maxGenericFileBytes)
        }
        let id = UUID()
        let ext = source.pathExtension
        let diskName = id.uuidString + (ext.isEmpty ? "" : ".\(ext.lowercased())")
        let destination = attachmentsDirectoryURL.appendingPathComponent(diskName)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let attachment = ChatAttachment(
            id: id,
            kind: classification.kind,
            filename: source.lastPathComponent,
            relativePath: "attachments/\(diskName)",
            mimeType: classification.mimeType,
            byteCount: Int(size),
            contentTypeIdentifier: classification.contentTypeIdentifier
        )
        register(attachment)
        return attachment
    }

    /// Stores a model-generated image preserving exact bytes, format, and alpha.
    public func saveGeneratedImage(
        data: Data,
        mimeType: String? = nil,
        suggestedFilename: String? = nil
    ) throws -> ChatAttachment {
        if Int64(data.count) > Self.maxGeneratedImageBytes {
            throw AttachmentStoreError.fileTooLarge(Int64(data.count), maxBytes: Self.maxGeneratedImageBytes)
        }
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw AttachmentStoreError.invalidImageData
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue

        guard let rawUTI = CGImageSourceGetType(imageSource) as String? else {
            throw AttachmentStoreError.invalidImageData
        }
        let uti = rawUTI.lowercased()

        let resolvedMime: String
        let ext: String
        if uti.contains("png") || uti == "public.png" {
            resolvedMime = "image/png"
            ext = "png"
        } else if uti.contains("jpeg") || uti.contains("jpg") || uti == "public.jpeg" {
            resolvedMime = "image/jpeg"
            ext = "jpg"
        } else if uti.contains("webp") || uti == "org.webmproject.webp" {
            resolvedMime = "image/webp"
            ext = "webp"
        } else {
            throw AttachmentStoreError.invalidImageData
        }

        let attachmentID = UUID()
        let diskFilename = "\(attachmentID.uuidString).\(ext)"
        let relativePath = "attachments/\(diskFilename)"
        let fileURL = attachmentsDirectoryURL.appendingPathComponent(diskFilename)

        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let displayName: String
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines), !suggested.isEmpty {
            let base = (suggested as NSString).deletingPathExtension
            displayName = base.isEmpty ? "Generated Image.\(ext)" : "\(base).\(ext)"
        } else {
            displayName = "Generated Image.\(ext)"
        }

        let attachment = ChatAttachment(
            id: attachmentID,
            kind: .image,
            filename: displayName,
            relativePath: relativePath,
            mimeType: resolvedMime,
            byteCount: data.count,
            width: width,
            height: height
        )
        register(attachment)
        return attachment
    }

    // MARK: - Load and Resolve File

    public func fileURL(for attachment: ChatAttachment) throws -> URL {
        let rel = attachment.relativePath
        guard !rel.contains(".."), !rel.hasPrefix("/") else {
            throw AttachmentStoreError.pathTraversalDetected(rel)
        }
        let root = attachmentsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = storageRootURL.appendingPathComponent(rel).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw AttachmentStoreError.pathTraversalDetected(rel)
        }
        return resolved
    }

    public func fileURL(forAttachmentURI uri: String) throws -> URL {
        let prefix = "limare://attachments/"
        guard uri.hasPrefix(prefix) else { throw AttachmentStoreError.pathTraversalDetected(uri) }
        let diskName = String(uri.dropFirst(prefix.count))
        guard !diskName.isEmpty, diskName == (diskName as NSString).lastPathComponent,
              !diskName.contains(".."), !diskName.hasPrefix("/") else {
            throw AttachmentStoreError.pathTraversalDetected(uri)
        }
        let synthetic = ChatAttachment(filename: diskName, relativePath: "attachments/\(diskName)", mimeType: "application/octet-stream", byteCount: 0)
        return try fileURL(for: synthetic)
    }

    public func loadData(for attachment: ChatAttachment) throws -> Data {
        let url = try fileURL(for: attachment)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AttachmentStoreError.fileNotFound(attachment.relativePath)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - In-Memory Attachment Registry

    private func register(_ attachment: ChatAttachment) {
        lock.lock()
        defer { lock.unlock() }
        let key = (attachment.relativePath as NSString).lastPathComponent
        knownAttachments[key] = attachment
    }

    public func registerAttachment(_ attachment: ChatAttachment) {
        register(attachment)
    }

    public func attachment(forURI uri: String) -> ChatAttachment? {
        let prefix = "limare://attachments/"
        guard uri.hasPrefix(prefix) else { return nil }
        let diskName = String(uri.dropFirst(prefix.count))
        lock.lock()
        defer { lock.unlock() }
        return knownAttachments[diskName]
    }

    public func originalFilename(forURI uri: String) -> String? {
        attachment(forURI: uri)?.filename
    }

    public func deleteAttachment(_ attachment: ChatAttachment) {
        lock.lock()
        let key = (attachment.relativePath as NSString).lastPathComponent
        knownAttachments.removeValue(forKey: key)
        lock.unlock()
        if let url = try? fileURL(for: attachment) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Normalization Pipeline

    public func normalizeImageData(_ data: Data) throws -> (data: Data, mimeType: String, width: Int, height: Int, isPNG: Bool) {
        let normalized = try ImageNormalizationKernel.normalize(data)
        return (normalized.data, normalized.mimeType, normalized.width, normalized.height, normalized.isPNG)
    }
}
