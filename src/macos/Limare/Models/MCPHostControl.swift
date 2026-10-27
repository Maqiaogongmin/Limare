import Foundation
import Darwin

enum MCPControlRecord: String, Sendable {
    case configuration = "configuration.v1"
    case journal = "operations.v1"

    var maximumBytes: Int { self == .configuration ? 256 * 1024 : 128 * 1024 }
}

/// IO adapter only. MCPStore remains the configuration and recovery authority.
protocol MCPControlRecordStoring: Sendable {
    func readControlRecord(_ record: MCPControlRecord) throws -> Data?
    func writeControlRecord(_ data: Data, record: MCPControlRecord) throws
    func deleteControlRecord(_ record: MCPControlRecord) throws
}

enum MCPAuthorityState: String, Sendable {
    case ready, migrationRequired, storageUnavailable, recoveryRequired, alreadyRunning

    var message: String {
        switch self {
        case .ready: return String(localized: "MCP configuration storage is ready.")
        case .migrationRequired: return String(localized: "Existing MCP configuration requires an explicit migration. The original data has been preserved.")
        case .storageUnavailable: return String(localized: "MCP configuration storage is unavailable. No empty configuration or file fallback has been activated.")
        case .recoveryRequired: return String(localized: "MCP recovery must complete before another operation or connection can start.")
        case .alreadyRunning: return String(localized: "Another Limare instance owns MCP configuration.")
        }
    }
}

enum MCPHostControlError: Error, LocalizedError {
    case unavailable, invalidRecord, capacityExceeded, revisionConflict, alreadyRunning, unsafeLease, protectedInfrastructure, humanConfirmationRequired
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "MCP native storage is unavailable.")
        case .invalidRecord: return String(localized: "MCP control record is invalid; recovery is required.")
        case .capacityExceeded: return String(localized: "MCP control record exceeds the product capacity limit.")
        case .revisionConflict: return String(localized: "MCP configuration changed; read its current revision before retrying.")
        case .alreadyRunning: return String(localized: "Another Limare instance owns MCP configuration.")
        case .unsafeLease: return String(localized: "The MCP authority lease could not be secured.")
        case .protectedInfrastructure: return "Agent file tools cannot access reserved MCP resources or file aliases."
        case .humanConfirmationRequired: return String(localized: "Adding or replacing an MCP credential needs your confirmation in Limare.")
        }
    }
}

struct MCPHostConfigDocument: Codable {
    var schemaVersion = 1
    var documentRevision: UInt64 = 0
    var lastCommitOperationID: UUID?
    var schemaInitialized = true
    var servers: [MCPServerConfig] = []

    func validate() throws {
        guard schemaVersion == 1, schemaInitialized, documentRevision < UInt64.max, servers.count <= 32,
              Set(servers.map(\.id)).count == servers.count else { throw MCPHostControlError.invalidRecord }
        for server in servers {
            try MCPStore.validate(server)
            guard server.isHTTP != server.isSTDIO,
                  server.startupTimeoutSeconds.map({ (1...300).contains($0) }) ?? true,
                  server.credentialEpoch.map({ $0 < UInt64.max }) ?? true,
                  server.oauth?.callbackPort == nil || server.oauth?.callbackPort == 0 else {
                throw MCPHostControlError.invalidRecord
            }
            for (name, value) in server.extensions ?? [:] {
                let text = value.value as? String
                guard !MCPServerConfig.isSensitiveKey(name), value.value is Bool || value.value is Int || value.value is Double
                        || (text.map { !SecretMasker.containsCredential($0) && !MCPServerConfig.isSecretReference($0) } ?? false) else {
                    throw MCPHostControlError.invalidRecord
                }
            }
            for entries in [server.env ?? [:], server.headers ?? [:]] {
                guard entries.allSatisfy({ !MCPServerConfig.isSensitiveKey($0.key) || MCPServerConfig.isSecretReference($0.value) }) else {
                    throw MCPHostControlError.invalidRecord
                }
            }
        }
    }
}

struct MCPHostOperationReceipt: Codable, Identifiable, Sendable {
    enum Outcome: String, Codable, Sendable { case pending, committed, notCommitted, outcomeUnknown }
    let id: UUID
    let createdAt: Date
    var outcome: Outcome
    var targetRevision: UInt64
    var commandDigest: String?
    var deletionTarget: String?
    var retiredCredentialNamespaces: [String]?
    var candidateCredentialNamespace: String?
    /// Runtime actions (reconnect, authenticate, logout) commit no configuration revision.
    var action: String? = nil
    var serverID: String? = nil
    /// Delivery-only: configuration committed while credential retirement or the receipt write is owed.
    var recoveryPending: Bool? = nil
    var safeError: String? = nil
}

struct MCPConfigurationPatch: Codable, Sendable {
    var set: [String: AnyCodable] = [:]
    var remove: [String] = []
}

struct MCPHostOperationJournal: Codable {
    var schemaVersion = 1
    var journalRevision: UInt64 = 0
    var activeOperations: [MCPHostOperationReceipt] = []
    var terminalReceipts: [MCPHostOperationReceipt] = []

    /// Safe errors are short Host summaries; at most 200 UTF-8 bytes so the journal cap always holds.
    static func bounded(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        return result
    }

    func receipt(_ id: UUID) -> MCPHostOperationReceipt? {
        activeOperations.first(where: { $0.id == id }) ?? terminalReceipts.first(where: { $0.id == id })
    }

    mutating func finish(_ id: UUID, outcome: MCPHostOperationReceipt.Outcome, safeError: String? = nil) {
        guard let index = activeOperations.firstIndex(where: { $0.id == id }) else { return }
        var receipt = activeOperations.remove(at: index)
        receipt.outcome = outcome
        receipt.recoveryPending = nil
        // Recovery data is only needed while active; terminal receipts stay small and bounded.
        receipt.deletionTarget = nil
        receipt.retiredCredentialNamespaces = nil
        receipt.candidateCredentialNamespace = nil
        receipt.safeError = safeError.map(Self.bounded)
        terminalReceipts.append(receipt)
        if terminalReceipts.count > 128 { terminalReceipts.removeFirst(terminalReceipts.count - 128) }
        journalRevision += 1
    }
}

/// OS lifetime lock, not a store. Closing the descriptor releases the authority.
final class MCPAuthorityLease {
    private let descriptor: Int32
    init(directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == directory.standardizedFileURL.path else { throw MCPHostControlError.unsafeLease }
        let path = directory.appendingPathComponent("mcp-authority.lock").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw MCPHostControlError.unsafeLease }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & S_IFMT == S_IFREG, fchmod(fd, 0o600) == 0 else {
            close(fd)
            throw MCPHostControlError.unsafeLease
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw MCPHostControlError.alreadyRunning
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
}
