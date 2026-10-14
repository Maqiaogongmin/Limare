import Foundation
import CryptoKit

/// Production-side screenshot evidence adapter and semantic verification pipeline (Batch C / CUGV-G12 / EC-C01).
///
/// Responsibilities:
/// 1. Untrusted screenshot payload validation enforcing AC-C12 strict ordering:
///    - Read transport metadata
///    - Validate correlation against production request (invocationID, verificationRunID, captureID, taskID, runID, requirementID, captureTestIdentity)
///    - Validate path containment (inside invocation temp root, regular file, no symlink escape)
///    - Read screenshot bytes and validate digest (SHA-256) and size bounds (<= 25MB)
///    - ONLY THEN call ArtifactStore.save(..., retentionClass: .temporaryExtraction)
/// 2. Failure screenshot policy: ordinary/failure screenshots remain `.temporaryExtraction` (never blanket-pinned).
/// 3. Reuses existing `ToolExecutor.execute(read_image)` and `VisionGroupResolver` for semantic evaluation.
/// 4. If semantic evaluation produces a valid finding: promotes artifact to `.evidencePinned` via `ArtifactStore.pinForEvidence`.
/// 5. Class-C finding payload creation (`FindingPayload`) referencing the pinned `ArtifactRef`.
/// 6. Specialist receipt creation (`.specialistProcessed(specialistID:success: true)`) with zero finding text.
/// 7. Atomic semantic admission into `ConversationRunCoordinator` (EC-C01).
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

    // MARK: - Semantic Evaluation Pipeline

    /// Orchestrates semantic evaluation reusing the existing `ToolExecutor.execute(read_image)` production seam.
    /// If evaluation succeeds, promotes artifact to `.evidencePinned` and atomically admits
    /// the `VerificationResult(.advisoryFinding)` and specialist `EvidenceReceipt(.specialistProcessed)`.
    @MainActor
    func evaluateSemanticRequirement(
        semanticRequirement: VerificationRequirement,
        artifactDescriptor: ArtifactDescriptor,
        artifactRef: ArtifactRef,
        conversationID: UUID,
        runID: UUID,
        taskID: String,
        verificationRunID: String? = nil,
        toolExecutor: ToolExecutor,
        artifactStore: ArtifactStore,
        coordinator: ConversationRunCoordinator,
        evaluatorIdentity: String = "vision.read_image",
        fault_simulatePinFailure: Bool = false,
        fault_simulateRollbackFailure: Bool = false
    ) async -> (result: VerificationResult?, receipt: EvidenceReceipt?) {
        // Conversation scope integrity (§43)
        guard artifactRef.conversationID == conversationID else {
            return (nil, nil)
        }

        // Build declared semantic prompt (§17)
        let prompt = """
        Review this Limare screenshot for the declared semantic requirement:

        Fact:
        \(semanticRequirement.fact)

        Expected condition:
        \(semanticRequirement.expectedCondition)

        Report what you observe.
        Do not return PASS/FAIL.
        Return a concise visual finding.
        """

        let argJSON: [String: Any] = [
            "path": "artifact://\(artifactRef.artifactID.uuidString)",
            "prompt": prompt
        ]
        guard let argData = try? JSONSerialization.data(withJSONObject: argJSON),
              let argString = String(data: argData, encoding: .utf8) else {
            return (nil, nil)
        }

        let readImageCallID = UUID().uuidString
        let toolCall = ProviderToolCall(
            id: readImageCallID,
            function: .init(name: "read_image", arguments: argString)
        )

        let scopedExecutor = toolExecutor.scoped(for: conversationID, runID: runID)
        let outcome = await scopedExecutor.execute(toolCall, onUpdate: { _ in })

        // Evaluator unavailable / error -> .unsupported (§27, AC-C4, ADV-C05)
        if outcome.isError {
            let unsupportedResult = VerificationResult(
                requirementID: semanticRequirement.requirementID,
                verifierIdentity: evaluatorIdentity,
                resultState: .unsupported,
                evidenceReferences: VerificationEvidenceReferences(receiptIDs: []),
                correlation: VerificationCorrelation(runID: runID, verificationRunID: verificationRunID)
            )
            _ = coordinator.recordVerificationResult(runID: runID, result: unsupportedResult)
            return (unsupportedResult, nil)
        }

        // Semantic finding produced:
        let findingText = outcome.content

        // Retention rule (§12, §13, AC-C6):
        // Promote artifact to .evidencePinned. A finding must never reference temporary evidence.
        guard let currentDesc = try? artifactStore.resolveDescriptor(
            artifactID: artifactRef.artifactID,
            conversationID: conversationID
        ) else {
            return (nil, nil)
        }
        let previousRetentionClass = currentDesc.retentionClass
        let needsPromotion = (previousRetentionClass != .evidencePinned)

        if fault_simulatePinFailure {
            let unsupportedResult = VerificationResult(
                requirementID: semanticRequirement.requirementID,
                verifierIdentity: evaluatorIdentity,
                resultState: .unsupported,
                evidenceReferences: VerificationEvidenceReferences(receiptIDs: []),
                correlation: VerificationCorrelation(runID: runID, verificationRunID: verificationRunID)
            )
            _ = coordinator.recordVerificationResult(runID: runID, result: unsupportedResult)
            return (unsupportedResult, nil)
        }

        if needsPromotion {
            do {
                _ = try artifactStore.pinForEvidence(
                    artifactID: artifactRef.artifactID,
                    conversationID: conversationID
                )
            } catch {
                let unsupportedResult = VerificationResult(
                    requirementID: semanticRequirement.requirementID,
                    verifierIdentity: evaluatorIdentity,
                    resultState: .unsupported,
                    evidenceReferences: VerificationEvidenceReferences(receiptIDs: []),
                    correlation: VerificationCorrelation(runID: runID, verificationRunID: verificationRunID)
                )
                _ = coordinator.recordVerificationResult(runID: runID, result: unsupportedResult)
                return (unsupportedResult, nil)
            }
        }

        // Verify descriptor is pinned and available
        guard let pinnedDescriptor = try? artifactStore.resolveDescriptor(
            artifactID: artifactRef.artifactID,
            conversationID: conversationID
        ), pinnedDescriptor.retentionClass == .evidencePinned,
           pinnedDescriptor.retentionState == .available else {
            if needsPromotion {
                _ = try? artifactStore.unpin(artifactID: artifactRef.artifactID, conversationID: conversationID, newClass: previousRetentionClass)
            }
            return (nil, nil)
        }

        // Construct FindingPayload (§19)
        let payload = FindingPayload(
            evaluatorID: evaluatorIdentity,
            artifactRef: artifactRef,
            text: findingText,
            governingRequirementID: semanticRequirement.requirementID
        )

        // Construct Specialist Receipt (§24, §25, CAUS-C01...CAUS-C05)
        let receipt = EvidenceReceipt(
            taskID: taskID,
            runID: runID,
            turnID: nil, // Genuine turn identity or nil (CAUS-C05)
            sourceCallID: readImageCallID, // Actual ProviderToolCall.id (CAUS-C02, CAUS-C03)
            observation: .specialistProcessed(
                specialistID: evaluatorIdentity, // Specialist ID (CAUS-C01)
                success: true
            ),
            reportedCanonicalOwnerDomain: "gui_verifier"
        )

        // Construct VerificationResult (§20, CAUS-C04)
        let result = VerificationResult(
            requirementID: semanticRequirement.requirementID,
            verifierIdentity: evaluatorIdentity,
            resultState: .advisoryFinding,
            evidenceReferences: VerificationEvidenceReferences(
                artifactRefs: [artifactRef],
                receiptIDs: [receipt.id]
            ),
            correlation: VerificationCorrelation(
                runID: runID,
                verificationRunID: verificationRunID,
                turnID: nil,
                callID: readImageCallID
            ),
            findingPayload: payload
        )

        // Atomic Admission (EC-C01 / §26)
        let admitted = coordinator.recordSemanticVerification(
            runID: runID,
            verificationResult: result,
            specialistReceipt: receipt,
            artifactStore: artifactStore
        )

        guard admitted else {
            // Admission rejected: roll back pin if promoted during this evaluation (RET-C02, RET-C03)
            if needsPromotion {
                do {
                    if fault_simulateRollbackFailure {
                        struct SimulatedRollbackError: Error {}
                        throw SimulatedRollbackError()
                    }
                    try artifactStore.unpin(
                        artifactID: artifactRef.artifactID,
                        conversationID: conversationID,
                        newClass: previousRetentionClass
                    )
                } catch {
                    // Rollback failure surfaced explicitly: never claimed as clean admission (RET-C04)
                    return (nil, nil)
                }
            }
            return (nil, nil)
        }

        return (result, receipt)
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
