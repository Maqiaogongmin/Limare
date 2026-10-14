import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

/// Consumer/domain-owned representation profile for video metadata v1.
///
/// The generic representation seam only compares this identity; no video-specific
/// knob is added to `RepresentationModels.swift`.
public enum VideoMetadataRepresentationProfile {
    public static let metadataV1 = RepresentationProfileIdentity(
        namespace: "limare.media.video",
        name: "metadata",
        version: 1
    )
}

/// Bounded conversion policy for the video metadata slice.
///
/// These are the single centralized numbers for this converter. They are
/// deliberately independent from the generic attachment admission cap: an
/// admission limit is not a conversion processing budget.
public enum VideoMetadataExtractionPolicy {
    /// Conservative bound on the video byte size this converter will stage.
    public static let maxInputBytes: Int64 = 64 * 1024 * 1024 // 64 MiB
    /// Bound on the derived metadata JSON. Enforced through the resolver's
    /// requirement budget so an oversized result is `overBudget` with zero
    /// artifact commit instead of a silently truncated "complete" extraction.
    public static let maxOutputBytes: Int64 = 16 * 1024 // 16 KiB
    /// Cooperative timeout handed to the resolver's conversion race.
    public static let timeoutSeconds: TimeInterval = 10
    /// Metadata schema version emitted by this profile. Changing the emitted key
    /// set is a v1 profile change and must be accompanied by a profile version bump.
    public static let schemaVersion = 1
    /// Stable prefix for the converter-owned ephemeral AVFoundation staging file.
    public static let stagingFilenamePrefix = "limare-video-metadata-"

    /// Only the declared source MIME decides the staging suffix, never the
    /// original filename extension.
    public static func stagingExtension(forSourceMIME sourceMIME: String) -> String? {
        switch sourceMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }
}

/// Mechanical, consumer-owned result of probing a bounded video snapshot.
///
/// This carries no path, no filename and no attachment identity: it is exactly
/// the bounded metadata fact the v1 profile establishes.
public struct VideoMetadataSnapshot: Sendable, Equatable {
    public let schemaVersion: Int
    public let durationMilliseconds: Int
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let width: Int
    public let height: Int

    public var hasAudio: Bool { audioTrackCount > 0 }

    public init(
        schemaVersion: Int,
        durationMilliseconds: Int,
        videoTrackCount: Int,
        audioTrackCount: Int,
        width: Int,
        height: Int
    ) {
        self.schemaVersion = schemaVersion
        self.durationMilliseconds = durationMilliseconds
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.width = width
        self.height = height
    }
}

/// Real AVFoundation-backed `video/mp4 | video/quicktime → application/json`
/// converter.
///
/// Scope is mechanical metadata only: no frame extraction, no thumbnails, no
/// contact sheets, no audio extraction, no transcription and no provider-native
/// video dialect. AVFoundation's normal read path is URL-backed, so the already
/// admitted and bounded snapshot bytes are written to a converter-owned
/// ephemeral staging file for the duration of one attempt. That file is
/// execution scratch: it is not an Artifact, it is not an Attachment, it is not
/// a shadow copy of the source, and it never transfers source authority.
public struct VideoMetadataConverter: RepresentationConverter {
    public static let converterID = "limare.media.video.metadata.v1"
    public static let jsonMIME = "application/json"
    public static let mp4Route = ConversionRoute(
        sourceMIME: "video/mp4",
        targetMIME: jsonMIME,
        priority: 10
    )
    public static let quickTimeRoute = ConversionRoute(
        sourceMIME: "video/quicktime",
        targetMIME: jsonMIME,
        priority: 10
    )
    public static let supportedRoutes = [mp4Route, quickTimeRoute]

    /// The exact v1 schema key set. Adding or removing a key is a profile change
    /// and must be accompanied by a profile version bump. The source MIME is
    /// deliberately absent: it already lives in the ResourceRef, the selected
    /// route and the conversion provenance, and is not part of this profile.
    public static let metadataV1Keys: Set<String> = [
        "schema_version",
        "duration_ms",
        "video_track_count",
        "audio_track_count",
        "width",
        "height",
        "has_audio",
    ]

    public let capability: ConverterCapability
    /// Converter-owned execution scratch directory. Production uses the system
    /// temporary directory; it is never a durable store.
    private let stagingDirectory: URL

    public init(stagingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        self.capability = ConverterCapability(
            id: Self.converterID,
            supportedRoutes: Self.supportedRoutes,
            maxInputBytes: VideoMetadataExtractionPolicy.maxInputBytes
        )
        self.stagingDirectory = stagingDirectory
    }

    public static func route(forSourceMIME sourceMIME: String) -> ConversionRoute? {
        switch sourceMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video/mp4": return mp4Route
        case "video/quicktime": return quickTimeRoute
        default: return nil
        }
    }

    /// Only the truthfully supported routes are declared. Frame, audio and
    /// plain-text targets are not claimed.
    public func applicableRoutes(
        source: ResourceResolvedContent,
        requirement: RepresentationRequirement
    ) throws -> [ConversionRoute] {
        guard requirement.acceptsFormat(mimeType: Self.jsonMIME),
              let route = Self.route(forSourceMIME: source.representation.mimeType) else {
            return []
        }
        return [route]
    }

    public func convert(
        source: ResourceResolvedContent,
        route: ConversionRoute,
        budget: ConversionBudget
    ) async throws -> ConversionOutput {
        try Task.checkCancellation()

        let sourceMIME = source.representation.mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let declaredRoute = Self.route(forSourceMIME: sourceMIME), declaredRoute == route else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: '\(sourceMIME)' is not a declared video route.",
                cleanupStatus: .notRequired
            )
        }
        guard let stagingExtension = VideoMetadataExtractionPolicy.stagingExtension(forSourceMIME: sourceMIME) else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: no staging suffix for '\(sourceMIME)'.",
                cleanupStatus: .notRequired
            )
        }

        let stagingURL = stagingDirectory.appendingPathComponent(
            "\(VideoMetadataExtractionPolicy.stagingFilenamePrefix)\(UUID().uuidString).\(stagingExtension)"
        )
        var stagingCleaned = false

        /// Cleanup truth: a staged file either no longer exists or was removed.
        /// A failed removal is reported as `failed`, never as `completed`.
        func cleanUpStaging() -> RepresentationCleanupStatus {
            if stagingCleaned { return .completed }
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                do {
                    try FileManager.default.removeItem(at: stagingURL)
                } catch {
                    return .failed
                }
            }
            stagingCleaned = true
            return .completed
        }

        // Bounded exact snapshot bytes are written to the ephemeral staging file
        // so AVFoundation can read them by URL. The converter never reaches for
        // a durable authority and never re-reads the original source file.
        do {
            try Task.checkCancellation()
            try source.data.write(to: stagingURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
        } catch is CancellationError {
            _ = cleanUpStaging()
            throw CancellationError()
        } catch {
            let cleanup = cleanUpStaging()
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: could not stage the admitted snapshot (\(error.localizedDescription)).",
                cleanupStatus: cleanup
            )
        }

        do {
            try Task.checkCancellation()

            let asset = AVURLAsset(url: stagingURL)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()

            guard let videoTrack = videoTracks.first else {
                throw ConversionExecutionError(
                    reason: "Video metadata extraction failed: the asset parses but declares no video track.",
                    cleanupStatus: .pending
                )
            }
            let (naturalSize, preferredTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            try Task.checkCancellation()

            let snapshot = try Self.makeSnapshot(
                duration: duration,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform
            )

            // Deterministic UTF-8 JSON with stable key ordering: the same input
            // must produce the same bytes.
            let data = try Self.encode(snapshot)

            let cleanup = cleanUpStaging()
            guard cleanup == .completed else {
                throw ConversionExecutionError(
                    reason: "Video metadata extraction failed: the ephemeral staging file could not be removed.",
                    cleanupStatus: .failed
                )
            }

            let representation = RepresentationDescriptor(
                mimeType: Self.jsonMIME,
                family: .text,
                epistemicLevel: .verified,
                establishedProfile: VideoMetadataRepresentationProfile.metadataV1
            )
            try Task.checkCancellation()
            return ConversionOutput(
                data: data,
                representation: representation,
                filename: "video-metadata.json",
                cleanupStatus: cleanup
            )
        } catch is CancellationError {
            _ = cleanUpStaging()
            throw CancellationError()
        } catch let error as ConversionExecutionError {
            let cleanup = error.cleanupStatus == .failed ? .failed : cleanUpStaging()
            throw ConversionExecutionError(reason: error.reason, cleanupStatus: cleanup)
        } catch {
            let cleanup = cleanUpStaging()
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: \(error.localizedDescription)",
                cleanupStatus: cleanup
            )
        }
    }

    /// Mechanically builds the v1 metadata fact from AVFoundation truth.
    ///
    /// Every float-to-integer conversion is range-checked before it happens, so
    /// pathologically large or non-finite AVFoundation values become a truthful
    /// typed failure instead of a Swift fatal trap. `duration` is validated
    /// rather than coerced, and an asset that parses without a video track is
    /// never reported as successful video metadata.
    public static func makeSnapshot(
        duration: CMTime,
        videoTrackCount: Int,
        audioTrackCount: Int,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) throws -> VideoMetadataSnapshot {
        guard duration.isValid, !duration.isIndefinite else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: the asset declares no valid finite duration.",
                cleanupStatus: .pending
            )
        }
        let durationMilliseconds = try checkedMilliseconds(fromSeconds: CMTimeGetSeconds(duration))
        guard videoTrackCount > 0 else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: video_track_count is 0, which is not a video metadata artifact.",
                cleanupStatus: .pending
            )
        }
        // Display orientation, not raw encoded size: a portrait video must not be
        // reported as landscape.
        let displaySize = naturalSize.applying(preferredTransform)
        let width = try checkedDimension(displaySize.width)
        let height = try checkedDimension(displaySize.height)

        return VideoMetadataSnapshot(
            schemaVersion: VideoMetadataExtractionPolicy.schemaVersion,
            durationMilliseconds: durationMilliseconds,
            videoTrackCount: videoTrackCount,
            audioTrackCount: audioTrackCount,
            width: width,
            height: height
        )
    }

    /// Converts AVFoundation seconds to integer milliseconds without ever
    /// trapping. A non-finite, negative or out-of-range magnitude is a truthful
    /// failure: the value is rejected before any `Int` conversion can trap.
    ///
    /// The upper bound is `Double(Int.max)` — every integral `Double` strictly
    /// below it is exactly representable as `Int`, so the check is conservative
    /// in the safe direction.
    static func checkedMilliseconds(fromSeconds seconds: Double) throws -> Int {
        guard seconds.isFinite else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: the duration in seconds is not finite.",
                cleanupStatus: .pending
            )
        }
        guard seconds >= 0 else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: the duration in seconds is negative.",
                cleanupStatus: .pending
            )
        }
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int.max) else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: the duration in milliseconds is not representable as an integer.",
                cleanupStatus: .pending
            )
        }
        return Int(milliseconds)
    }

    /// Converts a display dimension to a positive integer pixel count without
    /// ever trapping. Non-finite, non-positive and out-of-range magnitudes are
    /// truthful failures.
    static func checkedDimension(_ value: CGFloat) throws -> Int {
        let magnitude = value.magnitude
        guard magnitude.isFinite else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: a display dimension is not finite.",
                cleanupStatus: .pending
            )
        }
        let rounded = magnitude.rounded()
        guard rounded.isFinite, rounded >= 1, rounded < CGFloat(Int.max) else {
            throw ConversionExecutionError(
                reason: "Video metadata extraction failed: a display dimension is not a positive representable integer.",
                cleanupStatus: .pending
            )
        }
        return Int(rounded)
    }

    /// Deterministic UTF-8 `application/json` encoding with stable key ordering.
    public static func encode(_ snapshot: VideoMetadataSnapshot) throws -> Data {
        let object: [String: Any] = [
            "schema_version": snapshot.schemaVersion,
            "duration_ms": snapshot.durationMilliseconds,
            "video_track_count": snapshot.videoTrackCount,
            "audio_track_count": snapshot.audioTrackCount,
            "width": snapshot.width,
            "height": snapshot.height,
            "has_audio": snapshot.hasAudio,
        ]
        // Mechanical self-check: the emitted document is exactly the v1 profile or
        // it is not a v1 artifact at all.
        guard Set(object.keys) == metadataV1Keys else {
            throw ConversionExecutionError(
                reason: "Video metadata encoding failed: the emitted key set does not match the video metadata v1 schema.",
                cleanupStatus: .pending
            )
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
