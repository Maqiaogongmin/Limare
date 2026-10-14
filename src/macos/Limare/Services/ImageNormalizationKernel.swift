import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Consumer-domain definition; generic representation code treats this solely
/// as an opaque, versioned identity.
public enum ChatImageRepresentationProfile {
    public static let normalizedV1 = RepresentationProfileIdentity(
        namespace: "app.limare.chat-attachment",
        name: "normalized-chat-image",
        version: 1
    )
}

public struct ImageNormalizationProbe: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let hasAlpha: Bool
}

public struct NormalizedImageData: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let isPNG: Bool
}

/// Pure bounded image transformation helper. It owns neither storage nor
/// admission, and is shared by legacy callers and the representation converter.
public enum ImageNormalizationKernel {
    public static let maxDimension: CGFloat = 2048
    public static let jpegQuality: CGFloat = 0.85

    public static func probe(_ data: Data) throws -> ImageNormalizationProbe {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1
              ] as CFDictionary) else {
            throw AttachmentStoreError.invalidImageData
        }
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return ImageNormalizationProbe(
            width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? image.width,
            height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? image.height,
            hasAlpha: hasAlpha
        )
    }

    public static func normalize(_ data: Data) throws -> NormalizedImageData {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw AttachmentStoreError.invalidImageData
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let originalWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let originalHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let target = min(max(max(originalWidth, originalHeight), 1), maxDimension)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw AttachmentStoreError.invalidImageData
        }
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        let uti = (CGImageSourceGetType(imageSource) as String? ?? "").lowercased()
        let preservePNG = uti.contains("png") && hasAlpha
        let output = NSMutableData()
        let type = preservePNG ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else {
            throw AttachmentStoreError.invalidImageData
        }
        let encodeOptions: CFDictionary? = preservePNG ? nil : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, encodeOptions)
        guard CGImageDestinationFinalize(destination) else { throw AttachmentStoreError.invalidImageData }
        return NormalizedImageData(data: output as Data, mimeType: preservePNG ? "image/png" : "image/jpeg", width: image.width, height: image.height, isPNG: preservePNG)
    }
}

public struct ChatImageNormalizationConverter: RepresentationConverter {
    public let capability = ConverterCapability(
        id: "chat-image-normalization-v1",
        supportedRoutes: [
            ConversionRoute(sourceMIME: "image/jpeg", targetMIME: "image/jpeg"),
            ConversionRoute(sourceMIME: "image/png", targetMIME: "image/png"),
            ConversionRoute(sourceMIME: "image/png", targetMIME: "image/jpeg")
        ],
        maxInputBytes: AttachmentStore.maxSourceImageBytes
    )

    public init() {}

    public func applicableRoutes(source: ResourceResolvedContent, requirement: RepresentationRequirement) throws -> [ConversionRoute] {
        let mime = source.representation.mimeType.lowercased()
        // Applicability is a declared-MIME question first. A converter must never
        // probe or decode bytes for a source it does not claim: the generic
        // resolver fails the whole attempt when any converter's applicability
        // probe throws, so eager probing here would poison route selection for
        // every other format in the same composition. Semantic image behaviour is
        // unchanged — a real image source still probes for alpha as before.
        guard mime == "image/jpeg" || mime == "image/png" else { return [] }
        let probe = try ImageNormalizationKernel.probe(source.data)
        if mime == "image/jpeg" {
            return capability.supportedRoutes.filter { $0.sourceMIME == "image/jpeg" && $0.targetMIME == "image/jpeg" }
        }
        let target = probe.hasAlpha ? "image/png" : "image/jpeg"
        return capability.supportedRoutes.filter { $0.sourceMIME == "image/png" && $0.targetMIME == target }
    }

    public func convert(source: ResourceResolvedContent, route: ConversionRoute, budget: ConversionBudget) async throws -> ConversionOutput {
        try Task.checkCancellation()
        let normalized = try ImageNormalizationKernel.normalize(source.data)
        guard normalized.mimeType.caseInsensitiveCompare(route.targetMIME) == .orderedSame else {
            throw ConversionExecutionError(reason: "Normalization output does not match selected route.", cleanupStatus: .notRequired)
        }
        return ConversionOutput(
            data: normalized.data,
            representation: RepresentationDescriptor(mimeType: normalized.mimeType, epistemicLevel: .verified, establishedProfile: ChatImageRepresentationProfile.normalizedV1),
            filename: source.filename.map { (($0 as NSString).deletingPathExtension) + (normalized.isPNG ? ".png" : ".jpg") },
            cleanupStatus: .notRequired
        )
    }
}
