import Foundation

protocol SecretStoring: Sendable {
    func save(_ value: String, providerID: UUID) throws
    func load(providerID: UUID) throws -> String?
    func delete(providerID: UUID) throws
}

/// App-owned secret storage. It deliberately avoids macOS Keychain APIs so
/// differently signed builds cannot inherit login-keychain ACL prompts.
final class AppSecretFileVault: @unchecked Sendable {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let lock = NSLock()
    private var values: [String: String]
    private var failedToDecode = false

    init(storageRootURL: URL, fileName: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directoryURL = storageRootURL.appendingPathComponent("secrets", isDirectory: true)
        self.directoryURL = directoryURL
        self.fileURL = directoryURL.appendingPathComponent(fileName)
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            values = decoded
        } else {
            values = [:]
            failedToDecode = fileManager.fileExists(atPath: fileURL.path)
        }
    }

    func validateReadable() throws {
        if failedToDecode { throw ProviderCredentialStorageError.invalidRecord }
    }

    func snapshot() throws -> [String: String] {
        try lock.withLock {
            try validateReadable()
            return values
        }
    }

    func changeAtomically(_ change: (inout [String: String]) throws -> Void) throws {
        try lock.withLock {
            try validateReadable()
            let previous = values
            do {
                try change(&values)
                try persistLocked()
            } catch {
                values = previous
                throw error
            }
        }
    }

    func backupForMigration() throws {
        try validateReadable()
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let backup = directoryURL.appendingPathComponent("provider-secrets.legacy-backup.json")
        if !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: fileURL, to: backup)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
    }

    func value(for key: String) -> String? {
        lock.withLock { values[key] }
    }

    func setValue(_ value: String, for key: String) throws {
        try lock.withLock {
            try validateReadable()
            let previous = values[key]
            values[key] = value
            do {
                try persistLocked()
            } catch {
                values[key] = previous
                throw error
            }
        }
    }

    func removeValue(for key: String) throws {
        try lock.withLock {
            try validateReadable()
            guard let previous = values.removeValue(forKey: key) else { return }
            do {
                try persistLocked()
            } catch {
                values[key] = previous
                throw error
            }
        }
    }

    func removeValues(withPrefix prefix: String) throws {
        try lock.withLock {
            try validateReadable()
            let previous = values
            values = values.filter { !$0.key.hasPrefix(prefix) }
            guard values != previous else { return }
            do {
                try persistLocked()
            } catch {
                values = previous
                throw error
            }
        }
    }

    private func ensureDirectoryHardenedLocked() throws {
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir) || !isDir.boolValue {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let attrs = try fileManager.attributesOfItem(atPath: directoryURL.path)
        if let perms = attrs[.posixPermissions] as? NSNumber, (perms.intValue & 0o777) != 0o700 {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func persistLocked() throws {
        // Step 1: Ensure directory exists and is strictly 0700 before writing any candidate plaintext
        try ensureDirectoryHardenedLocked()

        // Step 2: Encode candidate plaintext
        let data = try JSONEncoder().encode(values)

        // Step 3: Write temporary artifact in private secrets directory
        let tempURL = directoryURL.appendingPathComponent(".tmp_\(UUID().uuidString)")
        var swapSucceeded = false
        defer {
            if !swapSucceeded && fileManager.fileExists(atPath: tempURL.path) {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        try data.write(to: tempURL, options: [])

        // Step 4: Restrict temp artifact to 0600 and verify permissions
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        let fileAttrs = try fileManager.attributesOfItem(atPath: tempURL.path)
        if let perms = fileAttrs[.posixPermissions] as? NSNumber, (perms.intValue & 0o777) != 0o600 {
            throw CocoaError(.fileWriteNoPermission)
        }

        // Step 5: Atomically replace/move into canonical filename
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL, backupItemName: nil, options: [])
            swapSucceeded = true
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
            swapSucceeded = true
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

final class ProviderSecretStore: SecretStoring, @unchecked Sendable {
    private let vault: AppSecretFileVault

    init(storageRootURL: URL, fileManager: FileManager = .default) {
        vault = AppSecretFileVault(
            storageRootURL: storageRootURL,
            fileName: "provider-secrets.json",
            fileManager: fileManager
        )
    }

    static let versionKey = "__providerCredentialEnvelopeVersion"

    func migrateLegacy(providers: [ProviderConfiguration]) throws {
        let snapshot = try vault.snapshot()
        if let version = snapshot[Self.versionKey] {
            guard version == "1" else { throw ProviderCredentialStorageError.invalidSchema }
            for (key, raw) in snapshot where UUID(uuidString: key) != nil {
                _ = try decodeEnvelope(raw, providerID: UUID(uuidString: key)!)
            }
            return
        }
        try vault.backupForMigration()
        let modes = Dictionary(providers.map { ($0.id.uuidString, $0.authenticationMode) }, uniquingKeysWith: { first, _ in first })
        try vault.changeAtomically { values in
            guard values[Self.versionKey] == nil else { throw ProviderCredentialStorageError.concurrentIdentityChange }
            for (key, raw) in snapshot {
                guard let id = UUID(uuidString: key) else { continue }
                let mode = modes[key] == .azureAPIKey ? ProviderAuthenticationMode.azureAPIKey : .bearer
                let selection = ProviderAuthenticationSelection.legacy(mode)
                var envelope = ProviderCredentialEnvelope(providerID: id)
                envelope.set(ProviderCredentialSlot(apiKey: raw, acquisition: selection.acquisitionMethod), selection: selection)
                let encoded = try encodeEnvelope(envelope)
                guard try decodeEnvelope(encoded, providerID: id).slot(for: selection)?.apiKey == raw else {
                    throw ProviderCredentialStorageError.invalidRecord
                }
                values[key] = encoded
            }
            values[Self.versionKey] = "1"
        }
    }

    func save(_ value: String, providerID: UUID) throws {
        if try vault.snapshot()[Self.versionKey] == nil { try migrateLegacy(providers: []) }
        try saveKey(value, providerID: providerID, selection: .legacy(.bearer))
    }

    func saveKey(_ value: String, providerID: UUID, selection: ProviderAuthenticationSelection) throws {
        guard [.apiKey, .azureAPIKey].contains(selection.credentialKind) else {
            throw ProviderConnectionError.invalidCredentialRoute
        }
        try modifyEnvelope(providerID: providerID) { envelope in
            let next = (envelope.slot(for: selection)?.revision ?? 0) + 1
            envelope.set(ProviderCredentialSlot(apiKey: value, acquisition: selection.acquisitionMethod, revision: next), selection: selection)
        }
    }

    func slot(providerID: UUID, selection: ProviderAuthenticationSelection) throws -> ProviderCredentialSlot? {
        guard let raw = try readableValue(providerID: providerID) else { return nil }
        return try decodeEnvelope(raw, providerID: providerID).slot(for: selection)
    }

    func saveSlot(_ slot: ProviderCredentialSlot, providerID: UUID, selection: ProviderAuthenticationSelection,
                  expectedRevision: UInt64?) throws {
        try modifyEnvelope(providerID: providerID) { envelope in
            guard envelope.slot(for: selection)?.revision == expectedRevision else {
                throw ProviderCredentialStorageError.concurrentIdentityChange
            }
            envelope.set(slot, selection: selection)
        }
    }

    func logout(providerID: UUID, selection: ProviderAuthenticationSelection) throws {
        try modifyEnvelope(providerID: providerID) { $0.remove(selection: selection) }
    }

    /// Restore a failed metadata save only if this write still owns the selected slot.
    func restoreSlot(_ previous: ProviderCredentialSlot?, providerID: UUID,
                     selection: ProviderAuthenticationSelection, expectedRevision: UInt64) throws {
        try modifyEnvelope(providerID: providerID) { envelope in
            guard envelope.slot(for: selection)?.revision == expectedRevision else {
                throw ProviderCredentialStorageError.concurrentIdentityChange
            }
            if let previous { envelope.set(previous, selection: selection) }
            else { envelope.remove(selection: selection) }
        }
    }

    func load(providerID: UUID) throws -> String? {
        try slot(providerID: providerID, selection: .legacy(.bearer))?.apiKey
    }

    func delete(providerID: UUID) throws {
        try vault.removeValue(for: providerID.uuidString)
    }

    private func readableValue(providerID: UUID) throws -> String? {
        try vault.validateReadable()
        guard vault.value(for: Self.versionKey) == "1" else { throw ProviderCredentialStorageError.invalidSchema }
        return vault.value(for: providerID.uuidString)
    }

    private func modifyEnvelope(providerID: UUID, change: (inout ProviderCredentialEnvelope) throws -> Void) throws {
        try vault.changeAtomically { values in
            guard values[Self.versionKey] == "1" else { throw ProviderCredentialStorageError.invalidSchema }
            var envelope = try values[providerID.uuidString].map { try decodeEnvelope($0, providerID: providerID) }
                ?? ProviderCredentialEnvelope(providerID: providerID)
            try change(&envelope)
            values[providerID.uuidString] = try encodeEnvelope(envelope)
        }
    }

    private func encodeEnvelope(_ envelope: ProviderCredentialEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }

    private func decodeEnvelope(_ raw: String, providerID: UUID) throws -> ProviderCredentialEnvelope {
        let record = try JSONDecoder().decode(ProviderCredentialEnvelope.self, from: Data(raw.utf8))
        guard record.schemaVersion == 1, record.providerID == providerID else {
            throw ProviderCredentialStorageError.invalidRecord
        }
        return record
    }

}

typealias KeychainSecretStore = ProviderSecretStore
