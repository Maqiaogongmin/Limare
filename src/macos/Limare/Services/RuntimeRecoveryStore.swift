import Foundation

struct ActiveRunRecoveryRecord: Codable, Sendable, Equatable {
    let runID: UUID
    let conversationID: UUID
    var ownerProcessInstanceID: UUID
    var lastKnownStatus: ConversationRunStatus
    /// Canonical terminal reason/error. Optional for backward-compatible v1 snapshots.
    var terminalError: String?
    var startedAt: Date
    var updatedAt: Date
    var modelSourceSnapshot: ConversationModelSource
    var workingDirectorySnapshot: URL
    var projectID: UUID?
    var recoveredFromRunID: UUID?
    var lastKnownPhase: String?

    init(
        runID: UUID,
        conversationID: UUID,
        ownerProcessInstanceID: UUID,
        lastKnownStatus: ConversationRunStatus,
        terminalError: String? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        modelSourceSnapshot: ConversationModelSource,
        workingDirectorySnapshot: URL,
        projectID: UUID? = nil,
        recoveredFromRunID: UUID? = nil,
        lastKnownPhase: String? = nil
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.ownerProcessInstanceID = ownerProcessInstanceID
        self.lastKnownStatus = lastKnownStatus
        self.terminalError = terminalError
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.modelSourceSnapshot = modelSourceSnapshot
        self.workingDirectorySnapshot = workingDirectorySnapshot
        self.projectID = projectID
        self.recoveredFromRunID = recoveredFromRunID
        self.lastKnownPhase = lastKnownPhase
    }
}

struct RecoverySnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var ownerProcessInstanceID: UUID
    var activeRuns: [UUID: ActiveRunRecoveryRecord]
    var terminalRuns: [UUID: ActiveRunRecoveryRecord]
    var queues: [UUID: [QueuedConversationInput]]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case ownerProcessInstanceID
        case activeRuns
        case terminalRuns
        case queues
    }

    init(
        schemaVersion: Int = RecoverySnapshot.currentSchemaVersion,
        ownerProcessInstanceID: UUID,
        activeRuns: [UUID: ActiveRunRecoveryRecord] = [:],
        terminalRuns: [UUID: ActiveRunRecoveryRecord] = [:],
        queues: [UUID: [QueuedConversationInput]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.ownerProcessInstanceID = ownerProcessInstanceID
        self.activeRuns = activeRuns
        self.terminalRuns = terminalRuns
        self.queues = queues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? RecoverySnapshot.currentSchemaVersion
        ownerProcessInstanceID = try container.decode(UUID.self, forKey: .ownerProcessInstanceID)
        activeRuns = try container.decodeIfPresent([UUID: ActiveRunRecoveryRecord].self, forKey: .activeRuns) ?? [:]
        terminalRuns = try container.decodeIfPresent([UUID: ActiveRunRecoveryRecord].self, forKey: .terminalRuns) ?? [:]
        queues = try container.decodeIfPresent([UUID: [QueuedConversationInput]].self, forKey: .queues) ?? [:]
    }
}

@MainActor
final class RuntimeRecoveryStore {
    let processInstanceID: UUID
    let rootURL: URL
    private let recoveryFileURL: URL
    private let fileManager: FileManager
    private let logs: DebugLogStore

    private(set) var activeRuns: [UUID: ActiveRunRecoveryRecord] = [:]
    private(set) var terminalRuns: [UUID: ActiveRunRecoveryRecord] = [:]
    private(set) var queues: [UUID: [QueuedConversationInput]] = [:]
    private(set) var interruptedRuns: [UUID: ActiveRunRecoveryRecord] = [:]

    init(
        processInstanceID: UUID = UUID(),
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default,
        logs: DebugLogStore
    ) {
        self.processInstanceID = processInstanceID
        self.fileManager = fileManager
        self.logs = logs

        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        self.rootURL = root
        self.recoveryFileURL = root.appendingPathComponent("runtime_recovery.json")

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    @ObservationIgnored
    var onWillPersistSnapshot: ((RecoverySnapshot) throws -> Void)?

    func resetTestHooks() {
        onWillPersistSnapshot = nil
    }

    // MARK: - Startup Reconciliation

    /// Loads persisted recovery state and reconciles stale runs from previous process instances.
    /// Returns any queues that survived relaunch.
    /// Conversations whose run this launch found interrupted (not ones reconciled earlier).
    private(set) var newlyInterrupted: Set<UUID> = []

    func reconcileStartupState() -> (interruptedRuns: [UUID: ActiveRunRecoveryRecord], recoveredQueues: [UUID: [QueuedConversationInput]]) {
        guard fileManager.fileExists(atPath: recoveryFileURL.path) else {
            return ([:], [:])
        }

        guard let data = try? Data(contentsOf: recoveryFileURL) else {
            logs.error("RecoveryStore", "Failed to read runtime_recovery.json at '\(recoveryFileURL.path)'.")
            return ([:], [:])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot: RecoverySnapshot
        do {
            snapshot = try decoder.decode(RecoverySnapshot.self, from: data)
        } catch {
            logs.error("RecoveryStore", "Failed to decode runtime_recovery.json (corrupted data): \(error.localizedDescription)")
            return ([:], [:])
        }

        var interrupted: [UUID: ActiveRunRecoveryRecord] = [:]
        newlyInterrupted = []
        for (convID, record) in snapshot.activeRuns {
            if record.lastKnownStatus == .interrupted {
                // Reconciled at an earlier launch: still recoverable, not a new interruption.
                interrupted[convID] = record
            } else if record.ownerProcessInstanceID != processInstanceID && !record.lastKnownStatus.isTerminal {
                newlyInterrupted.insert(convID)
                var reconciled = record
                reconciled.lastKnownStatus = .interrupted
                reconciled.updatedAt = Date()
                interrupted[convID] = reconciled
                logs.info("RecoveryStore", "Reconciled stale run '\(record.runID)' for conversation '\(convID)' to .interrupted (previous process: \(record.ownerProcessInstanceID)).")
            }
        }

        self.interruptedRuns = interrupted
        self.terminalRuns = snapshot.terminalRuns
        self.queues = snapshot.queues
        self.activeRuns = [:]

        // Persist reconciled state under current process instance
        do {
            try persistSnapshot()
        } catch {
            logs.error("RecoveryStore", "Failed to persist startup reconciliation snapshot: \(error.localizedDescription)")
        }

        return (interrupted, snapshot.queues)
    }

    // MARK: - Active Run Lifecycle

    func recordRunStart(
        conversationID: UUID,
        runID: UUID,
        modelSource: ConversationModelSource,
        workingDirectory: URL,
        projectID: UUID? = nil,
        recoveredFromRunID: UUID? = nil,
        phase: String? = nil
    ) throws {
        interruptedRuns.removeValue(forKey: conversationID)
        let record = ActiveRunRecoveryRecord(
            runID: runID,
            conversationID: conversationID,
            ownerProcessInstanceID: processInstanceID,
            lastKnownStatus: .running,
            startedAt: Date(),
            updatedAt: Date(),
            modelSourceSnapshot: modelSource,
            workingDirectorySnapshot: workingDirectory,
            projectID: projectID,
            recoveredFromRunID: recoveredFromRunID,
            lastKnownPhase: phase
        )
        activeRuns[conversationID] = record
        do {
            try persistSnapshot()
            logs.info("RecoveryStore", "Persisted active run '\(runID)' for conversation '\(conversationID)' before provider execution.")
        } catch {
            activeRuns.removeValue(forKey: conversationID)
            throw error
        }
    }

    func recordRunStatus(
        conversationID: UUID,
        runID: UUID,
        status: ConversationRunStatus,
        workingDirectory: URL? = nil,
        phase: String? = nil
    ) throws {
        guard var record = activeRuns[conversationID], record.runID == runID else { return }
        let previousRecord = record
        record.lastKnownStatus = status
        record.updatedAt = Date()
        if let workingDirectory {
            record.workingDirectorySnapshot = workingDirectory
        }
        if let phase {
            record.lastKnownPhase = phase
        }
        activeRuns[conversationID] = record
        do {
            try persistSnapshot()
            logs.info("RecoveryStore", "Updated status of run '\(runID)' to '\(status.rawValue)'.")
        } catch {
            activeRuns[conversationID] = previousRecord
            throw error
        }
    }

    func recordRunTerminal(
        conversationID: UUID,
        runID: UUID,
        status: ConversationRunStatus = .completed,
        error: String? = nil
    ) throws {
        guard let record = activeRuns[conversationID], record.runID == runID else { return }
        let previousActive = activeRuns[conversationID]
        let previousTerminal = terminalRuns[runID]

        var terminalRecord = record
        terminalRecord.lastKnownStatus = status
        terminalRecord.terminalError = error
        terminalRecord.updatedAt = Date()

        activeRuns.removeValue(forKey: conversationID)
        terminalRuns[runID] = terminalRecord

        do {
            try persistSnapshot()
            logs.info("RecoveryStore", "Atomically transitioned run '\(runID)' to terminal state '\(status.rawValue)' for conversation '\(conversationID)'.")
        } catch {
            if let previousActive {
                activeRuns[conversationID] = previousActive
            }
            if let previousTerminal {
                terminalRuns[runID] = previousTerminal
            } else {
                terminalRuns.removeValue(forKey: runID)
            }
            throw error
        }
    }

    func discardInterruptedRecovery(conversationID: UUID) throws {
        if let interrupted = interruptedRuns.removeValue(forKey: conversationID) {
            do {
                try persistSnapshot()
                logs.info("RecoveryStore", "Discarded interrupted recovery record for conversation '\(conversationID)'.")
            } catch {
                interruptedRuns[conversationID] = interrupted
                throw error
            }
        }
    }

    // MARK: - Queue Lifecycle

    func saveQueues(_ queues: [UUID: [QueuedConversationInput]]) throws {
        let previousQueues = self.queues
        self.queues = queues
        do {
            try persistSnapshot()
        } catch {
            self.queues = previousQueues
            throw error
        }
    }

    func removeConversation(conversationID: UUID) throws {
        let prevActive = activeRuns.removeValue(forKey: conversationID)
        let prevInterrupted = interruptedRuns.removeValue(forKey: conversationID)
        let prevTerminalRuns = terminalRuns
        let prevQueues = queues.removeValue(forKey: conversationID)

        terminalRuns = terminalRuns.filter { $0.value.conversationID != conversationID }

        do {
            try persistSnapshot()
            logs.info("RecoveryStore", "Cleaned up recovery ownership and queues for deleted conversation '\(conversationID)'.")
        } catch {
            if let prevActive { activeRuns[conversationID] = prevActive }
            if let prevInterrupted { interruptedRuns[conversationID] = prevInterrupted }
            terminalRuns = prevTerminalRuns
            if let prevQueues { queues[conversationID] = prevQueues }
            throw error
        }
    }

    // MARK: - Persistence

    private func persistSnapshot() throws {
        // Save both active runs and interrupted runs (if any) in activeRuns/interrupted
        var runsToPersist = activeRuns
        for (convID, interrupted) in interruptedRuns {
            if runsToPersist[convID] == nil {
                runsToPersist[convID] = interrupted
            }
        }

        let snapshot = RecoverySnapshot(
            ownerProcessInstanceID: processInstanceID,
            activeRuns: runsToPersist,
            terminalRuns: terminalRuns,
            queues: queues
        )

        if let hook = onWillPersistSnapshot {
            try hook(snapshot)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: recoveryFileURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryFileURL.path)
        } catch {
            logs.error("RecoveryStore", "Failed to atomically persist runtime_recovery.json: \(error.localizedDescription)")
            throw error
        }
    }
}
