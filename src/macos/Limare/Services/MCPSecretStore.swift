import Foundation
import Security
import LocalAuthentication

public struct MCPSecretRestoreFailure: Equatable, Sendable {
    public let account: String
    public let status: OSStatus

    public init(account: String, status: OSStatus) {
        self.account = account
        self.status = status
    }
}

public enum MCPSecretStoreError: LocalizedError, Equatable, Sendable {
    case unrecoverablePartialDeletion(serverID: String, failedAccount: String, deleteStatus: OSStatus, restoreFailures: [MCPSecretRestoreFailure])
    case operationFailed(status: OSStatus, message: String)
    case backupFailed(account: String, status: OSStatus)

    public var isUnrecoverableCredentialLoss: Bool {
        if case .unrecoverablePartialDeletion = self {
            return true
        }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case let .unrecoverablePartialDeletion(serverID, failedAccount, deleteStatus, restoreFailures):
            let failureList = restoreFailures.map { "\($0.account): \($0.status)" }.joined(separator: ", ")
            return "Failed to delete secret '\(failedAccount)' for server '\(serverID)' (status \(deleteStatus)), and restoring previously deleted secrets also failed (\(failureList))."
        case let .operationFailed(status, message):
            return "Keychain operation failed (status \(status)): \(message)"
        case let .backupFailed(account, status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
            return "Failed to read backup for secret '\(account)' (\(msg))"
        }
    }
}

/// Names of the per-server items in the MCP secret store (account `<serverID>:<key>`).
public enum MCPSecretKey {
    static func accountPrefix(serverID: String) -> String {
        let encoded = Data(serverID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "v1:\(encoded):"
    }
    static func account(serverID: String, key: String) -> String {
        accountPrefix(serverID: serverID) + Data(key.utf8).base64EncodedString()
    }
    static func belongsToServer(_ account: String, serverID: String) -> Bool {
        let parts = account.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, parts[0] == "v1" else { return false }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let namespace = String(data: data, encoding: .utf8) else { return false }
        return namespace.hasPrefix("b1.\(Data(serverID.utf8).base64EncodedString()).")
    }
    /// The key of an account in `serverID`'s namespace, or nil for another namespace.
    static func key(fromAccount account: String, serverID: String) -> String? {
        let prefix = accountPrefix(serverID: serverID)
        guard account.hasPrefix(prefix), let data = Data(base64Encoded: String(account.dropFirst(prefix.count))) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func header(_ name: String) -> String { "header.\(name)" }
    public static func env(_ name: String) -> String { "env.\(name)" }
    /// An unknown imported field held for Human review; never resolved into a connection.
    public static func quarantine(_ name: String) -> String { "quarantine.\(name)" }
    public static let authorizationHeaderName = "Authorization"
    public static let authorizationHeader = header(authorizationHeaderName)
    /// The SDK's `OAuthAccessToken` as JSON: access + refresh token, expiry, scopes, issuer, client_id.
    public static let oauthToken = "oauth.token"
    /// Client secret for a pre-registered OAuth app (`MCPOAuthSettings.clientId`).
    public static let oauthClientSecret = "oauth.clientSecret"
}

/// Public metadata only. Unknown is not evidence that a credential is absent.
public enum MCPCredentialPresence: Sendable, Equatable {
    case unknown
    case absent
    case present
}

public protocol MCPSecretStoring: Sendable {
    func saveSecret(_ value: String, serverID: String, key: String) throws
    func loadSecret(serverID: String, key: String) throws -> String?
    func deleteSecret(serverID: String, key: String) throws
    func deleteAllSecrets(serverID: String) throws
    func hasStoredSecrets(serverID: String) throws -> Bool
    /// Must not retrieve credential value data or allow authentication UI.
    func secretPresence(serverID: String, key: String) throws -> MCPCredentialPresence
    func deleteAllBindings(serverID: String) throws
    func hasBindings(serverID: String) throws -> Bool
    /// Keys stored in one namespace, from metadata only.
    func storedKeys(serverID: String) throws -> [String]
}

public extension MCPSecretStoring {
    func deleteAllBindings(serverID: String) throws { throw MCPHostControlError.unavailable }
    func hasBindings(serverID: String) throws -> Bool { throw MCPHostControlError.unavailable }
    func storedKeys(serverID: String) throws -> [String] { throw MCPHostControlError.unavailable }
    func secretPresence(serverID: String, key: String) throws -> MCPCredentialPresence {
        // Backends without a metadata API must not fall back to loadSecret.
        .unknown
    }
    func hasStoredSecrets(serverID: String) throws -> Bool {
        throw MCPHostControlError.unavailable
    }
}

public final class InMemoryMCPSecretStore: MCPSecretStoring, MCPControlRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var controlRecords: [MCPControlRecord: Data] = [:]

    public init() {}

    private func compositeKey(serverID: String, key: String) -> String {
        MCPSecretKey.account(serverID: serverID, key: key)
    }

    public func saveSecret(_ value: String, serverID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[compositeKey(serverID: serverID, key: key)] = value
    }

    public func loadSecret(serverID: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[compositeKey(serverID: serverID, key: key)]
    }

    public func deleteSecret(serverID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: compositeKey(serverID: serverID, key: key))
    }

    public func deleteAllSecrets(serverID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = MCPSecretKey.accountPrefix(serverID: serverID)
        let keysToRemove = storage.keys.filter { $0.hasPrefix(prefix) }
        for k in keysToRemove {
            storage.removeValue(forKey: k)
        }
    }

    public func hasStoredSecrets(serverID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let prefix = MCPSecretKey.accountPrefix(serverID: serverID)
        return storage.keys.contains(where: { $0.hasPrefix(prefix) })
    }

    public func secretPresence(serverID: String, key: String) throws -> MCPCredentialPresence {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.contains(compositeKey(serverID: serverID, key: key)) ? .present : .absent
    }
    public func deleteAllBindings(serverID: String) throws {
        lock.withLock {
            for key in storage.keys.filter({ MCPSecretKey.belongsToServer($0, serverID: serverID) }) { storage.removeValue(forKey: key) }
        }
    }
    public func hasBindings(serverID: String) throws -> Bool {
        lock.withLock { storage.keys.contains(where: { MCPSecretKey.belongsToServer($0, serverID: serverID) }) }
    }
    public func storedKeys(serverID: String) throws -> [String] {
        lock.withLock { storage.keys.compactMap { MCPSecretKey.key(fromAccount: $0, serverID: serverID) } }
    }
}

extension InMemoryMCPSecretStore {
    func readControlRecord(_ record: MCPControlRecord) throws -> Data? {
        lock.withLock { controlRecords[record] }
    }
    func writeControlRecord(_ data: Data, record: MCPControlRecord) throws {
        guard data.count <= record.maximumBytes else { throw MCPHostControlError.capacityExceeded }
        lock.withLock { controlRecords[record] = data }
    }
    func deleteControlRecord(_ record: MCPControlRecord) throws {
        _ = lock.withLock { controlRecords.removeValue(forKey: record) }
    }
}

public final class FileMCPSecretStore: MCPSecretStoring, @unchecked Sendable {
    private let vault: AppSecretFileVault

    public init(storageRootURL: URL, fileManager: FileManager = .default) {
        vault = AppSecretFileVault(
            storageRootURL: storageRootURL,
            fileName: "mcp-secrets.json",
            fileManager: fileManager
        )
    }

    private func account(serverID: String, key: String) -> String {
        "\(serverID):\(key)"
    }

    public func saveSecret(_ value: String, serverID: String, key: String) throws {
        try vault.setValue(value, for: account(serverID: serverID, key: key))
    }

    public func loadSecret(serverID: String, key: String) throws -> String? {
        vault.value(for: account(serverID: serverID, key: key))
    }

    public func deleteSecret(serverID: String, key: String) throws {
        try vault.removeValue(for: account(serverID: serverID, key: key))
    }

    public func deleteAllSecrets(serverID: String) throws {
        try vault.removeValues(withPrefix: "\(serverID):")
    }

    public func hasStoredSecrets(serverID: String) throws -> Bool {
        let prefix = "\(serverID):"
        let secrets = try vault.snapshot()
        return secrets.keys.contains(where: { $0.hasPrefix(prefix) })
    }

}

public final class KeychainMCPSecretStore: MCPSecretStoring, MCPControlRecordStoring, @unchecked Sendable {
    private let service: String
    private let controlService: String
    private let expectedApplicationIdentifier: String
    private let lock = NSLock()

    /// The frozen signed identity (Team MNV6M9LX23, bundle app.limare.Limare) that owns the records.
    public static let productApplicationIdentifier = "MNV6M9LX23.app.limare.Limare"

    /// Acceptance probes pass their own services so they never touch the product records.
    public init(service: String = "app.limare.Limare.mcp.credentials", controlService: String = "app.limare.Limare.mcp.control",
                expectedApplicationIdentifier: String = KeychainMCPSecretStore.productApplicationIdentifier,
                storageRootURL: URL? = nil, fileManager: FileManager = .default) {
        self.service = service
        self.controlService = controlService
        self.expectedApplicationIdentifier = expectedApplicationIdentifier
        // No implicit legacy reads, migration, or file/login-keychain fallback.
    }

    private func noninteractiveContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// Data Protection items belong to the signed application identifier. A process without it gets
    /// errSecMissingEntitlement on writes but notFound on reads, and a build signed under another Team
    /// sees a different, empty namespace. Either would read "no access" as "no record" (a first launch),
    /// so every operation is refused unless the process carries exactly Limare's identity.
    static let signedApplicationIdentifier: String? = {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil) as? String
    }()

    fileprivate func requireSignedIdentity() throws {
        guard Self.signedApplicationIdentifier == expectedApplicationIdentifier else {
            throw MCPSecretStoreError.operationFailed(status: errSecMissingEntitlement,
                message: "This build is not signed with Limare's application identifier.")
        }
    }

    private func account(serverID: String, key: String) -> String {
        MCPSecretKey.account(serverID: serverID, key: key)
    }

    public func secretPresence(serverID: String, key: String) throws -> MCPCredentialPresence {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        if metadataLookupHook == nil { try requireSignedIdentity() }
        #else
        try requireSignedIdentity()
        #endif
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(serverID: serverID, key: key),
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var attributes: CFTypeRef?
        #if DEBUG
        let status: OSStatus
        if let result = metadataLookupHook?(query) {
            status = result.0
            attributes = result.1 as CFDictionary?
        } else {
            status = SecItemCopyMatching(query as CFDictionary, &attributes)
        }
        #else
        let status = SecItemCopyMatching(query as CFDictionary, &attributes)
        #endif
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else {
            throw MCPSecretStoreError.operationFailed(status: status, message: "Credential metadata lookup failed.")
        }
        guard attributes is [String: Any] else {
            throw MCPSecretStoreError.operationFailed(status: errSecInternalComponent, message: "Unexpected credential metadata response.")
        }
        return .present
    }

    public func saveSecret(_ value: String, serverID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireSignedIdentity()

        let acc = account(serverID: serverID, key: key)
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        // Update in-place if item exists, preserving original item if update fails
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                let msg = SecCopyErrorMessageString(addStatus, nil) as String? ?? "Keychain error code \(addStatus)"
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: [NSLocalizedDescriptionKey: msg])
            }
            return
        }

        let msg = SecCopyErrorMessageString(updateStatus, nil) as String? ?? "Keychain error code \(updateStatus)"
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: msg])
    }

    public func loadSecret(serverID: String, key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        try requireSignedIdentity()

        let acc = account(serverID: serverID, key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error code \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw MCPHostControlError.invalidRecord
        }
        return value
    }

    public func deleteSecret(serverID: String, key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireSignedIdentity()

        let acc = account(serverID: serverID, key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error code \(status)"
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    #if DEBUG
    var controlIOHook: (@Sendable (String, MCPControlRecord, Data?) throws -> Data?)? = nil
    public var metadataLookupHook: (@Sendable ([String: Any]) -> (OSStatus, [String: Any]?))? = nil
    public var itemDeleteHook: (@Sendable (String, Int) -> OSStatus?)? = nil
    public var itemRestoreHook: (@Sendable (String, Int) -> OSStatus?)? = nil
    public var itemPresenceStatusHook: (@Sendable () -> OSStatus?)? = nil
    #endif

    public func deleteAllSecrets(serverID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireSignedIdentity()

        let prefix = MCPSecretKey.accountPrefix(serverID: serverID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecSuccess { return }
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error code \(status)"
            throw MCPSecretStoreError.operationFailed(status: status, message: msg)
        }

        let targetAccounts = items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }
        guard !targetAccounts.isEmpty else { return }

        // Back up existing data for each target account before deletion to guarantee rollback atomicity
        var backups: [(account: String, data: Data)] = []
        for acc in targetAccounts {
            let readQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
                kSecAttrService as String: service,
                kSecAttrAccount as String: acc,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var dataRes: CFTypeRef?
            let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &dataRes)
            if readStatus == errSecItemNotFound {
                continue
            }
            guard readStatus == errSecSuccess, let data = dataRes as? Data else {
                throw MCPSecretStoreError.backupFailed(account: acc, status: readStatus)
            }
            backups.append((account: acc, data: data))
        }

        var deletedAccounts: [String] = []
        for acc in targetAccounts {
            let delQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
                kSecAttrService as String: service,
                kSecAttrAccount as String: acc
            ]
            #if DEBUG
            let delStatus = itemDeleteHook?(acc, deletedAccounts.count) ?? SecItemDelete(delQuery as CFDictionary)
            #else
            let delStatus = SecItemDelete(delQuery as CFDictionary)
            #endif

            if delStatus == errSecSuccess || delStatus == errSecItemNotFound {
                deletedAccounts.append(acc)
            } else {
                // An account deletion failed! Roll back by re-adding all previously deleted items in this batch
                var restoreFailures: [(account: String, status: OSStatus)] = []
                for deletedAcc in deletedAccounts {
                    guard let backup = backups.first(where: { $0.account == deletedAcc }) else { continue }
                    let addQuery: [String: Any] = [
                        kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
                        kSecAttrService as String: service,
                        kSecAttrAccount as String: backup.account,
                        kSecValueData as String: backup.data,
                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    ]
                    #if DEBUG
                    let restoreStatus = itemRestoreHook?(backup.account, restoreFailures.count) ?? SecItemAdd(addQuery as CFDictionary, nil)
                    #else
                    let restoreStatus = SecItemAdd(addQuery as CFDictionary, nil)
                    #endif
                    if restoreStatus != errSecSuccess {
                        restoreFailures.append((account: backup.account, status: restoreStatus))
                    }
                }
                if !restoreFailures.isEmpty {
                    let structuredFailures = restoreFailures.map { MCPSecretRestoreFailure(account: $0.account, status: $0.status) }
                    throw MCPSecretStoreError.unrecoverablePartialDeletion(
                        serverID: serverID,
                        failedAccount: acc,
                        deleteStatus: delStatus,
                        restoreFailures: structuredFailures
                    )
                }
                let msg = SecCopyErrorMessageString(delStatus, nil) as String? ?? "Keychain error code \(delStatus)"
                throw MCPSecretStoreError.operationFailed(status: delStatus, message: msg)
            }
        }
    }

    public func hasStoredSecrets(serverID: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try requireSignedIdentity()

        let prefix = MCPSecretKey.accountPrefix(serverID: serverID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        #if DEBUG
        let status = itemPresenceStatusHook?() ?? SecItemCopyMatching(query as CFDictionary, &result)
        #else
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #endif
        if status == errSecItemNotFound {
            return false
        }
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error code \(status)"
            throw MCPSecretStoreError.operationFailed(status: status, message: message)
        }
        guard let items = result as? [[String: Any]] else {
            throw MCPSecretStoreError.operationFailed(status: errSecInternalComponent, message: "Unexpected Keychain credential lookup response.")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.contains(where: { $0.hasPrefix(prefix) })
    }
}

extension KeychainMCPSecretStore {
    private func bindingAccounts(serverID: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: noninteractiveContext(),
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw MCPSecretStoreError.operationFailed(status: status, message: "Credential binding lookup failed.")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { MCPSecretKey.belongsToServer($0, serverID: serverID) }
    }
    public func hasBindings(serverID: String) throws -> Bool {
        try requireSignedIdentity()
        return try lock.withLock { !(try bindingAccounts(serverID: serverID)).isEmpty }
    }
    public func storedKeys(serverID: String) throws -> [String] {
        try requireSignedIdentity()
        return try lock.withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: noninteractiveContext(),
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return [] }
            guard status == errSecSuccess, let items = result as? [[String: Any]] else {
                throw MCPSecretStoreError.operationFailed(status: status, message: "Credential slot lookup failed.")
            }
            return items.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap { MCPSecretKey.key(fromAccount: $0, serverID: serverID) } }
        }
    }
    public func deleteAllBindings(serverID: String) throws {
        try requireSignedIdentity()
        try lock.withLock {
            for account in try bindingAccounts(serverID: serverID) {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecUseDataProtectionKeychain as String: true,
                    kSecUseAuthenticationContext as String: noninteractiveContext(),
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                let status = SecItemDelete(query as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw MCPSecretStoreError.operationFailed(status: status, message: "Credential cleanup is incomplete.")
                }
            }
        }
    }

    /// The sole legacy read path. Never called by startup, connect or status.
    func readLegacySecret(serverID: String, key: String, consent: MCPHumanConsent) throws -> String? {
        guard consent.isValid else { throw MCPHostControlError.unavailable }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.limare.mcp",
            kSecAttrAccount as String: "\(serverID):\(key)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw MCPSecretStoreError.operationFailed(status: status, message: "Explicit legacy migration read failed.")
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw MCPHostControlError.invalidRecord
        }
        return value
    }

    private func controlQuery(_ record: MCPControlRecord) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecUseAuthenticationContext as String: noninteractiveContext(),
         kSecAttrService as String: controlService,
         kSecAttrAccount as String: record.rawValue]
    }

    func readControlRecord(_ record: MCPControlRecord) throws -> Data? {
        try lock.withLock {
            #if DEBUG
            if let hook = controlIOHook { return try hook("read", record, nil) }
            #endif
            try requireSignedIdentity()
            var query = controlQuery(record)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else {
                throw MCPSecretStoreError.operationFailed(status: status, message: "Control record read failed.")
            }
            guard let data = result as? Data, data.count <= record.maximumBytes else {
                throw MCPHostControlError.invalidRecord
            }
            return data
        }
    }

    func writeControlRecord(_ data: Data, record: MCPControlRecord) throws {
        guard data.count <= record.maximumBytes else { throw MCPHostControlError.capacityExceeded }
        try lock.withLock {
            #if DEBUG
            if let hook = controlIOHook { _ = try hook("write", record, data); return }
            #endif
            try requireSignedIdentity()
            let query = controlQuery(record)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else {
                throw MCPSecretStoreError.operationFailed(status: status, message: "Control record update failed.")
            }
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(add as CFDictionary, nil)
            guard result == errSecSuccess else {
                throw MCPSecretStoreError.operationFailed(status: result, message: "Control record save failed.")
            }
        }
    }

    func deleteControlRecord(_ record: MCPControlRecord) throws {
        try lock.withLock {
            #if DEBUG
            if let hook = controlIOHook { _ = try hook("delete", record, nil); return }
            #endif
            try requireSignedIdentity()
            let status = SecItemDelete(controlQuery(record) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw MCPSecretStoreError.operationFailed(status: status, message: "Control record deletion failed.")
            }
        }
    }
}
