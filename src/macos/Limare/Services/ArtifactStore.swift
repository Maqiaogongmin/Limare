import Foundation
import CryptoKit

public enum ArtifactStoreError: Error, LocalizedError, Sendable, Equatable {
    case pathTraversalDetected(String)
    case unauthorizedAccess(artifactID: UUID, requestedConversationID: UUID)
    case artifactNotFound(UUID)
    case fileMissing(UUID, path: String)
    case fileExpired(UUID)
    case integrityMismatch(expected: String, actual: String)
    case invalidData(String)
    case writeFailed(String)
    case deletionFailed(path: String, underlying: String)
    case directoryCreationFailed(path: String, underlying: String)
    case permissionEnforcementFailed(path: String, underlying: String)
    case metadataReadFailed(String)
    case metadataCorrupted(String)
    case metadataPersistenceFailed(String)
    case saveWithRollbackFailure(primary: String, rollbackError: String)
    case missingFileStatePersistenceFailed(artifactID: UUID, path: String, underlying: String)
    case gcRestoreFailed(artifactID: UUID, originalPath: String, stagingPath: String, primary: String, restoreError: String)
    case conversationDeleteRestoreFailed(conversationID: UUID, originalPath: String, stagingPath: String, primary: String, restoreError: String)
    case quarantineReconciliationFailed(String)
    case quarantineRestoreConflict(path: String, reason: String)
    case storeUnavailable

    public var errorDescription: String? {
        switch self {
        case .pathTraversalDetected(let path):
            return "Invalid artifact path detected (containment violation): \(path)"
        case .unauthorizedAccess(let artifactID, let convID):
            return "Unauthorized access to artifact '\(artifactID)' from conversation '\(convID)'."
        case .artifactNotFound(let id):
            return "Artifact descriptor not found for ID '\(id)'."
        case .fileMissing(let id, let path):
            return "Artifact file missing on disk for ID '\(id)' at '\(path)'."
        case .fileExpired(let id):
            return "Artifact '\(id)' has expired and is no longer available."
        case .integrityMismatch(let expected, let actual):
            return "Artifact SHA-256 integrity mismatch: expected \(expected), got \(actual)."
        case .invalidData(let reason):
            return "Invalid artifact data: \(reason)"
        case .writeFailed(let reason):
            return "Failed to write artifact: \(reason)"
        case .deletionFailed(let path, let underlying):
            return "Failed to delete artifact at '\(path)': \(underlying)"
        case .directoryCreationFailed(let path, let underlying):
            return "Failed to create artifact directory at '\(path)': \(underlying)"
        case .permissionEnforcementFailed(let path, let underlying):
            return "Failed to enforce permissions at '\(path)': \(underlying)"
        case .metadataReadFailed(let reason):
            return "Failed to read artifact metadata: \(reason)"
        case .metadataCorrupted(let reason):
            return "Artifact metadata corrupted: \(reason)"
        case .metadataPersistenceFailed(let reason):
            return "Failed to persist artifact metadata: \(reason)"
        case .saveWithRollbackFailure(let primary, let rollbackError):
            return "Failed to save artifact (\(primary)) and rollback also failed (\(rollbackError))"
        case .missingFileStatePersistenceFailed(let id, let path, let underlying):
            return "Artifact file '\(id)' missing at '\(path)' and metadata persistence failed: \(underlying)"
        case .gcRestoreFailed(let id, let orig, let staged, let primary, let restoreErr):
            return "GC metadata commit failed (\(primary)) and restoration from staging (\(staged) -> \(orig)) also failed for artifact '\(id)': \(restoreErr)"
        case .conversationDeleteRestoreFailed(let convID, let orig, let staged, let primary, let restoreErr):
            return "Conversation '\(convID)' deletion metadata commit failed (\(primary)) and restoration from staging (\(staged) -> \(orig)) also failed: \(restoreErr)"
        case .quarantineReconciliationFailed(let reason):
            return "Quarantine reconciliation failed: \(reason)"
        case .quarantineRestoreConflict(let path, let reason):
            return "Quarantine restoration conflict at '\(path)': \(reason)"
        case .storeUnavailable:
            return "Artifact storage is unavailable."
        }
    }
}

public final class ArtifactStore: @unchecked Sendable {
    public let storageRootURL: URL
    public let artifactsDirectoryURL: URL
    private let metadataFileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var descriptors: [UUID: ArtifactDescriptor] = [:]

    // MARK: - Internal Fault Injection Seam (Testing Only)
    var fault_simulateMetadataPersistenceFailure: Error? = nil
    var fault_simulateFileRemovalFailure: Error? = nil
    var fault_simulateMetadataPreCommitFailure: Bool = false
    var fault_simulateGCRestoreFailure: Error? = nil
    var fault_simulateConversationDeleteRestoreFailure: Error? = nil

    private var quarantineDirectoryURL: URL {
        artifactsDirectoryURL.appendingPathComponent(".quarantine", isDirectory: true)
    }

    public init(
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager

        let resolvedRoot: URL
        let resolvedArtifactsDir: URL

        if let storageRootURL {
            if storageRootURL.lastPathComponent == "artifacts" {
                resolvedArtifactsDir = storageRootURL
                resolvedRoot = storageRootURL.deletingLastPathComponent()
            } else {
                resolvedRoot = storageRootURL
                resolvedArtifactsDir = storageRootURL.appendingPathComponent("artifacts", isDirectory: true)
            }
        } else {
            let appSupport = LimareStorage.applicationSupport
            resolvedRoot = appSupport.appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
            resolvedArtifactsDir = resolvedRoot.appendingPathComponent("artifacts", isDirectory: true)
        }

        self.storageRootURL = resolvedRoot
        self.artifactsDirectoryURL = resolvedArtifactsDir
        self.metadataFileURL = resolvedArtifactsDir.appendingPathComponent("metadata.json")

        // Root Symlink Escape Probe A Check:
        // Ensure resolvedArtifactsDir is contained within resolvedRoot and is not an escaping symlink.
        let canonicalRoot = resolvedRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalArtifactsDir = resolvedArtifactsDir.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalArtifactsDir.path == canonicalRoot.path || canonicalArtifactsDir.path.hasPrefix(canonicalRoot.path + "/") else {
            throw ArtifactStoreError.pathTraversalDetected("Artifacts directory escaped authority root via symlink: \(resolvedArtifactsDir.path)")
        }

        if !fileManager.fileExists(atPath: resolvedArtifactsDir.path) {
            do {
                try fileManager.createDirectory(
                    at: resolvedArtifactsDir,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ArtifactStoreError.directoryCreationFailed(path: resolvedArtifactsDir.path, underlying: error.localizedDescription)
            }
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: resolvedArtifactsDir.path)
        } catch {
            throw ArtifactStoreError.permissionEnforcementFailed(path: resolvedArtifactsDir.path, underlying: error.localizedDescription)
        }

        // Setup / normalize .quarantine directory inside canonical ArtifactStore authority
        let quarantineDir = resolvedArtifactsDir.appendingPathComponent(".quarantine", isDirectory: true)
        if !fileManager.fileExists(atPath: quarantineDir.path) {
            do {
                try fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
            } catch {
                throw ArtifactStoreError.directoryCreationFailed(path: quarantineDir.path, underlying: error.localizedDescription)
            }
        } else {
            let canonicalQuarantine = quarantineDir.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalQuarantine.path.hasPrefix(canonicalArtifactsDir.path + "/") else {
                throw ArtifactStoreError.pathTraversalDetected("Quarantine directory escaped authority root via symlink: \(quarantineDir.path)")
            }
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineDir.path)
        } catch {
            throw ArtifactStoreError.permissionEnforcementFailed(path: quarantineDir.path, underlying: error.localizedDescription)
        }

        // Metadata Symlink and POSIX 0600 Authority Hardening on Init:
        if fileManager.fileExists(atPath: metadataFileURL.path) {
            let canonicalMeta = metadataFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalMeta.path.hasPrefix(canonicalArtifactsDir.path + "/") else {
                throw ArtifactStoreError.pathTraversalDetected("Metadata file escaped artifacts root via symlink: \(metadataFileURL.path)")
            }
            do {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataFileURL.path)
            } catch {
                throw ArtifactStoreError.permissionEnforcementFailed(path: metadataFileURL.path, underlying: error.localizedDescription)
            }
        }

        // Load authoritative metadata before any reconciliation
        try loadMetadataFromDisk()

        // Reconcile quarantine against authoritative metadata
        try reconcileQuarantineLocked()
    }

    private func reconcileQuarantineLocked() throws {
        let quarantineDir = artifactsDirectoryURL.appendingPathComponent(".quarantine", isDirectory: true)
        if fileManager.fileExists(atPath: quarantineDir.path) {
            let contents: [String]
            do {
                contents = try fileManager.contentsOfDirectory(atPath: quarantineDir.path)
            } catch {
                throw ArtifactStoreError.quarantineReconciliationFailed("Failed to list quarantine directory at '\(quarantineDir.path)': \(error.localizedDescription)")
            }

            for item in contents {
                if item.hasPrefix(".") {
                    continue
                }
                let itemURL = quarantineDir.appendingPathComponent(item)

                if item.hasPrefix("gc_") {
                    // Staged GC file: gc_<artifactID>_<filename>
                    let rest = String(item.dropFirst(3))
                    let components = rest.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let firstComp = components.first, let artifactID = UUID(uuidString: String(firstComp)) else {
                        throw ArtifactStoreError.quarantineReconciliationFailed("Malformed GC quarantine item: \(item)")
                    }

                    guard let descriptor = descriptors[artifactID] else {
                        throw ArtifactStoreError.quarantineReconciliationFailed("Unreconcilable GC quarantine item with unknown artifact ID: \(artifactID.uuidString)")
                    }

                    if descriptor.retentionState == .expired {
                        // Case B: Metadata commit succeeded before crash. Purge cleanup debt.
                        do {
                            try fileManager.removeItem(at: itemURL)
                        } catch {
                            throw ArtifactStoreError.deletionFailed(path: itemURL.path, underlying: error.localizedDescription)
                        }
                    } else {
                        // Case A: retentionState is non-expired (.available). Crash occurred BEFORE metadata commit!
                        let originalURL = try resolveFileURLInternal(descriptor: descriptor)
                        let convDir = originalURL.deletingLastPathComponent()

                        if !fileManager.fileExists(atPath: convDir.path) {
                            do {
                                try fileManager.createDirectory(at: convDir, withIntermediateDirectories: true)
                                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: convDir.path)
                            } catch {
                                throw ArtifactStoreError.directoryCreationFailed(path: convDir.path, underlying: error.localizedDescription)
                            }
                        }

                        if fileManager.fileExists(atPath: originalURL.path) {
                            throw ArtifactStoreError.quarantineRestoreConflict(path: originalURL.path, reason: "Target artifact file already exists during GC quarantine restoration")
                        }

                        do {
                            try fileManager.moveItem(at: itemURL, to: originalURL)
                            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originalURL.path)
                        } catch {
                            throw ArtifactStoreError.quarantineReconciliationFailed("Failed to restore quarantined file from '\(itemURL.path)' to '\(originalURL.path)': \(error.localizedDescription)")
                        }
                    }
                } else if item.hasPrefix("conv_") {
                    // Staged conversation folder: conv_<conversationID>
                    let rest = String(item.dropFirst(5))
                    guard let conversationID = UUID(uuidString: rest) else {
                        throw ArtifactStoreError.quarantineReconciliationFailed("Malformed conversation quarantine directory: \(item)")
                    }

                    let matchingDescriptors = descriptors.values.filter { $0.conversationID == conversationID }
                    if matchingDescriptors.isEmpty {
                        // Case B: Authoritative metadata contains no descriptors for conversation. Purge cleanup debt.
                        do {
                            try fileManager.removeItem(at: itemURL)
                        } catch {
                            throw ArtifactStoreError.deletionFailed(path: itemURL.path, underlying: error.localizedDescription)
                        }
                    } else {
                        // Case A: Descriptors still exist. Crash occurred BEFORE metadata removal. Restore conversation directory!
                        let convDir = artifactsDirectoryURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)

                        if fileManager.fileExists(atPath: convDir.path) {
                            throw ArtifactStoreError.quarantineRestoreConflict(path: convDir.path, reason: "Target conversation directory already exists during quarantine restoration")
                        }

                        do {
                            try fileManager.moveItem(at: itemURL, to: convDir)
                            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: convDir.path)
                        } catch {
                            throw ArtifactStoreError.quarantineReconciliationFailed("Failed to restore quarantined conversation directory from '\(itemURL.path)' to '\(convDir.path)': \(error.localizedDescription)")
                        }
                    }
                } else {
                    // Case C: Unrecognized / ambiguous quarantine entry
                    throw ArtifactStoreError.quarantineReconciliationFailed("Unrecognized quarantine entry: \(item)")
                }
            }
        }

        // Clean up stale temporary metadata preparation files (.metadata.tmp.*)
        let rootContents: [String]
        do {
            rootContents = try fileManager.contentsOfDirectory(atPath: artifactsDirectoryURL.path)
        } catch {
            throw ArtifactStoreError.quarantineReconciliationFailed("Failed to list artifacts directory at '\(artifactsDirectoryURL.path)': \(error.localizedDescription)")
        }

        for file in rootContents {
            if file.hasPrefix(".metadata.tmp.") {
                let tmpURL = artifactsDirectoryURL.appendingPathComponent(file)
                do {
                    try fileManager.removeItem(at: tmpURL)
                } catch {
                    // Non-fatal temporary file cleanup
                }
            }
        }
    }

    private func ensureQuarantineDirectoryLocked() throws {
        if !fileManager.fileExists(atPath: quarantineDirectoryURL.path) {
            do {
                try fileManager.createDirectory(at: quarantineDirectoryURL, withIntermediateDirectories: true)
            } catch {
                throw ArtifactStoreError.directoryCreationFailed(path: quarantineDirectoryURL.path, underlying: error.localizedDescription)
            }
        }
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineDirectoryURL.path)
        } catch {
            throw ArtifactStoreError.permissionEnforcementFailed(path: quarantineDirectoryURL.path, underlying: error.localizedDescription)
        }
    }

    // MARK: - SHA-256 Helper

    public static func computeSHA256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Metadata Persistence

    private func loadMetadataFromDisk() throws {
        guard fileManager.fileExists(atPath: metadataFileURL.path) else {
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: metadataFileURL)
        } catch {
            throw ArtifactStoreError.metadataReadFailed("Failed to read metadata at '\(metadataFileURL.path)': \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let loaded = try decoder.decode([UUID: ArtifactDescriptor].self, from: data)
            lock.lock()
            self.descriptors = loaded
            lock.unlock()
        } catch {
            throw ArtifactStoreError.metadataCorrupted("Corrupted metadata at '\(metadataFileURL.path)': \(error.localizedDescription)")
        }
    }

    private func saveMetadataToDiskLocked(updatedDescriptors: [UUID: ArtifactDescriptor]) throws {
        if let fault = fault_simulateMetadataPersistenceFailure {
            throw fault
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(updatedDescriptors)
        } catch {
            throw ArtifactStoreError.metadataPersistenceFailed("Failed to encode metadata: \(error.localizedDescription)")
        }

        // Atomic commit pattern:
        // 1. Write to temporary file within canonical artifacts directory
        // 2. Enforce POSIX 0600 on temporary file
        // 3. Only replace authoritative metadata.json after all preparation succeeds
        let tempFileURL = artifactsDirectoryURL.appendingPathComponent(".metadata.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tempFileURL, options: .atomic)
        } catch {
            throw ArtifactStoreError.metadataPersistenceFailed("Failed to write temporary metadata to '\(tempFileURL.path)': \(error.localizedDescription)")
        }

        if fault_simulateMetadataPreCommitFailure {
            do {
                if fileManager.fileExists(atPath: tempFileURL.path) {
                    try fileManager.removeItem(at: tempFileURL)
                }
            } catch {
                // Cleanup temp file
            }
            throw ArtifactStoreError.permissionEnforcementFailed(path: tempFileURL.path, underlying: "Simulated pre-commit permission enforcement failure")
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempFileURL.path)
        } catch {
            do {
                if fileManager.fileExists(atPath: tempFileURL.path) {
                    try fileManager.removeItem(at: tempFileURL)
                }
            } catch {
                // Cleanup temp file
            }
            throw ArtifactStoreError.permissionEnforcementFailed(path: tempFileURL.path, underlying: error.localizedDescription)
        }

        // Complete atomic swap/replacement
        do {
            if fileManager.fileExists(atPath: metadataFileURL.path) {
                _ = try fileManager.replaceItemAt(metadataFileURL, withItemAt: tempFileURL, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: tempFileURL, to: metadataFileURL)
            }
        } catch {
            do {
                if fileManager.fileExists(atPath: tempFileURL.path) {
                    try fileManager.removeItem(at: tempFileURL)
                }
            } catch {
                // Cleanup temp file
            }
            throw ArtifactStoreError.metadataPersistenceFailed("Failed to atomically replace metadata at '\(metadataFileURL.path)': \(error.localizedDescription)")
        }
    }

    // MARK: - Path Resolution & Containment

    private func sanitizeFilename(_ filename: String) throws -> (displayName: String, ext: String) {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("artifact.bin", "bin")
        }
        guard !trimmed.contains(".."), !trimmed.hasPrefix("/") else {
            throw ArtifactStoreError.pathTraversalDetected(filename)
        }
        let lastComponent = (trimmed as NSString).lastPathComponent
        guard !lastComponent.isEmpty, lastComponent == trimmed else {
            throw ArtifactStoreError.pathTraversalDetected(filename)
        }
        let ext = (lastComponent as NSString).pathExtension.lowercased()
        let safeExt = ext.isEmpty ? "bin" : ext
        return (lastComponent, safeExt)
    }

    private func resolveFileURLInternal(descriptor: ArtifactDescriptor) throws -> URL {
        let rel = descriptor.relativePath
        guard !rel.contains(".."), !rel.hasPrefix("/") else {
            throw ArtifactStoreError.pathTraversalDetected(rel)
        }

        let canonicalArtifactsRoot = artifactsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let targetURL = storageRootURL.appendingPathComponent(rel)
        let canonicalFile = targetURL.resolvingSymlinksInPath().standardizedFileURL

        guard canonicalFile.path == canonicalArtifactsRoot.path || canonicalFile.path.hasPrefix(canonicalArtifactsRoot.path + "/") else {
            throw ArtifactStoreError.pathTraversalDetected(rel)
        }

        return targetURL
    }

    // MARK: - Save Operations

    /// Stores raw artifact data with SHA-256 integrity, safe POSIX permissions, and atomic metadata update.
    @discardableResult
    public func save(
        data: Data,
        conversationID: UUID,
        filename: String,
        mimeType: String,
        representationEpistemicLevel: RepresentationEpistemicLevel? = .inferred,
        representationProfile: RepresentationProfileIdentity? = nil,
        producerProvenance: ArtifactProducerProvenance = .unspecified,
        workspaceProvenance: URL? = nil,
        authorizationProvenance: String? = nil,
        parentResourceLocator: String? = nil,
        conversionRouteProvenance: String? = nil,
        conversionProvenance: ConversionProvenance? = nil,
        retentionClass: ArtifactRetentionClass = .conversationRetained
    ) throws -> ArtifactDescriptor {
        let (displayName, safeExt) = try sanitizeFilename(filename)
        let artifactID = UUID()
        let convDir = artifactsDirectoryURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)

        let canonicalArtifactsRoot = artifactsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL

        // Symlink Escape Probe B Check:
        // If convDir already exists as a symlink pointing outside authority root, fail closed immediately!
        let canonicalConvDir = convDir.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalConvDir.path.hasPrefix(canonicalArtifactsRoot.path + "/") else {
            throw ArtifactStoreError.pathTraversalDetected("Conversation directory escaped artifacts root via symlink: \(convDir.path)")
        }

        if !fileManager.fileExists(atPath: convDir.path) {
            do {
                try fileManager.createDirectory(
                    at: convDir,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ArtifactStoreError.directoryCreationFailed(path: convDir.path, underlying: error.localizedDescription)
            }
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: convDir.path)
        } catch {
            throw ArtifactStoreError.permissionEnforcementFailed(path: convDir.path, underlying: error.localizedDescription)
        }

        let diskFilename = "\(artifactID.uuidString).\(safeExt)"
        let fileURL = convDir.appendingPathComponent(diskFilename)

        let canonicalFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalFile.path.hasPrefix(canonicalArtifactsRoot.path + "/") else {
            throw ArtifactStoreError.pathTraversalDetected(fileURL.path)
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw ArtifactStoreError.writeFailed("Failed to write artifact bytes to '\(fileURL.path)': \(error.localizedDescription)")
        }

        do {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let permErr {
            var rollbackFailed = false
            var rollbackErrorMsg = ""
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    if let rmErr = fault_simulateFileRemovalFailure {
                        throw rmErr
                    }
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                rollbackFailed = true
                rollbackErrorMsg = error.localizedDescription
            }
            if rollbackFailed {
                throw ArtifactStoreError.saveWithRollbackFailure(
                    primary: "Failed to set file permissions at '\(fileURL.path)': \(permErr.localizedDescription)",
                    rollbackError: rollbackErrorMsg
                )
            } else {
                throw ArtifactStoreError.permissionEnforcementFailed(path: fileURL.path, underlying: permErr.localizedDescription)
            }
        }

        let sha256 = Self.computeSHA256(data: data)
        let relativePath = "artifacts/\(conversationID.uuidString)/\(diskFilename)"

        let descriptor = ArtifactDescriptor(
            artifactID: artifactID,
            conversationID: conversationID,
            filename: displayName,
            relativePath: relativePath,
            mimeType: mimeType,
            byteCount: Int64(data.count),
            sha256: sha256,
            createdAt: Date(),
            producerProvenance: producerProvenance,
            workspaceProvenance: workspaceProvenance,
            authorizationProvenance: authorizationProvenance,
            parentResourceLocator: parentResourceLocator ?? conversionProvenance?.parentResourceLocator,
            conversionRouteProvenance: conversionRouteProvenance ?? conversionProvenance?.selectedRoute.routeID,
            conversionProvenance: conversionProvenance,
            representationEpistemicLevel: representationEpistemicLevel,
            representationProfile: representationProfile,
            retentionState: .available,
            retentionClass: retentionClass
        )

        lock.lock()
        defer { lock.unlock() }

        var updated = descriptors
        updated[artifactID] = descriptor

        do {
            try saveMetadataToDiskLocked(updatedDescriptors: updated)
            self.descriptors = updated
            return descriptor
        } catch let metaErr {
            // Clean up newly created orphan file on metadata commit failure
            var rollbackFailed = false
            var rollbackErrorMsg = ""
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    if let rmErr = fault_simulateFileRemovalFailure {
                        throw rmErr
                    }
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                rollbackFailed = true
                rollbackErrorMsg = error.localizedDescription
            }
            if rollbackFailed {
                throw ArtifactStoreError.saveWithRollbackFailure(
                    primary: metaErr.localizedDescription,
                    rollbackError: rollbackErrorMsg
                )
            } else {
                throw metaErr
            }
        }
    }

    // MARK: - Resolution and Authority Enforcement

    /// Resolves descriptor verifying conversation-scoped authorization and physical availability.
    public func resolveDescriptor(
        artifactID: UUID,
        conversationID: UUID
    ) throws -> ArtifactDescriptor {
        lock.lock()
        guard let descriptor = descriptors[artifactID] else {
            lock.unlock()
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        lock.unlock()

        guard descriptor.conversationID == conversationID else {
            throw ArtifactStoreError.unauthorizedAccess(
                artifactID: artifactID,
                requestedConversationID: conversationID
            )
        }

        if descriptor.retentionState == .expired {
            throw ArtifactStoreError.fileExpired(artifactID)
        }

        let fileURL = try resolveFileURLInternal(descriptor: descriptor)
        if !fileManager.fileExists(atPath: fileURL.path) {
            lock.lock()
            var updated = descriptors
            if var descToUpdate = updated[artifactID] {
                descToUpdate.retentionState = .missing
                updated[artifactID] = descToUpdate
                do {
                    try saveMetadataToDiskLocked(updatedDescriptors: updated)
                    self.descriptors = updated
                } catch {
                    lock.unlock()
                    throw ArtifactStoreError.missingFileStatePersistenceFailed(
                        artifactID: artifactID,
                        path: descriptor.relativePath,
                        underlying: error.localizedDescription
                    )
                }
            }
            lock.unlock()
            throw ArtifactStoreError.fileMissing(artifactID, path: descriptor.relativePath)
        }

        return descriptor
    }

    /// Resolves file URL strictly within canonical root, verifying conversation authority and lifecycle availability.
    public func resolveFileURL(
        artifactID: UUID,
        conversationID: UUID
    ) throws -> URL {
        lock.lock()
        guard let descriptor = descriptors[artifactID] else {
            lock.unlock()
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }
        lock.unlock()

        guard descriptor.conversationID == conversationID else {
            throw ArtifactStoreError.unauthorizedAccess(
                artifactID: artifactID,
                requestedConversationID: conversationID
            )
        }

        if descriptor.retentionState == .expired {
            throw ArtifactStoreError.fileExpired(artifactID)
        }

        if descriptor.retentionState == .missing {
            throw ArtifactStoreError.fileMissing(artifactID, path: descriptor.relativePath)
        }

        let targetURL = try resolveFileURLInternal(descriptor: descriptor)
        if !fileManager.fileExists(atPath: targetURL.path) {
            lock.lock()
            var updated = descriptors
            if var descToUpdate = updated[artifactID] {
                descToUpdate.retentionState = .missing
                updated[artifactID] = descToUpdate
                do {
                    try saveMetadataToDiskLocked(updatedDescriptors: updated)
                    self.descriptors = updated
                } catch {
                    lock.unlock()
                    throw ArtifactStoreError.missingFileStatePersistenceFailed(
                        artifactID: artifactID,
                        path: descriptor.relativePath,
                        underlying: error.localizedDescription
                    )
                }
            }
            lock.unlock()
            throw ArtifactStoreError.fileMissing(artifactID, path: descriptor.relativePath)
        }

        return targetURL
    }

    /// Loads artifact bytes with strict SHA-256 verification and conversation authority check.
    public func loadData(
        artifactID: UUID,
        conversationID: UUID,
        verifyIntegrity: Bool = true
    ) throws -> Data {
        let descriptor = try resolveDescriptor(artifactID: artifactID, conversationID: conversationID)
        let fileURL = try resolveFileURLInternal(descriptor: descriptor)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ArtifactStoreError.fileMissing(artifactID, path: descriptor.relativePath)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ArtifactStoreError.invalidData("Failed to read artifact bytes at '\(fileURL.path)': \(error.localizedDescription)")
        }

        if verifyIntegrity {
            let actualSHA = Self.computeSHA256(data: data)
            guard actualSHA == descriptor.sha256 else {
                throw ArtifactStoreError.integrityMismatch(
                    expected: descriptor.sha256,
                    actual: actualSHA
                )
            }
        }

        return data
    }

    // MARK: - Retention and Evidence Pinning

    /// Promotes an artifact to `.evidencePinned`, guaranteeing protection against GC.
    @discardableResult
    public func pinForEvidence(
        artifactID: UUID,
        conversationID: UUID
    ) throws -> ArtifactDescriptor {
        lock.lock()
        defer { lock.unlock() }

        guard var descriptor = descriptors[artifactID] else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }

        guard descriptor.conversationID == conversationID else {
            throw ArtifactStoreError.unauthorizedAccess(
                artifactID: artifactID,
                requestedConversationID: conversationID
            )
        }

        descriptor.retentionClass = .evidencePinned
        var updated = descriptors
        updated[artifactID] = descriptor

        try saveMetadataToDiskLocked(updatedDescriptors: updated)
        self.descriptors = updated
        return descriptor
    }

    /// Reverts an artifact from pinned state to specified retention class.
    @discardableResult
    public func unpin(
        artifactID: UUID,
        conversationID: UUID,
        newClass: ArtifactRetentionClass = .conversationRetained
    ) throws -> ArtifactDescriptor {
        lock.lock()
        defer { lock.unlock() }

        guard var descriptor = descriptors[artifactID] else {
            throw ArtifactStoreError.artifactNotFound(artifactID)
        }

        guard descriptor.conversationID == conversationID else {
            throw ArtifactStoreError.unauthorizedAccess(
                artifactID: artifactID,
                requestedConversationID: conversationID
            )
        }

        descriptor.retentionClass = newClass
        var updated = descriptors
        updated[artifactID] = descriptor

        try saveMetadataToDiskLocked(updatedDescriptors: updated)
        self.descriptors = updated
        return descriptor
    }

    /// Garbage collects unpinned temporary extraction artifacts with bounded staging rollback safety.
    @discardableResult
    public func cleanupGarbage(
        conversationID: UUID? = nil,
        olderThan: Date? = nil
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        try ensureQuarantineDirectoryLocked()

        var candidates: [(id: UUID, descriptor: ArtifactDescriptor, originalURL: URL, stagedURL: URL)] = []
        var updatedDescriptors = descriptors

        for (id, var descriptor) in descriptors {
            if let conversationID, descriptor.conversationID != conversationID {
                continue
            }

            // Only temporaryExtraction is eligible for automated GC
            guard descriptor.retentionClass == .temporaryExtraction else {
                continue
            }

            if let olderThan, descriptor.createdAt > olderThan {
                continue
            }

            let originalURL = try resolveFileURLInternal(descriptor: descriptor)
            let stagedFilename = "gc_\(id.uuidString)_\(originalURL.lastPathComponent)"
            let stagedURL = quarantineDirectoryURL.appendingPathComponent(stagedFilename)

            descriptor.retentionState = .expired
            updatedDescriptors[id] = descriptor

            candidates.append((id: id, descriptor: descriptor, originalURL: originalURL, stagedURL: stagedURL))
        }

        if candidates.isEmpty {
            return 0
        }

        // Step 1: Stage candidate artifact files into internal quarantine
        var stagedItems: [(id: UUID, originalURL: URL, stagedURL: URL)] = []
        for item in candidates {
            if fileManager.fileExists(atPath: item.originalURL.path) {
                do {
                    if fileManager.fileExists(atPath: item.stagedURL.path) {
                        try fileManager.removeItem(at: item.stagedURL)
                    }
                    try fileManager.moveItem(at: item.originalURL, to: item.stagedURL)
                    stagedItems.append((id: item.id, originalURL: item.originalURL, stagedURL: item.stagedURL))
                } catch {
                    // Roll back already staged items in reverse order
                    for staged in stagedItems.reversed() {
                        do {
                            try fileManager.moveItem(at: staged.stagedURL, to: staged.originalURL)
                        } catch {
                            // Best-effort restoration on staging failure
                        }
                    }
                    throw ArtifactStoreError.deletionFailed(path: item.originalURL.path, underlying: "Failed to stage file into quarantine: \(error.localizedDescription)")
                }
            }
        }

        // Step 2: Atomically commit metadata update marking descriptors .expired
        do {
            try saveMetadataToDiskLocked(updatedDescriptors: updatedDescriptors)
            self.descriptors = updatedDescriptors
        } catch let metaErr {
            // Step 3a: Metadata commit failed -> Restore staged files to original locations
            var anyRestoreFailed = false
            var firstRestoreErr: Error? = nil
            var failedItem: (id: UUID, originalURL: URL, stagedURL: URL)? = nil

            for staged in stagedItems {
                do {
                    if let fault = fault_simulateGCRestoreFailure {
                        throw fault
                    }
                    if fileManager.fileExists(atPath: staged.stagedURL.path) {
                        try fileManager.moveItem(at: staged.stagedURL, to: staged.originalURL)
                    }
                } catch {
                    anyRestoreFailed = true
                    firstRestoreErr = error
                    failedItem = staged
                    break
                }
            }

            if anyRestoreFailed, let failedItem, let firstRestoreErr {
                throw ArtifactStoreError.gcRestoreFailed(
                    artifactID: failedItem.id,
                    originalPath: failedItem.originalURL.path,
                    stagingPath: failedItem.stagedURL.path,
                    primary: metaErr.localizedDescription,
                    restoreError: firstRestoreErr.localizedDescription
                )
            } else {
                throw metaErr
            }
        }

        // Step 3b: Metadata commit succeeded -> Purge quarantined files
        for staged in stagedItems {
            do {
                if fileManager.fileExists(atPath: staged.stagedURL.path) {
                    try fileManager.removeItem(at: staged.stagedURL)
                }
            } catch {
                // Quarantined byte cleanup error handled without compromising metadata truth
            }
        }

        return candidates.count
    }


    /// Cascade deletes all artifacts belonging to a conversation with bounded staging rollback safety.
    public func deleteConversationArtifacts(conversationID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureQuarantineDirectoryLocked()

        var updated = descriptors
        let matchingIDs = descriptors.filter { $0.value.conversationID == conversationID }.map { $0.key }
        for id in matchingIDs {
            updated.removeValue(forKey: id)
        }

        let convDir = artifactsDirectoryURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let stagedConvDir = quarantineDirectoryURL.appendingPathComponent("conv_\(conversationID.uuidString)", isDirectory: true)
        var didStageDir = false

        if fileManager.fileExists(atPath: convDir.path) {
            do {
                if fileManager.fileExists(atPath: stagedConvDir.path) {
                    try fileManager.removeItem(at: stagedConvDir)
                }
                try fileManager.moveItem(at: convDir, to: stagedConvDir)
                didStageDir = true
            } catch {
                throw ArtifactStoreError.deletionFailed(path: convDir.path, underlying: "Failed to stage conversation directory: \(error.localizedDescription)")
            }
        }

        do {
            try saveMetadataToDiskLocked(updatedDescriptors: updated)
            self.descriptors = updated
        } catch let metaErr {
            if didStageDir {
                var restoreFailed = false
                var restoreErrDesc = ""
                do {
                    if let fault = fault_simulateConversationDeleteRestoreFailure {
                        throw fault
                    }
                    if fileManager.fileExists(atPath: stagedConvDir.path) {
                        try fileManager.moveItem(at: stagedConvDir, to: convDir)
                    }
                } catch {
                    restoreFailed = true
                    restoreErrDesc = error.localizedDescription
                }

                if restoreFailed {
                    throw ArtifactStoreError.conversationDeleteRestoreFailed(
                        conversationID: conversationID,
                        originalPath: convDir.path,
                        stagingPath: stagedConvDir.path,
                        primary: metaErr.localizedDescription,
                        restoreError: restoreErrDesc
                    )
                }
            }
            throw metaErr
        }

        if didStageDir {
            do {
                if fileManager.fileExists(atPath: stagedConvDir.path) {
                    try fileManager.removeItem(at: stagedConvDir)
                }
            } catch {
                // Quarantined directory cleanup error handled without compromising metadata truth
            }
        }
    }

    // MARK: - Conversation-Scoped Queries & Internal Helpers

    public func descriptor(
        artifactID: UUID,
        conversationID: UUID
    ) throws -> ArtifactDescriptor {
        try resolveDescriptor(artifactID: artifactID, conversationID: conversationID)
    }

    public func allDescriptors(for conversationID: UUID) -> [ArtifactDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.values.filter { $0.conversationID == conversationID }
    }

    // MARK: - Internal Test Helpers

    func internalDescriptor(for artifactID: UUID) -> ArtifactDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[artifactID]
    }

    func internalContains(artifactID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[artifactID] != nil
    }
}
