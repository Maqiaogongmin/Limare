import Foundation
import CryptoKit

/// Why a connection failed, decided where the typed error is known so the UI never re-parses messages.
enum MCPFailureKind: Sendable, Equatable {
    case authentication
    case forbidden
    case network
    case timeout
    case serverError
    case protocolError
    case processExited
    case credentialStorage
    case other
}

enum MCPServerStatus: Sendable, Equatable {
    case configSaved
    /// The connection sends a fixed Authorization header whose token has to be entered.
    case credentialRequired
    /// The server uses OAuth and has no usable token; the user has to sign in through the browser.
    case signInRequired
    /// A browser sign-in is in progress.
    case signingIn
    case connecting
    case connected(toolCount: Int)
    case failed(message: String, kind: MCPFailureKind = .other)
    case disconnected

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .configSaved: return "Config saved"
        case .credentialRequired: return "Credential required"
        case .signInRequired: return "Sign-in required"
        case .signingIn: return "Waiting for browser sign-in…"
        case .connecting: return "Connecting…"
        case .connected(let count): return "Connected (\(count) tool\(count == 1 ? "" : "s"))"
        case .failed(let msg, _): return "Failed: \(msg)"
        case .disconnected: return "Disconnected"
        }
    }
}

/// OAuth client settings for servers without dynamic client registration (Claude Code's `oauth` block).
/// Servers that support registration need none of this. A client secret never lives here: it is kept in
/// the secret store under `oauth.clientSecret`.
struct MCPOAuthSettings: Codable, Hashable, Sendable {
    var clientId: String?
    var callbackPort: Int?
}

/// A product profile fixes what a connection may be, so the generic Host never recognizes vendor
/// hostnames. A configuration without a profile is a generic server.
enum MCPServerProfile: String, Codable, Sendable, CaseIterable {
    /// GitHub's remote MCP server through the user's own GitHub App (authorization code + PKCE).
    case githubRemote = "github-remote"

    struct Contract: Sendable {
        let displayName: String
        let endpoint: String
        let headers: [String: String]
        /// Authorization server the OAuth adapter pins for this profile.
        let authorizationIssuer: String
        /// No dynamic registration: the user's own client ID (and secret) must be configured.
        let requiresPreRegisteredClient: Bool
        /// Signs in only through SDK OAuth, so it is offered only while OAuth is admitted.
        let requiresOAuth: Bool
    }

    /// Profiles a new connection may use in this build.
    static var available: [MCPServerProfile] { allCases.filter { !$0.contract.requiresOAuth || MCPStore.oauthAdmitted } }

    var contract: Contract {
        switch self {
        case .githubRemote:
            return Contract(
                displayName: "GitHub (own GitHub App)",
                endpoint: "https://api.githubcopilot.com/mcp/",
                headers: ["X-MCP-Readonly": "true", "X-MCP-Toolsets": "repos,issues,pull_requests,users,projects"],
                authorizationIssuer: "https://github.com/login/oauth",
                requiresPreRegisteredClient: true,
                requiresOAuth: true
            )
        }
    }

    func configuration(id: String) -> MCPServerConfig {
        MCPServerConfig(id: id, url: contract.endpoint, headers: contract.headers, profile: self)
    }

    /// The fixed endpoint and headers are the whole remote definition; anything else means the
    /// connection is not this profile. OAuth is the only authentication.
    func validate(_ config: MCPServerConfig) throws {
        guard config.url == contract.endpoint, config.command == nil, config.args == nil, config.env == nil,
              (config.headers ?? [:]) == contract.headers else {
            throw MCPTransportError.configurationError("The \(contract.displayName) profile fixes its endpoint and headers; static tokens are not supported.")
        }
    }
}

/// How a configuration change treats the pre-registered OAuth client secret. It is committed in the
/// same transaction as the configuration, never as a side write. A secret is removed with its client
/// ID: that retires the binding after commit (or the post-commit sweep drops an unreferenced one).
enum MCPSecretMutation: Sendable, Equatable {
    case unchanged
    case replace(String)
}

enum MCPTransportType: String, Codable, Sendable, CaseIterable {
    case stdio = "stdio"
    case http = "http"
}

struct MCPServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var note: String?
    var enabled: Bool
    var createdAt: Double?
    var updatedAt: Double?
    var credentialEpoch: UInt64? = nil
    var credentialBindingID: UUID? = nil

    var credentialStorageID: String {
        "b1.\(Data(id.utf8).base64EncodedString()).\(credentialBindingID?.uuidString ?? "legacy-\(credentialEpoch ?? 1)")"
    }

    /// Unrecognized imported fields that are inert scalars. Preserved for export; never interpreted.
    var extensions: [String: AnyCodable]? = nil
    /// Names of unrecognized imported fields that may carry credentials or change behaviour. Their
    /// values live only in this binding's credential namespace; the server cannot connect until a
    /// Human discards them.
    var quarantinedFields: [String]? = nil
    var requiresReview: Bool { !(quarantinedFields ?? []).isEmpty }
    /// nil is a generic server.
    var profile: MCPServerProfile? = nil

    /// Everything that decides where stored credentials are sent or which program receives them.
    /// A change retires the binding. Label, note, enabled, timeout and secret values do not.
    var credentialTarget: String {
        struct Target: Encodable {
            let url: String?, command: String?, args: [String]?, clientID: String?, env: [String: String], profile: String?
        }
        let publicEnv = (env ?? [:]).filter { !Self.isSensitiveKey($0.key) && !Self.isSecretReference($0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Target(url: url, command: command, args: args, clientID: oauth?.clientId,
                                                env: publicEnv, profile: profile?.rawValue))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // STDIO transport
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var startupTimeoutSeconds: Int?
    /// How long one tools/call may take (Codex's DEFAULT_TOOL_TIMEOUT); startup keeps its own 30 s.
    static let toolCallTimeoutSeconds = 300

    // HTTP transport
    var url: String?
    var headers: [String: String]?
    var oauth: MCPOAuthSettings?

    init(
        id: String,
        note: String? = nil,
        enabled: Bool = true,
        createdAt: Double? = nil,
        updatedAt: Double? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil,
        startupTimeoutSeconds: Int? = 30,
        url: String? = nil,
        headers: [String: String]? = nil,
        oauth: MCPOAuthSettings? = nil,
        profile: MCPServerProfile? = nil
    ) {
        self.profile = profile
        self.id = id
        self.note = note
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.command = command
        self.args = args
        self.env = env
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.url = url
        self.headers = headers
        self.oauth = oauth
    }

    var isHTTP: Bool { !(url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// Environment variables and headers whose values are stored credentials, with their slot keys.
    var credentialSlots: [(name: String, key: String, isHeader: Bool)] {
        let env = (env ?? [:]).compactMap { name, value in
            Self.extractSecretKey(from: value).map { (name: name, key: MCPSecretKey.env($0), isHeader: false) }
        }
        let headers = (headers ?? [:]).compactMap { name, value in
            Self.extractSecretKey(from: value).map { (name: name, key: MCPSecretKey.header($0), isHeader: true) }
        }
        return (env + headers).sorted { $0.name < $1.name }
    }
    var isSTDIO: Bool { !(command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

    /// A static `Authorization` header wins over OAuth, as in Claude Code: the user chose a fixed credential.
    var hasStaticAuthorizationHeader: Bool {
        headers?.keys.contains(where: { $0.caseInsensitiveCompare("Authorization") == .orderedSame }) == true
    }

    var transportType: MCPTransportType {
        if isHTTP { return .http }
        return .stdio
    }

    var transportSummary: String {
        if isHTTP { return url ?? "" }
        if isSTDIO {
            let argStr = (args ?? []).joined(separator: " ")
            return argStr.isEmpty ? (command ?? "") : "\(command ?? "") \(argStr)"
        }
        return "Not configured"
    }

    /// A deterministic revision token of non-sensitive configuration parameters.
    /// Excludes environment variables, headers, auth tokens, and secrets.
    var nonSecretConfigRevision: String {
        var parts: [String] = []
        parts.append("id:\(id)")
        parts.append("enabled:\(enabled)")
        parts.append("binding:\(credentialBindingID?.uuidString ?? "legacy")")
        if let note = note, !note.isEmpty {
            parts.append("note:\(note)")
        }
        parts.append("transport:\(transportType.rawValue)")
        if let command = command, !command.isEmpty {
            parts.append("command:\(command)")
        }
        if let args = args, !args.isEmpty {
            parts.append("args:\(args.joined(separator: "\u{1F}"))")
        }
        if let url = url, !url.isEmpty {
            parts.append("url:\(url)")
        }
        if let timeout = startupTimeoutSeconds {
            parts.append("timeout:\(timeout)")
        }
        if let profile { parts.append("profile:\(profile.rawValue)") }
        if let oauth {
            parts.append("oauth:\(oauth.clientId ?? ""):\(oauth.callbackPort.map(String.init) ?? "")")
        }
        if let env = env, !env.isEmpty {
            let sortedKeys = env.keys.sorted()
            var envParts: [String] = []
            for k in sortedKeys {
                let v = env[k] ?? ""
                if MCPServerConfig.isSensitiveKey(k) {
                    if MCPServerConfig.isSecretReference(v) {
                        envParts.append("\(k)=\(v)")
                    } else {
                        envParts.append("\(k)=<sensitive>")
                    }
                } else if MCPServerConfig.isSecretReference(v) {
                    envParts.append("\(k)=\(v)")
                } else {
                    envParts.append("\(k)=\(v)")
                }
            }
            parts.append("env:\(envParts.joined(separator: "\u{1E}"))")
        }
        if let headers = headers, !headers.isEmpty {
            let sortedKeys = headers.keys.sorted()
            var headerParts: [String] = []
            for k in sortedKeys {
                let v = headers[k] ?? ""
                if MCPServerConfig.isSensitiveKey(k) {
                    if MCPServerConfig.isSecretReference(v) {
                        headerParts.append("\(k)=\(v)")
                    } else {
                        headerParts.append("\(k)=<sensitive>")
                    }
                } else if MCPServerConfig.isSecretReference(v) {
                    headerParts.append("\(k)=\(v)")
                } else {
                    headerParts.append("\(k)=\(v)")
                }
            }
            parts.append("headers:\(headerParts.joined(separator: "\u{1E}"))")
        }

        let canonicalString = parts.joined(separator: "\u{1D}")
        let digest = SHA256.hash(data: Data(canonicalString.utf8))
        return String(digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - Secret Redaction & Keychain Reference Helpers

    static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        let keywords = ["key", "token", "secret", "auth", "password", "bearer", "credential", "private", "cookie"]
        for kw in keywords {
            if lower.contains(kw) { return true }
        }
        return false
    }

    static func isSecretReference(_ value: String) -> Bool {
        (value.hasPrefix("${secret:") || value.hasPrefix("${keychain:")) && value.hasSuffix("}")
    }

    static func makeSecretReference(key: String) -> String {
        "${secret:\(key)}"
    }

    static func extractSecretKey(from reference: String) -> String? {
        guard isSecretReference(reference) else { return nil }
        if reference.hasPrefix("${secret:") {
            let start = reference.index(reference.startIndex, offsetBy: 9)
            let end = reference.index(before: reference.endIndex)
            return String(reference[start..<end])
        } else if reference.hasPrefix("${keychain:") {
            let start = reference.index(reference.startIndex, offsetBy: 11)
            let end = reference.index(before: reference.endIndex)
            return String(reference[start..<end])
        }
        return nil
    }

    static func isKeychainReference(_ value: String) -> Bool {
        isSecretReference(value)
    }

    static func makeKeychainReference(key: String) -> String {
        "${keychain:\(key)}"
    }

    static func extractKeychainKey(from reference: String) -> String? {
        extractSecretKey(from: reference)
    }

    func redactedCopy() -> MCPServerConfig {
        var copy = self
        if let env = copy.env {
            var redactedEnv: [String: String] = [:]
            for (k, v) in env {
                if Self.isSensitiveKey(k) || Self.isKeychainReference(v) {
                    redactedEnv[k] = "[REDACTED]"
                } else {
                    redactedEnv[k] = v
                }
            }
            copy.env = redactedEnv
        }
        if let headers = copy.headers {
            var redactedHeaders: [String: String] = [:]
            for (k, v) in headers {
                if Self.isSensitiveKey(k) || Self.isKeychainReference(v) {
                    redactedHeaders[k] = "[REDACTED]"
                } else {
                    redactedHeaders[k] = v
                }
            }
            copy.headers = redactedHeaders
        }
        return copy
    }
}

struct MCPServersFile: Codable {
    var mcpServers: [String: MCPServerEntry]

    init(mcpServers: [String: MCPServerEntry] = [:]) {
        self.mcpServers = mcpServers
    }

    func redacted() -> MCPServersFile {
        var result: [String: MCPServerEntry] = [:]
        for (id, entry) in mcpServers {
            var redactedEntry = entry
            if let env = entry.env {
                var rEnv: [String: String] = [:]
                for (k, v) in env {
                    if MCPServerConfig.isSensitiveKey(k) || MCPServerConfig.isKeychainReference(v) {
                        rEnv[k] = "[REDACTED]"
                    } else {
                        rEnv[k] = v
                    }
                }
                redactedEntry.env = rEnv
            }
            if let headers = entry.headers {
                var rHeaders: [String: String] = [:]
                for (k, v) in headers {
                    if MCPServerConfig.isSensitiveKey(k) || MCPServerConfig.isKeychainReference(v) {
                        rHeaders[k] = "[REDACTED]"
                    } else {
                        rHeaders[k] = v
                    }
                }
                redactedEntry.headers = rHeaders
            }
            result[id] = redactedEntry
        }
        return MCPServersFile(mcpServers: result)
    }
}

struct MCPServerEntry: Codable {
    var note: String?
    var enabled: Bool?
    var createdAt: Double?
    var updatedAt: Double?
    var url: String?
    var headers: [String: String]?
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var startupTimeoutSeconds: Int?
    var oauth: MCPOAuthSettings?
    var profile: MCPServerProfile?
}
