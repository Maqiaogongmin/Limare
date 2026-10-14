import Foundation

public enum AttachmentReferenceFormatter {
    public enum InspectionCapability: Sendable {
        case nativeImageInput
        case readImage
        case unavailableImageInspection
        case availableTool
        case directFileRead
        case representationConversion
    }

    public static func uri(for attachment: ChatAttachment) -> String {
        "limare://attachments/\((attachment.relativePath as NSString).lastPathComponent)"
    }

    public static func reference(
        for attachment: ChatAttachment,
        inspection: InspectionCapability? = nil,
        isAvailable: Bool = true
    ) -> String {
        let path = uri(for: attachment)
        guard isAvailable else {
            return "[attachment_missing]\nName: \(attachment.filename)\nPath: \(path)"
        }
        let resolvedInspection = inspection ?? {
            switch attachment.kind {
            case .image:
                return .readImage
            case .pdf:
                return .representationConversion
            case .video:
                return .representationConversion
            case .text:
                return .directFileRead
            default:
                return .availableTool
            }
        }()
        let inspectionText: String
        switch resolvedInspection {
        case .nativeImageInput:
            inspectionText = "Native image input is included with this attachment."
        case .readImage:
            inspectionText = "Use read_image to inspect this attachment; call the read_image tool when needed."
        case .unavailableImageInspection:
            inspectionText = "This image is attached locally, but this request has no capability for reading its contents."
        case .directFileRead:
            inspectionText = "Use file_read to read this text attachment directly. If Shell or other tools are needed, use attachment_copy to copy it to the working directory."
        case .representationConversion:
            inspectionText = Self.representationConversionGuidance(for: attachment)
        case .availableTool:
            inspectionText = "If you need to inspect or process this file with Shell or other tools, first copy it to the working directory using attachment_copy."
        }
        return """
        [Attached file]
        Name: \(attachment.filename)
        Kind: \(attachment.kind.rawValue)
        MIME: \(attachment.mimeType)
        Size: \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
        Path: \(path)
        Inspection: \(inspectionText)

        This file is stored locally by the Harness.
        """
    }

    /// Kind-specific conversion guidance. Video offers bounded metadata and a
    /// visual frame-sheet representation while leaving audio uninspected.
    static func representationConversionGuidance(for attachment: ChatAttachment) -> String {
        switch attachment.kind {
        case .pdf:
            return "Use resource_convert to obtain a text representation when PDF content is needed."
        case .video:
            return "resource_convert can obtain bounded mechanical metadata with target_mime = \"application/json\" or a bounded representative-frame sheet with visible timecodes using target_mime = \"image/png\". The sheet is a visual representation; audio is not inspected, and the full video has not been natively viewed by the model."
        default:
            return "Use resource_convert to obtain another representation of this attachment when needed."
        }
    }

    public static func unsupportedInspection(for attachment: ChatAttachment) -> String {
        let guidance: String
        switch attachment.kind {
        case .pdf:
            guidance = "Use resource_convert with this attachment path as the source and target_mime \"text/plain\" to obtain its text representation."
        case .video:
            guidance = "resource_convert can obtain bounded mechanical metadata with target_mime = \"application/json\" or a bounded representative-frame sheet with visible timecodes using target_mime = \"image/png\". The sheet is a visual representation; audio is not inspected, and the full video has not been natively viewed by the model."
        default:
            guidance = "If you need to inspect or process this file with Shell or other tools, first copy it to the working directory using attachment_copy."
        }
        return """
        This file is attached and stored locally, but Limare does not currently have a processor for reading this file type.
        Name: \(attachment.filename)
        Kind: \(attachment.kind.rawValue)
        MIME: \(attachment.mimeType)
        Size: \(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
        Path: \(uri(for: attachment))
        Content status: Not inspected
        \(guidance)
        """
    }
}
