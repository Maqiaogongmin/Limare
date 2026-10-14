import Foundation
import AVFoundation
import AppKit

public enum VideoFrameSheetProfile {
    public static let frameSheetV1 = RepresentationProfileIdentity(
        namespace: "limare.media.video", name: "frame-sheet", version: 1
    )
}

/// Limare v0.1 product adaptation for short clips. All frame and image limits live here.
public enum VideoFrameSheetPolicy {
    public static let maxInputBytes: Int64 = 32 * 1024 * 1024
    public static let maxOutputBytes: Int64 = 8 * 1024 * 1024
    public static let timeoutSeconds: TimeInterval = 25
    public static let maxDurationSeconds: Double = 30
    public static let frameCount = 6
    public static let columns = 3
    public static let cellWidth = 320
    public static let imageHeight = 180
    public static let timecodeHeight = 32
    public static let stagingFilenamePrefix = "limare-video-frame-sheet-"

    public static func sampleSeconds(duration: Double) throws -> [Double] {
        guard duration.isFinite, duration > 0, duration <= maxDurationSeconds else {
            throw ConversionExecutionError(reason: "Frame sheet requires a finite positive video duration no longer than 30 seconds.")
        }
        return (0..<frameCount).map { duration * (Double($0) + 0.5) / Double(frameCount) }
    }

    public static func timecode(seconds: Double) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        let minutes = milliseconds / 60_000
        let remainder = milliseconds % 60_000
        return String(format: "%02d:%02d.%03d", minutes, remainder / 1_000, remainder % 1_000)
    }
}

public struct VideoFrameSheetConverter: RepresentationConverter {
    public static let converterID = "limare.media.video.frame-sheet.v1"
    public static let supportedRoutes = [
        ConversionRoute(sourceMIME: "video/mp4", targetMIME: "image/png", priority: 10),
        ConversionRoute(sourceMIME: "video/quicktime", targetMIME: "image/png", priority: 10),
    ]

    public let capability: ConverterCapability
    private let stagingDirectory: URL
    /// Test seam for deterministic cancellation and partial-extraction failures.
    /// Production construction does not supply it.
    private let sampleBoundary: (@Sendable (Int) async throws -> Void)?

    public init(stagingDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        self.init(stagingDirectory: stagingDirectory, sampleBoundary: nil)
    }

    init(stagingDirectory: URL, sampleBoundary: (@Sendable (Int) async throws -> Void)?) {
        capability = ConverterCapability(
            id: Self.converterID,
            supportedRoutes: Self.supportedRoutes,
            maxInputBytes: VideoFrameSheetPolicy.maxInputBytes
        )
        self.stagingDirectory = stagingDirectory
        self.sampleBoundary = sampleBoundary
    }

    public func applicableRoutes(source: ResourceResolvedContent, requirement: RepresentationRequirement) throws -> [ConversionRoute] {
        guard requirement.acceptsFormat(mimeType: "image/png") else { return [] }
        return Self.supportedRoutes.filter { $0.sourceMIME == source.representation.mimeType.lowercased() }
    }

    public func convert(source: ResourceResolvedContent, route: ConversionRoute, budget: ConversionBudget) async throws -> ConversionOutput {
        try Task.checkCancellation()
        let mime = source.representation.mimeType.lowercased()
        guard Self.supportedRoutes.contains(route), route.sourceMIME == mime else {
            throw ConversionExecutionError(reason: "Frame sheet source route is unsupported.", cleanupStatus: .notRequired)
        }
        let suffix = mime == "video/mp4" ? "mp4" : "mov"
        let stagingURL = stagingDirectory.appendingPathComponent("\(VideoFrameSheetPolicy.stagingFilenamePrefix)\(UUID().uuidString).\(suffix)")

        func cleanup() -> RepresentationCleanupStatus {
            guard FileManager.default.fileExists(atPath: stagingURL.path) else { return .completed }
            do {
                try FileManager.default.removeItem(at: stagingURL)
                return .completed
            } catch { return .failed }
        }

        do {
            try Task.checkCancellation()
            try source.data.write(to: stagingURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagingURL.path)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: stagingURL)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw ConversionExecutionError(reason: "Frame sheet requires a video track.")
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let display = naturalSize.applying(transform)
            _ = try VideoMetadataConverter.checkedDimension(display.width)
            _ = try VideoMetadataConverter.checkedDimension(display.height)
            guard duration.isValid, !duration.isIndefinite else {
                throw ConversionExecutionError(reason: "Frame sheet requires a valid duration.")
            }
            let times = try VideoFrameSheetPolicy.sampleSeconds(duration: CMTimeGetSeconds(duration))
            try Task.checkCancellation()
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var frames: [CGImage] = []
            for seconds in times {
                try Task.checkCancellation()
                try await sampleBoundary?(frames.count)
                try Task.checkCancellation()
                let time = CMTime(seconds: seconds, preferredTimescale: 600_000)
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                frames.append(image)
            }
            try Task.checkCancellation()
            let data = try Self.render(frames: frames, times: times)
            try Task.checkCancellation()
            let cleanupStatus = cleanup()
            guard cleanupStatus == .completed else {
                throw ConversionExecutionError(reason: "Frame sheet staging cleanup failed.", cleanupStatus: .failed)
            }
            try Task.checkCancellation()
            return ConversionOutput(
                data: data,
                representation: RepresentationDescriptor(
                    mimeType: "image/png", family: .image, epistemicLevel: .verified,
                    establishedProfile: VideoFrameSheetProfile.frameSheetV1
                ),
                filename: "video-frame-sheet.png",
                cleanupStatus: cleanupStatus
            )
        } catch is CancellationError {
            let status = cleanup()
            if status == .failed {
                throw ConversionExecutionError(reason: "Frame sheet cancellation staging cleanup failed.", cleanupStatus: .failed)
            }
            throw CancellationError()
        } catch let error as ConversionExecutionError {
            let status = cleanup()
            throw ConversionExecutionError(reason: error.reason, cleanupStatus: status == .failed ? .failed : status)
        } catch {
            let status = cleanup()
            throw ConversionExecutionError(reason: "Frame sheet extraction failed: \(error.localizedDescription)", cleanupStatus: status)
        }
    }

    private static func render(frames: [CGImage], times: [Double]) throws -> Data {
        guard frames.count == VideoFrameSheetPolicy.frameCount, times.count == frames.count else {
            throw ConversionExecutionError(reason: "Frame sheet extraction was incomplete.")
        }
        let policy = VideoFrameSheetPolicy.self
        let cellHeight = policy.imageHeight + policy.timecodeHeight
        let width = policy.columns * policy.cellWidth
        let rows = (policy.frameCount + policy.columns - 1) / policy.columns
        let height = rows * cellHeight
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ConversionExecutionError(reason: "Frame sheet canvas creation failed.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (index, frame) in frames.enumerated() {
            let x = (index % policy.columns) * policy.cellWidth
            let y = height - (index / policy.columns + 1) * cellHeight
            let frameWidth = CGFloat(frame.width)
            let frameHeight = CGFloat(frame.height)
            guard frameWidth > 0, frameHeight > 0 else {
                throw ConversionExecutionError(reason: "Frame sheet received an empty frame.")
            }
            let scale = min(CGFloat(policy.cellWidth) / frameWidth, CGFloat(policy.imageHeight) / frameHeight)
            let drawWidth = frameWidth * scale
            let drawHeight = frameHeight * scale
            NSImage(cgImage: frame, size: NSSize(width: frameWidth, height: frameHeight)).draw(
                in: NSRect(x: CGFloat(x) + (CGFloat(policy.cellWidth) - drawWidth) / 2,
                           y: CGFloat(y + policy.timecodeHeight) + (CGFloat(policy.imageHeight) - drawHeight) / 2,
                           width: drawWidth, height: drawHeight)
            )
            let label = "\(index + 1)  \(policy.timecode(seconds: times[index]))" as NSString
            label.draw(at: NSPoint(x: x + 12, y: y + 7), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }
        context.flushGraphics()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ConversionExecutionError(reason: "Frame sheet PNG encoding failed.")
        }
        return png
    }
}
