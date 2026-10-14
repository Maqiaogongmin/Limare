import Foundation
import PDFKit

/// Consumer/domain-owned representation profile for PDF text extraction v1.
///
/// The generic representation seam only compares this identity; no PDF-specific
/// knob is added to `RepresentationModels.swift`.
public enum PDFTextRepresentationProfile {
    public static let extractedV1 = RepresentationProfileIdentity(
        namespace: "limare.media.pdf",
        name: "extracted-text",
        version: 1
    )
}

/// Bounded conversion policy for the PDF text slice.
///
/// These are the single centralized numbers for this converter. They are
/// deliberately independent from the generic attachment admission cap: an
/// admission limit is not a conversion processing budget.
public enum PDFTextExtractionPolicy {
    /// Conservative bound on the PDF byte size this converter will parse.
    public static let maxInputBytes: Int64 = 32 * 1024 * 1024 // 32 MiB
    /// Bound on the extracted UTF-8 text. Enforced through the resolver's
    /// requirement budget so an oversized result is `overBudget` with zero
    /// artifact commit instead of a silently truncated "complete" extraction.
    public static let maxOutputBytes: Int64 = 128 * 1024 // 128 KiB
    /// Cooperative timeout handed to the resolver's conversion race.
    public static let timeoutSeconds: TimeInterval = 15
    /// Deterministic page boundary marker. Changing this marker is a v1 profile
    /// change and must be accompanied by a profile version bump.
    public static func pageMarker(_ pageNumber: Int) -> String { "[Page \(pageNumber)]" }
}

/// Real macOS PDFKit-backed `application/pdf → text/plain` converter.
///
/// Scope for R8-PDF1 is text only: no page rasterization, no OCR, no
/// embeddings, and no provider-native PDF dialect. Every failure is a typed
/// `ConversionExecutionError`, so an unreadable document can never produce an
/// artifact, and a scanned PDF truthfully reports that no text layer exists.
public struct PDFTextExtractionConverter: RepresentationConverter {
    public static let converterID = "limare.media.pdf.text-extraction.v1"
    public static let textRoute = ConversionRoute(
        sourceMIME: "application/pdf",
        targetMIME: "text/plain",
        priority: 10
    )

    public let capability: ConverterCapability

    public init() {
        self.capability = ConverterCapability(
            id: Self.converterID,
            supportedRoutes: [Self.textRoute],
            maxInputBytes: PDFTextExtractionPolicy.maxInputBytes
        )
    }

    /// Only the truthfully supported route is declared. PDF → PNG, PDF →
    /// Markdown, and PDF → JSON are not claimed.
    public func applicableRoutes(
        source: ResourceResolvedContent,
        requirement: RepresentationRequirement
    ) throws -> [ConversionRoute] {
        guard source.representation.mimeType.caseInsensitiveCompare("application/pdf") == .orderedSame,
              requirement.acceptsFormat(mimeType: Self.textRoute.targetMIME) else {
            return []
        }
        return [Self.textRoute]
    }

    public func convert(
        source: ResourceResolvedContent,
        route: ConversionRoute,
        budget: ConversionBudget
    ) async throws -> ConversionOutput {
        try Task.checkCancellation()

        guard let document = PDFDocument(data: source.data) else {
            throw ConversionExecutionError(
                reason: "PDF text extraction failed: the document is not a parseable PDF.",
                cleanupStatus: .notRequired
            )
        }
        guard !document.isLocked else {
            throw ConversionExecutionError(
                reason: "PDF text extraction failed: the document is encrypted or locked and cannot be read.",
                cleanupStatus: .notRequired
            )
        }

        var pages: [String] = []
        var foundExtractableText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let pageText = document.page(at: index)?.string ?? ""
            if !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                foundExtractableText = true
            }
            pages.append(pageText)
        }

        // Truthful reporting: an image-only (scanned) PDF has no extractable text
        // layer. OCR is deferred, and pretending otherwise would fabricate content.
        guard foundExtractableText else {
            throw ConversionExecutionError(
                reason: "PDF text extraction produced no extractable text: this document appears to be a scanned image. OCR is deferred.",
                cleanupStatus: .notRequired
            )
        }

        try Task.checkCancellation()

        let text = Self.render(pages: pages)
        let data = Data(text.utf8)
        let representation = RepresentationDescriptor(
            mimeType: Self.textRoute.targetMIME,
            family: .text,
            epistemicLevel: .verified,
            establishedProfile: PDFTextRepresentationProfile.extractedV1
        )
        try Task.checkCancellation()
        return ConversionOutput(
            data: data,
            representation: representation,
            filename: "extracted-text.txt",
            cleanupStatus: .notRequired
        )
    }

    /// Mechanical, deterministic rendering that preserves page boundaries.
    static func render(pages: [String]) -> String {
        pages.enumerated()
            .map { index, pageText in
                "\(PDFTextExtractionPolicy.pageMarker(index + 1))\n\(pageText)"
            }
            .joined(separator: "\n\n")
    }
}
