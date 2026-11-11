import Foundation
import CryptoKit

/// Screenshot transport validation and ingestion into the artifact store.
///
/// Responsibilities:
/// 1. Untrusted screenshot payload validation enforcing AC-C12 strict ordering:
///    - Read transport metadata
///    - Validate correlation against production request (invocationID, verificationRunID, captureID, taskID, runID, requirementID, captureTestIdentity)
///    - Validate path containment (inside invocation temp root, regular file, no symlink escape)
///    - Read screenshot bytes and validate digest (SHA-256) and size bounds (<= 25MB)
///    - ONLY THEN call ArtifactStore.save(..., retentionClass: .temporaryExtraction)
/// 2. Failure screenshot policy: ordinary/failure screenshots remain `.temporaryExtraction` (never blanket-pinned).
public final class MacOSGUIScreenshotEvidenceAdapter: @unchecked Sendable {
    public static let shared = MacOSGUIScreenshotEvidenceAdapter()

    public init() {}

    // MARK: - Transport Metadata Model

    public struct ScreenshotTransportMetadata: Codable, Sendable, Equatable {
        public let invocationID: String
        public let verificationRunID: String
        public let captureID: String
        public let taskID: String
        public let runID: String
        public let requirementID: String
        public let captureTestIdentity: String
        public let mimeType: String
        public let byteCount: Int64
        public let sha256: String
        public let timestamp: Double

        public init(
            invocationID: String,
            verificationRunID: String,
            captureID: String,
            taskID: String,
            runID: String,
            requirementID: String,
            captureTestIdentity: String,
            mimeType: String = "image/png",
            byteCount: Int64,
            sha256: String,
            timestamp: Double = Date().timeIntervalSince1970
        ) {
            self.invocationID = invocationID
            self.verificationRunID = verificationRunID
            self.captureID = captureID
            self.taskID = taskID
            self.runID = runID
            self.requirementID = requirementID
            self.captureTestIdentity = captureTestIdentity
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.sha256 = sha256
            self.timestamp = timestamp
        }
    }

    // MARK: - Ingestion Outcome

    public enum IngestionOutcome: Sendable {
        case success(descriptor: ArtifactDescriptor, artifactRef: ArtifactRef)
        case rejected(reason: String)
        case failed(reason: String)

        public var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        public var descriptor: ArtifactDescriptor? {
            if case .success(let d, _) = self { return d }
            return nil
        }

        public var artifactRef: ArtifactRef? {
            if case .success(_, let r) = self { return r }
            return nil
        }
    }

    // MARK: - AC-C12 Transport Validation & Materialization

    /// Ingests an untrusted screenshot from an invocation transport directory into the canonical ArtifactStore.
    /// Strictly enforces AC-C12 ordering:
    /// read metadata -> validate metadata -> validate path containment -> read bytes -> validate digest/bounds -> ArtifactStore.save(.temporaryExtraction).
    public func ingestScreenshot(
        metadataURL: URL,
        dataURL: URL,
        request: MacOSGUIVerifierRuntime.InvocationRequest,
        conversationID: UUID,
        artifactStore: ArtifactStore,
        allowedTempRoot: URL,
        fault_simulateArtifactStoreSaveFailure: Bool = false
    ) -> IngestionOutcome {
        let fileManager = FileManager.default

        // Step 1: Read transport metadata
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return .rejected(reason: "Screenshot metadata file missing at '\(metadataURL.path)'")
        }

        let metaData: Data
        do {
            metaData = try Data(contentsOf: metadataURL)
        } catch {
            return .rejected(reason: "Failed to read screenshot metadata file: \(error.localizedDescription)")
        }

        let metadata: ScreenshotTransportMetadata
        do {
            metadata = try JSONDecoder().decode(ScreenshotTransportMetadata.self, from: metaData)
        } catch {
            return .rejected(reason: "Failed to decode screenshot metadata JSON: \(error.localizedDescription)")
        }

        // Step 2: Validate metadata correlation against production request
        if metadata.invocationID != request.invocationID {
            return .rejected(reason: "Invocation ID mismatch: expected \(request.invocationID), got \(metadata.invocationID)")
        }
        if let expectedVRun = request.verificationRunID, !expectedVRun.isEmpty, metadata.verificationRunID != expectedVRun {
            return .rejected(reason: "Verification run ID mismatch: expected \(expectedVRun), got \(metadata.verificationRunID)")
        }
        if let expectedCaptureID = request.captureID, !expectedCaptureID.isEmpty, metadata.captureID != expectedCaptureID {
            return .rejected(reason: "Capture ID mismatch: expected \(expectedCaptureID), got \(metadata.captureID)")
        }
        if metadata.taskID != request.taskID {
            return .rejected(reason: "Task ID mismatch: expected \(request.taskID), got \(metadata.taskID)")
        }
        if metadata.runID != request.runID.uuidString {
            return .rejected(reason: "Run ID mismatch: expected \(request.runID.uuidString), got \(metadata.runID)")
        }
        if metadata.requirementID != request.requirementID {
            return .rejected(reason: "Requirement ID mismatch: expected \(request.requirementID), got \(metadata.requirementID)")
        }
        if metadata.captureTestIdentity != request.concreteVerifierIdentity {
            return .rejected(reason: "Capture test identity mismatch: expected \(request.concreteVerifierIdentity), got \(metadata.captureTestIdentity)")
        }

        // Step 3: Validate transport path containment (no traversal or symlink escape)
        let canonicalAllowedRoot = allowedTempRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalMetaURL = metadataURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalDataURL = dataURL.resolvingSymlinksInPath().standardizedFileURL

        guard isStrictDescendant(of: canonicalAllowedRoot, target: canonicalMetaURL) else {
            return .rejected(reason: "Metadata URL escapes authorized temporary invocation root: \(metadataURL.path)")
        }
        guard isStrictDescendant(of: canonicalAllowedRoot, target: canonicalDataURL) else {
            return .rejected(reason: "Data URL escapes authorized temporary invocation root: \(dataURL.path)")
        }

        // Step 4: Validate screenshot file and bytes
        guard fileManager.fileExists(atPath: dataURL.path) else {
            return .rejected(reason: "Screenshot data file missing at '\(dataURL.path)'")
        }

        let attrs = (try? fileManager.attributesOfItem(atPath: dataURL.path)) ?? [:]
        guard let fileType = attrs[.type] as? FileAttributeType, fileType == .typeRegular else {
            return .rejected(reason: "Screenshot data file is not a regular file")
        }

        let rawData: Data
        do {
            rawData = try Data(contentsOf: dataURL)
        } catch {
            return .rejected(reason: "Failed to read screenshot data bytes: \(error.localizedDescription)")
        }

        guard !rawData.isEmpty else {
            return .rejected(reason: "Screenshot data file is empty (0 bytes)")
        }

        guard rawData.count <= AttachmentStore.maxSourceImageBytes else {
            return .rejected(reason: "Screenshot file exceeds maximum image size limit (\(rawData.count) bytes)")
        }

        guard metadata.mimeType == "image/png" || metadata.mimeType == "image/jpeg" else {
            return .rejected(reason: "Unsupported screenshot MIME type: \(metadata.mimeType)")
        }

        guard Int64(rawData.count) == metadata.byteCount else {
            return .rejected(reason: "Screenshot byte count mismatch: metadata declared \(metadata.byteCount), actual \(rawData.count)")
        }

        // Digest verification
        var hasher = SHA256()
        hasher.update(data: rawData)
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard actualDigest.lowercased() == metadata.sha256.lowercased() else {
            return .rejected(reason: "Screenshot SHA-256 digest mismatch: metadata declared \(metadata.sha256), actual \(actualDigest)")
        }

        // Step 5: ONLY NOW call ArtifactStore.save(...)
        if fault_simulateArtifactStoreSaveFailure {
            return .failed(reason: "Simulated ArtifactStore.save failure")
        }

        let filename = "verification_screenshot_\(metadata.captureID).png"
        let descriptor: ArtifactDescriptor
        do {
            descriptor = try artifactStore.save(
                data: rawData,
                conversationID: conversationID,
                filename: filename,
                mimeType: metadata.mimeType,
                producerProvenance: .testing,
                retentionClass: .temporaryExtraction
            )
        } catch {
            return .failed(reason: "ArtifactStore.save failed: \(error.localizedDescription)")
        }

        // Step 6: Safe transport file cleanup (cleanup failure must not invalidate committed ArtifactStore truth)
        try? fileManager.removeItem(at: dataURL)
        try? fileManager.removeItem(at: metadataURL)

        let artifactRef = ArtifactRef(artifactID: descriptor.artifactID, conversationID: conversationID)
        return .success(descriptor: descriptor, artifactRef: artifactRef)
    }

    // MARK: - Private Helpers

    private func isStrictDescendant(of parent: URL, target: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if parentPath == targetPath {
            return false
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return targetPath.hasPrefix(prefix)
    }
}
