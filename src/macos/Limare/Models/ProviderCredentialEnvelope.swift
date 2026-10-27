import Foundation

struct ProviderOAuthRegistration: Codable, Equatable, Sendable {
    var issuedClientID: String
    var issuer: String
    var subject: String
    var workspaceID: String?
    var grantedScopes: [String]
}

/// AppAuth's secure archive is the sole persisted token representation.
struct ProviderCredentialSlot: Codable, Equatable, Sendable {
    var revision: UInt64
    var acquisitionMethod: CredentialAcquisitionMethod
    var apiKey: String?
    var oauthStateArchive: Data?
    var oauthRegistration: ProviderOAuthRegistration?
    var providerMetadata: [String: String]

    init(apiKey: String, acquisition: CredentialAcquisitionMethod = .manualAPIKey, revision: UInt64 = 1) {
        self.revision = revision
        acquisitionMethod = acquisition
        self.apiKey = apiKey
        oauthStateArchive = nil
        oauthRegistration = nil
        providerMetadata = [:]
    }

    init(archive: Data, registration: ProviderOAuthRegistration, revision: UInt64) {
        self.revision = revision
        acquisitionMethod = .authorizationCodePKCE
        apiKey = nil
        oauthStateArchive = archive
        oauthRegistration = registration
        providerMetadata = [:]
    }
}

struct ProviderCredentialEnvelope: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var providerID: UUID
    // String keys preserve unknown future slot kinds, without treating them as usable credentials.
    var slots: [String: [String: ProviderCredentialSlot]] = [:]

    func slot(for selection: ProviderAuthenticationSelection) -> ProviderCredentialSlot? {
        slots[selection.credentialKind.rawValue]?[selection.authenticationIdentityID]
    }

    mutating func set(_ slot: ProviderCredentialSlot, selection: ProviderAuthenticationSelection) {
        var identities = slots[selection.credentialKind.rawValue] ?? [:]
        identities[selection.authenticationIdentityID] = slot
        slots[selection.credentialKind.rawValue] = identities
    }

    mutating func remove(selection: ProviderAuthenticationSelection) {
        slots[selection.credentialKind.rawValue]?.removeValue(forKey: selection.authenticationIdentityID)
        if slots[selection.credentialKind.rawValue]?.isEmpty == true {
            slots.removeValue(forKey: selection.credentialKind.rawValue)
        }
    }
}

enum ProviderCredentialStorageError: LocalizedError {
    case invalidSchema, invalidRecord, concurrentIdentityChange, credentialMissing
    var errorDescription: String? {
        switch self {
        case .invalidSchema: String(localized: "Credential storage has an unsupported or damaged format. Original secrets were preserved.")
        case .invalidRecord: String(localized: "The credential record is damaged. Original secrets were preserved.")
        case .concurrentIdentityChange: String(localized: "Authentication changed while the request was running. Its result was discarded.")
        case .credentialMissing: String(localized: "The selected authentication identity has no credential.")
        }
    }
}
