import Foundation
import Observation
import CryptoKit

struct MCPCredentialRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let serverID: String
    let serverName: String
    let promptText: String
    let generation: Int
    /// The variable or header the value is for, shown as the field label.
    var credentialName = "Token"
}

@MainActor
@Observable
final class MCPStore {
    private(set) var servers: [MCPServerConfig] = []
    private(set) var statuses: [String: MCPServerStatus] = [:]
    private(set) var toolsByServer: [String: [MCPTool]] = [:]
    /// Each connected server's initialize `instructions`, discarded with its tool catalog.
    private(set) var instructionsByServer: [String: String] = [:]
    private(set) var pendingCredentialRequest: MCPCredentialRequest?
    private(set) var credentialPresenceByServer: [String: [String: MCPCredentialPresence]] = [:]
    /// Credential names the last connection attempt found without a stored value.
    private(set) var missingCredentials: [String: [String]] = [:]
    private(set) var authorityState: MCPAuthorityState = .storageUnavailable
    private(set) var configurationRevision: UInt64 = 0
    private(set) var operationReceipts: [MCPHostOperationReceipt] = []
    /// stdio and Streamable HTTP run on the pinned official SDK in deps/swift-sdk (blueprint §4, §21).
    nonisolated static let productionSDKAdmitted = true
    /// SDK OAuth stays closed until the official SDK meets the blueprint's OAuth gate items.
    nonisolated static let oauthAdmitted = false
    var runtimeAdmissionMessage: String? {
        Self.productionSDKAdmitted ? nil : "MCP protocol activation is gated on a qualified official Swift SDK release. Configuration is preserved."
    }

    @ObservationIgnored private var controlRecords: (any MCPControlRecordStoring)?
    @ObservationIgnored private var authorityLease: MCPAuthorityLease?
    @ObservationIgnored private var controlDocument = MCPHostConfigDocument()
    @ObservationIgnored private var operationJournal = MCPHostOperationJournal()
    @ObservationIgnored private var managementOperation: (id: UUID, digest: String)?
    @ObservationIgnored private var preparedConfigurationOperationID: UUID?

    @ObservationIgnored
    private var credentialPresenceTasks: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let logs: DebugLogStore
    @ObservationIgnored
    private let fileManager: FileManager
    @ObservationIgnored
    private let storageURL: URL
    @ObservationIgnored
    private let secretStore: any MCPSecretStoring
    @ObservationIgnored private let workspaceURLProvider: @MainActor () -> URL?

    @ObservationIgnored
    private var connections: [String: MCPConnection] = [:]
    @ObservationIgnored
    private var inProgressRefreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var runtimeOperationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var connectionGenerations: [String: Int] = [:]
    @ObservationIgnored
    private var discoveredGenerations: [String: Int] = [:]

    private struct QueuedCredentialRequest {
        let request: MCPCredentialRequest
        let continuation: CheckedContinuation<String?, Never>
        var id: UUID { request.id }
        var serverID: String { request.serverID }
        var generation: Int { request.generation }
    }


    @ObservationIgnored
    private var credentialQueue: [QueuedCredentialRequest] = []

    @ObservationIgnored
    var toolDiscoveryProvider: ((MCPServerConfig) async throws -> [MCPTool])?
    /// LocalAuthentication; acceptance fixtures inject a stand-in. Never reachable from the model.
    @ObservationIgnored
    var humanConsentProvider: MCPHumanConsent.Provider = { try await MCPHumanConsent.authorize(operationID: $0, reason: $1) }

    init(
        logs: DebugLogStore,
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        secretStore: (any MCPSecretStoring)? = nil,
        workspaceURLProvider: (@MainActor () -> URL?)? = nil
    ) {
        self.logs = logs
        self.fileManager = fileManager
        self.workspaceURLProvider = workspaceURLProvider ?? { nil }
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if DEBUG
        // Isolated UI test roots cannot inherit the production Keychain namespace.
        if secretStore == nil, let storageRootURL {
            guard case .valid = TestStorageBootstrap.validateStorageRoot(environment: [
                TestStorageBootstrap.uiTestModeKey: "1",
                TestStorageBootstrap.uiTestStorageRootKey: storageRootURL.path
            ]) else {
                self.secretStore = InMemoryMCPSecretStore()
                self.storageURL = root.appendingPathComponent("mcp_servers.json")
                authorityState = .storageUnavailable
                return
            }
            self.secretStore = InMemoryMCPSecretStore()
        } else { self.secretStore = secretStore ?? KeychainMCPSecretStore() }
        #else
        self.secretStore = secretStore ?? KeychainMCPSecretStore()
        #endif
        self.controlRecords = self.secretStore as? any MCPControlRecordStoring
        self.storageURL = root.appendingPathComponent("mcp_servers.json")
        if self.secretStore is KeychainMCPSecretStore {
            let nativeRoot = LimareStorage.applicationSupport.appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
            guard root.standardizedFileURL == nativeRoot.standardizedFileURL else {
                authorityState = .storageUnavailable
                return
            }
            do { authorityLease = try MCPAuthorityLease(directory: root.appendingPathComponent("mcp-host", isDirectory: true)) }
            catch MCPHostControlError.alreadyRunning { authorityState = .alreadyRunning; return }
            catch { authorityState = .storageUnavailable; return }
        }
        load()
    }

    var activeTools: [MCPTool] {
        servers.flatMap { currentDiscoveredTools(for: $0) }
    }

    var activeChatToolDefinitions: [ChatToolDefinition] {
        activeTools.map { $0.asChatToolDefinition() }
    }

    func currentToolContributions() -> [ExtensionContribution] {
        var contributions: [ExtensionContribution] = []
        for server in servers where server.enabled {
            let currentGen = connectionGenerations[server.id, default: 0]
            let tools = currentDiscoveredTools(for: server)

            for tool in tools {
                let version = ExtensionSourceVersion(value: server.nonSecretConfigRevision)
                let identity = ExtensionContributionIdentity(
                    kind: .mcp,
                    sourceID: server.id,
                    sourceVersion: version,
                    localID: tool.name
                )
                let origin = ExtensionContributionOrigin.mcpDiscovered(
                    serverID: server.id,
                    connectionGeneration: currentGen
                )
                let prereqs = ExtensionContributionPrerequisites.mcpDiscovered(
                    enabledIntent: true,
                    connectionGeneration: currentGen,
                    discoverySucceeded: true
                )
                let payload = ExtensionContributionPayload.toolDefinition(tool.asChatToolDefinition())
                contributions.append(ExtensionContribution(
                    identity: identity,
                    origin: origin,
                    prerequisites: prereqs,
                    payload: payload,
                    claim: .runtimeDerived
                ))
            }
        }
        return contributions
    }

    private func currentDiscoveredTools(for server: MCPServerConfig) -> [MCPTool] {
        guard server.enabled, statuses[server.id]?.isConnected == true,
              discoveredGenerations[server.id] == connectionGenerations[server.id, default: 0] else {
            return []
        }
        return toolsByServer[server.id] ?? []
    }

    /// The instructions of a server whose tools are currently offered (Claude Code's "MCP Server
    /// Instructions"); nil when it is not connected or sent none.
    func currentInstructions(for serverID: String) -> String? {
        guard let server = servers.first(where: { $0.id == serverID }), !currentDiscoveredTools(for: server).isEmpty,
              let text = instructionsByServer[serverID]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func handleUnexpectedStdioTermination(serverID: String, generation: Int, exitCode: Int32) {
        // Only a live session's death is handled here; a process that dies while connecting is
        // reported by the connect attempt, with the server's own (redacted) reason.
        guard connectionGenerations[serverID] == generation, discoveredGenerations[serverID] == generation,
              let server = servers.first(where: { $0.id == serverID }), server.enabled, !server.isHTTP else { return }
        // Revoke the dead generation before any in-flight discovery can publish.
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        _ = nextGeneration(for: serverID)
        // The mechanical exit code is sufficient; stderr can contain configured secrets.
        let reason = "MCP server process exited with code \(exitCode)."
        statuses[serverID] = .failed(message: reason, kind: .processExited)
        toolsByServer.removeValue(forKey: serverID)
        instructionsByServer.removeValue(forKey: serverID)
        discoveredGenerations.removeValue(forKey: serverID)
        if let connection = connections.removeValue(forKey: serverID) { Task { await connection.stop() } }
        logs.error("MCP", "Server '\(serverID)' \(reason)")
    }

    func simulateDiscoveryForTesting(serverID: String, generation: Int, tools: [MCPTool], instructions: String? = nil) {
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        connectionGenerations[serverID] = generation
        discoveredGenerations[serverID] = generation
        toolsByServer[serverID] = tools
        instructionsByServer[serverID] = instructions
        statuses[serverID] = .connected(toolCount: tools.count)
    }

    func simulateGenerationAdvanceForTesting(serverID: String, nextGeneration: Int) {
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        connectionGenerations[serverID] = nextGeneration
        statuses[serverID] = .connecting
    }

    func connectionGenerationForTesting(serverID: String) -> Int {
        connectionGenerations[serverID, default: 0]
    }

    func simulateUnexpectedStdioTerminationForTesting(serverID: String, generation: Int, exitCode: Int32 = 42) {
        handleUnexpectedStdioTermination(serverID: serverID, generation: generation, exitCode: exitCode)
    }

    /// What should happen next for a server, for the model and the user. Derived from typed state only.
    func nextAction(for serverID: String) -> String {
        guard let server = servers.first(where: { $0.id == serverID }) else { return "The server does not exist; read list." }
        if server.requiresReview { return "Imported fields await the user's review in Settings → MCP before the server can connect." }
        if !server.enabled { return "The server is disabled; enable it to connect." }
        switch status(for: serverID) {
        case .connected(let count):
            return count == 0 ? "Connected, but the server offers no tools." : "Connected; its tools are available in this conversation from the next turn."
        case .credentialRequired:
            let names = missingCredentials[serverID] ?? server.credentialSlots.map(\.name)
            return names.isEmpty
                ? "Call authenticate: Limare asks the user for an access token in its own secure prompt."
                : "Call authenticate: Limare asks the user for \(names.joined(separator: ", ")) in its own secure prompt. Never ask for the value in the conversation."
        case .failed(_, .processExited):
            return "The server program did not start; read its error. If the program is not installed, give the user the install command to run in Terminal (mcp_manage does not install server programs). If it needs a token, add it as a reference with patch and call authenticate. Then call reconnect."
        case .failed(_, .authentication), .failed(_, .forbidden):
            return "The server rejected the credential. Call authenticate so the user can enter a new one."
        case .failed:
            return "Read the error, fix the configuration with patch if needed, then call reconnect."
        case .connecting, .signingIn:
            return "Connecting; read status again shortly."
        case .configSaved, .disconnected, .signInRequired:
            return "Call reconnect to connect."
        }
    }

    /// The frozen runtime projection (blueprint §13), derived from typed Host state. A stored token
    /// is not authentication: `authenticated` needs the server to have accepted the committed
    /// credential in the current generation. Identity verification is not offered in this phase.
    func runtimeProjection(for serverID: String) -> (transport: String, auth: String, identity: String) {
        let server = servers.first(where: { $0.id == serverID })
        let status = status(for: serverID)
        let transport: String
        switch status {
        case .connected: transport = "ready"
        case .connecting, .signingIn: transport = "connecting"
        case .failed: transport = "failed"
        case .configSaved, .credentialRequired, .signInRequired, .disconnected: transport = "disconnected"
        }
        let credentialed = server?.hasStaticAuthorizationHeader == true
            || (server?.env ?? [:]).contains { MCPServerConfig.isSecretReference($0.value) }
        let auth: String
        switch status {
        case .credentialRequired, .signInRequired: auth = "signInRequired"
        case .signingIn: auth = "signingIn"
        case .failed(_, .authentication), .failed(_, .forbidden): auth = "authFailed"
        case .connected: auth = credentialed ? "authenticated" : "anonymous"
        default: auth = credentialed ? "signInRequired" : "anonymous"
        }
        return (transport, auth, "unsupported")
    }

    func status(for serverID: String) -> MCPServerStatus {
        statuses[serverID] ?? .disconnected
    }

    /// Settings reads this immutable metadata projection, never the secret backend.
    func credentialPresence(serverID: String, key: String) -> MCPCredentialPresence {
        credentialPresenceByServer[serverID]?[key] ?? .unknown
    }

    private func refreshCredentialPresence(for serverID: String) {
        credentialPresenceTasks[serverID]?.cancel()
        guard servers.contains(where: { $0.id == serverID }) else {
            credentialPresenceTasks.removeValue(forKey: serverID)
            credentialPresenceByServer.removeValue(forKey: serverID)
            return
        }
        let backend = secretStore
        let namespace = credentialNamespace(for: serverID)
        let keys = [MCPSecretKey.oauthToken, MCPSecretKey.oauthClientSecret]
        let lookup = Task.detached {
            var snapshot: [String: MCPCredentialPresence] = [:]
            for key in keys {
                do {
                    snapshot[key] = try backend.secretPresence(serverID: namespace, key: key)
                } catch {
                    snapshot[key] = .unknown
                }
            }
            return snapshot
        }
        credentialPresenceTasks[serverID] = Task { [weak self] in
            let snapshot = await lookup.value
            guard !Task.isCancelled, let self,
                  self.servers.contains(where: { $0.id == serverID }) else { return }
            self.credentialPresenceByServer[serverID] = snapshot
            self.credentialPresenceTasks.removeValue(forKey: serverID)
        }
    }

    func tools(for serverID: String) -> [MCPTool] {
        toolsByServer[serverID] ?? []
    }

    func resolvedServer(id: String) -> MCPServerConfig? {
        guard let server = servers.first(where: { $0.id == id }) else { return nil }
        return try? Self.resolveSecrets(in: server, using: secretStore)
    }

    func setServerStatus(_ status: MCPServerStatus, for serverID: String) {
        statuses[serverID] = status
    }

    // MARK: - Credential Request Lifecycle

    func requestCredential(
        serverID: String,
        serverName: String,
        promptText: String,
        credentialName: String = "Token",
        timeoutSeconds: TimeInterval = MCPOAuth.interactiveTimeoutSeconds
    ) async -> String? {
        let id = UUID()
        let currentGen = connectionGenerations[serverID, default: 0]
        let request = MCPCredentialRequest(
            id: id,
            serverID: serverID,
            serverName: serverName,
            promptText: promptText,
            generation: currentGen,
            credentialName: credentialName
        )

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            self?.cancelQueuedCredentialRequest(id: id)
        }

        let token = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                self.enqueueCredentialRequest(request, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueuedCredentialRequest(id: id)
            }
        }

        timeoutTask.cancel()
        return token
    }

    private func enqueueCredentialRequest(_ request: MCPCredentialRequest, continuation: CheckedContinuation<String?, Never>) {
        credentialQueue.append(QueuedCredentialRequest(request: request, continuation: continuation))
        if pendingCredentialRequest == nil {
            pendingCredentialRequest = request
        }
    }

    func resolveCredentialRequest(id: UUID, credential: String?) {
        guard let index = credentialQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = credentialQueue.remove(at: index)
        let currentGen = connectionGenerations[item.serverID, default: 0]
        guard item.generation == currentGen else {
            logs.error("MCP", "Credential request \(id) rejected: generation \(item.generation) does not match active generation \(currentGen)")
            item.continuation.resume(returning: nil)
            advanceCredentialQueue()
            return
        }
        // The requester commits the value through the configuration authority.
        item.continuation.resume(returning: credential)
        advanceCredentialQueue()
    }

    func cancelQueuedCredentialRequest(id: UUID) {
        guard let index = credentialQueue.firstIndex(where: { $0.id == id }) else { return }
        let item = credentialQueue.remove(at: index)
        item.continuation.resume(returning: nil)
        advanceCredentialQueue()
    }

    func cancelAllCredentialRequests() {
        let queue = credentialQueue
        credentialQueue.removeAll()
        for item in queue {
            item.continuation.resume(returning: nil)
        }
        pendingCredentialRequest = nil
    }

    private func advanceCredentialQueue() {
        if let next = credentialQueue.first {
            pendingCredentialRequest = next.request
        } else {
            pendingCredentialRequest = nil
        }
    }

    /// Commits a generic bearer credential into the server's current binding: journal intent,
    /// candidate secret, configuration commit. Never a side write outside the authority.
    private func saveAuthorizationBearerToken(_ token: String, serverID: String, authorization: MCPHumanConsent) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var server = servers.first(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
        var headers = server.headers ?? [:]
        headers[MCPSecretKey.authorizationHeaderName] = trimmed.lowercased().hasPrefix("bearer ") ? trimmed : "Bearer \(trimmed)"
        server.headers = headers
        try addOrUpdate(server, authorization: authorization)
    }

    private func credentialNamespace(for serverID: String) -> String {
        servers.first(where: { $0.id == serverID })?.credentialStorageID
            ?? MCPServerConfig(id: serverID).credentialStorageID
    }

    func hasAuthorizationSecret(serverID: String) throws -> Bool {
        switch try secretStore.secretPresence(serverID: credentialNamespace(for: serverID), key: MCPSecretKey.authorizationHeader) {
        case .present: return true
        case .absent: return false
        case .unknown: throw MCPHostControlError.unavailable
        }
    }

    func hasStoredSecrets(serverID: String) throws -> Bool {
        try secretStore.hasBindings(serverID: serverID)
    }

    @discardableResult
    private func nextGeneration(for serverID: String) -> Int {
        let next = (connectionGenerations[serverID] ?? 0) + 1
        connectionGenerations[serverID] = next
        return next
    }

    /// Rejects configurations that put credentials where they would be stored in plain text or shown to
    /// the model (id, command, arguments, URL, note). Credentials belong in headers or env, which go to the
    /// secret store. Credential formats come from `SecretMasker`, the single registry.
    nonisolated static func validate(_ config: MCPServerConfig) throws {
        // Bounded so the fixed-capacity control records can always hold their receipts.
        guard !config.id.isEmpty, config.id.utf8.count <= 128,
              !config.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MCPTransportError.configurationError("Server ID must be 1-128 bytes without control characters.")
        }
        if SecretMasker.containsCredential(config.id) {
            throw MCPTransportError.configurationError("Server ID cannot contain sensitive credentials.")
        }
        if let cmd = config.command, SecretMasker.containsCredential(cmd) {
            throw MCPTransportError.configurationError("Command cannot contain sensitive credentials.")
        }
        if let args = config.args, args.contains(where: SecretMasker.containsCredential) {
            throw MCPTransportError.configurationError("Command arguments cannot contain sensitive credentials. Put them in environment variables.")
        }
        if let note = config.note, SecretMasker.containsCredential(note) {
            throw MCPTransportError.configurationError("The note cannot contain credentials.")
        }
        if let urlStr = config.url {
            guard let components = URLComponents(string: urlStr),
                  let scheme = components.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  components.host != nil else {
                throw MCPTransportError.invalidURL("A valid http or https URL is required.")
            }
            if components.user != nil || components.password != nil || SecretMasker.containsCredential(urlStr) {
                throw MCPTransportError.invalidURL("URLs must not carry credentials. Put a token in the Authorization header, or sign in.")
            }
            let hasCredentialHeader = config.headers?.contains(where: { MCPServerConfig.isSensitiveKey($0.key) || MCPServerConfig.isSecretReference($0.value) }) == true
            if scheme == "http", hasCredentialHeader,
               !["localhost", "127.0.0.1", "::1", "[::1]"].contains(components.host?.lowercased() ?? "") {
                throw MCPTransportError.invalidURL("Credential-bearing remote MCP connections require HTTPS.")
            }
        }
        try config.profile?.validate(config)
    }

    // MARK: - Secret Canonicalization & Collection

    private struct SecretRollbackAction {
        let serverID: String
        let key: String
        let priorValue: String?
    }

    private func collectSecrets(for serverID: String) async -> [String] {
        guard let server = servers.first(where: { $0.id == serverID }) else { return [] }
        let store = secretStore
        return await Task.detached(priority: .userInitiated) {
            var list: [String] = []
            for (key, value) in server.env ?? [:] {
                if let reference = MCPServerConfig.extractKeychainKey(from: value),
                   let secret = try? store.loadSecret(serverID: server.credentialStorageID, key: MCPSecretKey.env(reference)) {
                    list.append(secret)
                } else if MCPServerConfig.isSensitiveKey(key), !MCPServerConfig.isSecretReference(value), !value.isEmpty {
                    list.append(value)
                }
            }
            for (key, value) in server.headers ?? [:] {
                if let reference = MCPServerConfig.extractKeychainKey(from: value),
                   let secret = try? store.loadSecret(serverID: server.credentialStorageID, key: MCPSecretKey.header(reference)) {
                    list.append(secret)
                } else if MCPServerConfig.isSensitiveKey(key), !MCPServerConfig.isSecretReference(value), !value.isEmpty {
                    list.append(value)
                }
            }
            return list.filter { !$0.isEmpty }
        }.value
    }

    // MARK: - Refresh Task Lifecycle Launcher

    @discardableResult
    private func startRefreshTask(for serverID: String, generation: Int) -> Task<Void, Never> {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshTools(for: serverID, generation: generation)
            // Clean up inProgressRefreshTasks if this generation is still current
            if self.connectionGenerations[serverID, default: 0] == generation {
                self.inProgressRefreshTasks.removeValue(forKey: serverID)
            }
        }
        inProgressRefreshTasks[serverID] = task
        return task
    }

    // MARK: - CRUD

    nonisolated static func commandDigest(action: String, serverID: String, expectedRevision: UInt64,
                                          config: MCPServerConfig? = nil, patch: MCPConfigurationPatch? = nil) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fingerprint = Data("\(action)\u{0}\(serverID)\u{0}\(expectedRevision)\u{0}".utf8)
        if let config { fingerprint.append(try encoder.encode(config)) }
        if let patch { fingerprint.append(try encoder.encode(patch)) }
        return SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }

    /// The receipt as delivered: a committed configuration whose credential retirement or receipt
    /// write is still owed is committed, with recovery pending.
    func reportedReceipt(_ id: UUID) -> MCPHostOperationReceipt? {
        guard var receipt = operationJournal.receipt(id) else { return nil }
        if receipt.outcome == .pending, receipt.action == nil, controlDocument.lastCommitOperationID == id {
            receipt.outcome = .committed
            receipt.recoveryPending = true
        }
        return receipt
    }

    /// Definition fields an Agent patch may set or remove; identity, enablement and profile are not among them.
    nonisolated static let patchableFields: Set<String> = ["note", "command", "args", "env", "startupTimeoutSeconds", "url", "headers", "oauth"]

    /// The sole revision/idempotency boundary for public Agent configuration mutations.
    @discardableResult
    func applyManagementMutation(action: String, serverID: String, expectedRevision: UInt64,
                                 requestID: UUID, config: MCPServerConfig? = nil,
                                 patch: MCPConfigurationPatch? = nil) throws -> MCPHostOperationReceipt {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = try Self.commandDigest(action: action, serverID: serverID, expectedRevision: expectedRevision,
                                            config: config, patch: patch)
        // A replay reports the recorded outcome; it never executes the command again.
        if operationJournal.receipt(requestID) != nil {
            guard operationJournal.receipt(requestID)?.commandDigest == digest, let receipt = reportedReceipt(requestID) else {
                throw MCPHostControlError.revisionConflict
            }
            return receipt
        }
        guard authorityState == .ready, configurationRevision == expectedRevision else {
            throw MCPHostControlError.revisionConflict
        }
        managementOperation = (requestID, digest)
        defer { managementOperation = nil }
        switch action {
        case "create":
            guard let config, config.id == serverID, !servers.contains(where: { $0.id == serverID }) else {
                throw MCPHostControlError.revisionConflict
            }
            try addOrUpdate(config)
        case "patch":
            guard let current = servers.first(where: { $0.id == serverID }), let patch else {
                throw MCPTransportError.unknownServer(serverID)
            }
            let allowed = Self.patchableFields
            guard patch.set.keys.allSatisfy(allowed.contains), patch.remove.allSatisfy({ allowed.contains($0.components(separatedBy: ".")[0]) }) else {
                throw MCPTransportError.configurationError("Unsupported MCP patch field.")
            }
            var object = try JSONSerialization.jsonObject(with: encoder.encode(current)) as! [String: Any]
            let values = try JSONSerialization.jsonObject(with: encoder.encode(patch.set)) as! [String: Any]
            for (key, value) in values {
                guard !(value is NSNull) else { throw MCPTransportError.configurationError("Use remove for explicit field deletion.") }
                if key == "oauth" {
                    guard let fields = value as? [String: Any], Set(fields.keys).isSubset(of: ["clientId"]) else {
                        throw MCPTransportError.configurationError("OAuth patches accept only the public client ID.")
                    }
                }
                if key == "env" || key == "headers" {
                    guard let supplied = value as? [String: String] else { throw MCPHostControlError.invalidRecord }
                    var merged = object[key] as? [String: String] ?? [:]
                    for (name, value) in supplied {
                        guard (!MCPServerConfig.isSensitiveKey(name) && !SecretMasker.containsCredential(value)) || MCPServerConfig.isSecretReference(value) else {
                            throw MCPTransportError.configurationError("Agent patches require credential references, never values.")
                        }
                        merged[name] = value
                    }
                    object[key] = merged
                } else { object[key] = value }
            }
            for field in patch.remove {
                let parts = field.split(separator: ".", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "env" || parts[0] == "headers" {
                    var entries = object[parts[0]] as? [String: String] ?? [:]
                    entries.removeValue(forKey: parts[1]); object[parts[0]] = entries
                } else if parts.count == 1 { object.removeValue(forKey: field) }
                else { throw MCPTransportError.configurationError("Invalid MCP patch remove path.") }
            }
            let updated = try JSONDecoder().decode(MCPServerConfig.self, from: JSONSerialization.data(withJSONObject: object))
            try addOrUpdate(updated)
        case "enable", "disable":
            guard var current = servers.first(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
            current.enabled = action == "enable"
            try addOrUpdate(current)
        case "remove":
            guard servers.contains(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
            try delete(id: serverID)
        default: throw MCPTransportError.configurationError("Unsupported MCP mutation.")
        }
        guard let receipt = reportedReceipt(requestID), receipt.outcome == .committed else {
            throw MCPHostControlError.unavailable
        }
        return receipt
    }

    /// Whether a runtime action applies to this server; checked before anyone is asked to approve it.
    func validateRuntimeAction(_ action: String, serverID: String) throws {
        guard ["reconnect", "authenticate", "logout"].contains(action) else {
            throw MCPTransportError.configurationError("Unsupported MCP runtime action.")
        }
        guard let server = servers.first(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
        if action == "authenticate", !server.isHTTP, server.credentialSlots.isEmpty {
            throw MCPTransportError.configurationError("'\(serverID)' references no stored credentials. Patch its env with a reference such as {\"NAME\": \"${secret:NAME}\"} first; authenticate then asks the user for the value.")
        }
        if action == "logout", !usesOAuth(serverID: server.id) {
            throw MCPTransportError.configurationError("'\(serverID)' does not use OAuth sign-in.")
        }
    }

    /// The one entry for reconnect, authenticate and logout, from Settings and from mcp_manage alike.
    /// Authentication becomes a Host-owned operation: the caller gets its pending receipt, and a replay
    /// never opens a second prompt or browser. Its Human ticket is bound to this request ID.
    func performRuntimeAction(_ action: String, serverID: String, expectedRevision: UInt64,
                              requestID: UUID) async throws -> MCPHostOperationReceipt {
        let digest = try Self.commandDigest(action: action, serverID: serverID, expectedRevision: expectedRevision)
        if let previous = operationJournal.receipt(requestID) {
            guard previous.commandDigest == digest else { throw MCPHostControlError.revisionConflict }
            return previous
        }
        guard authorityState == .ready, configurationRevision == expectedRevision else {
            throw MCPHostControlError.revisionConflict
        }
        try validateRuntimeAction(action, serverID: serverID)
        guard let controlRecords, operationJournal.activeOperations.count < 8 else { throw MCPHostControlError.unavailable }
        var journal = operationJournal
        journal.activeOperations.append(MCPHostOperationReceipt(id: requestID, createdAt: Date(), outcome: .pending,
            targetRevision: configurationRevision, commandDigest: digest, action: action, serverID: serverID))
        journal.journalRevision += 1
        try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
        operationJournal = journal
        operationReceipts = journal.terminalReceipts + journal.activeOperations

        switch action {
        case "reconnect":
            await reconnect(serverID: serverID)
            finishRuntimeOperation(requestID, outcome: .committed)
        case "logout":
            if await signOut(serverID: serverID) {
                finishRuntimeOperation(requestID, outcome: .committed)
            } else {
                finishRuntimeOperation(requestID, outcome: .notCommitted, safeError: "The stored credential could not be removed.")
            }
        default:
            runtimeOperationTasks[requestID] = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.authenticate(serverID: serverID, operationID: requestID)
                    self.finishRuntimeOperation(requestID, outcome: .committed)
                } catch MCPOAuthError.cancelled {
                    self.finishRuntimeOperation(requestID, outcome: .notCommitted, safeError: "Cancelled or timed out by the user.")
                } catch MCPOAuthError.credentialNotCommitted {
                    self.finishRuntimeOperation(requestID, outcome: .outcomeUnknown,
                        safeError: MCPOAuthError.credentialNotCommitted.localizedDescription)
                } catch {
                    self.finishRuntimeOperation(requestID, outcome: .notCommitted,
                        safeError: SecretMasker.redact(error.localizedDescription, secrets: []))
                }
                self.runtimeOperationTasks.removeValue(forKey: requestID)
            }
        }
        return operationJournal.receipt(requestID) ?? journal.activeOperations.last!
    }

    private func finishRuntimeOperation(_ id: UUID, outcome: MCPHostOperationReceipt.Outcome, safeError: String? = nil) {
        guard let controlRecords else { return }
        var journal = operationJournal
        journal.finish(id, outcome: outcome, safeError: safeError)
        do {
            try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
            operationJournal = journal
            operationReceipts = journal.terminalReceipts + journal.activeOperations
        } catch {
            // Restart reports the interrupted action as outcomeUnknown; never as completed.
            authorityState = .recoveryRequired
            logs.error("MCP", "Runtime operation receipt could not be recorded; recovery is required.")
        }
    }

    /// Re-runs startup reconciliation against the durable records. No file or empty fallback.
    func retryRecovery() {
        guard authorityState == .recoveryRequired else { return }
        for id in servers.map(\.id) { purgeRuntimeState(for: id) }
        load()
    }

    /// The definition as it will be stored: `<stored secret>` placeholders keep the current references.
    private func canonicalized(_ server: MCPServerConfig) -> MCPServerConfig {
        let old = servers.first(where: { $0.id == server.id })
        func normalized(_ entries: [String: String]?, old: [String: String]?) -> [String: String]? {
            guard var result = entries else { return nil }
            for (key, value) in result where value == "<stored secret>" {
                result[key] = old?[key]
            }
            return result.isEmpty ? nil : result
        }
        var canonical = server
        canonical.env = normalized(server.env, old: old?.env)
        canonical.headers = normalized(server.headers, old: old?.headers)
        return canonical
    }

    /// Whether committing this change adds or replaces a credential value, which needs a Human ticket.
    private nonisolated static func writesCredential(_ canonical: MCPServerConfig, quarantinedValues: [String: String],
                                                     clientSecret: MCPSecretMutation) -> Bool {
        if !quarantinedValues.isEmpty { return true }
        if case .replace = clientSecret { return true }
        return [canonical.env ?? [:], canonical.headers ?? [:]].contains { entries in
            entries.contains { MCPServerConfig.isSensitiveKey($0.key) && !MCPServerConfig.isSecretReference($0.value) }
        }
    }

    private nonisolated static func validateClientSecret(_ clientSecret: MCPSecretMutation, for canonical: MCPServerConfig) throws {
        if case .replace = clientSecret, canonical.oauth?.clientId?.isEmpty != false {
            throw MCPTransportError.configurationError("A client secret needs the OAuth client ID it belongs to.")
        }
    }

    /// Human configuration save (Settings): definition and client secret commit as one transaction.
    /// A new or replaced credential is confirmed through LocalAuthentication first, for this operation only.
    func saveConfiguration(_ server: MCPServerConfig, clientSecret: MCPSecretMutation = .unchanged) async throws {
        guard authorityState == .ready else { throw MCPHostControlError.unavailable }
        let canonical = canonicalized(server)
        try Self.validate(canonical)
        try Self.validateClientSecret(clientSecret, for: canonical)
        var ticket: MCPHumanConsent?
        if Self.writesCredential(canonical, quarantinedValues: [:], clientSecret: clientSecret) {
            ticket = try await humanConsentProvider(UUID(), "Save credentials for the MCP connection “\(server.id)”.")
        }
        try addOrUpdate(server, clientSecret: clientSecret, authorization: ticket)
    }

    /// `quarantinedValues` are unknown imported fields held only in the binding's credential namespace.
    /// `authorization` is the Human ticket of the operation that supplies new credential values; Agent
    /// mutations carry references only and never need one.
    func addOrUpdate(_ server: MCPServerConfig, quarantinedValues: [String: String] = [:],
                     clientSecret: MCPSecretMutation = .unchanged, authorization: MCPHumanConsent? = nil) throws {
        guard authorityState == .ready else { throw MCPHostControlError.unavailable }
        let oldConfig = servers.first(where: { $0.id == server.id })

        // Transactional secret writes with rollback tracking
        var rollbackActions: [SecretRollbackAction] = []
        var canonical = canonicalized(server)
        if !quarantinedValues.isEmpty {
            canonical.quarantinedFields = Set((canonical.quarantinedFields ?? []) + quarantinedValues.keys).sorted()
        }
        // Only a change of where credentials go retires them; replacing one secret keeps the others.
        let rebind = oldConfig.map { $0.credentialTarget != canonical.credentialTarget } ?? true
        canonical.credentialEpoch = (oldConfig?.credentialEpoch ?? 1) + (oldConfig != nil && rebind ? 1 : 0)
        canonical.credentialBindingID = rebind ? UUID() : oldConfig?.credentialBindingID
        let retiredNamespaces = rebind ? oldConfig.map { [$0.credentialStorageID] } ?? [] : []

        func rollback() {
            for action in rollbackActions.reversed() {
                if let prior = action.priorValue {
                    do { try secretStore.saveSecret(prior, serverID: action.serverID, key: action.key) }
                    catch { authorityState = .recoveryRequired }
                } else {
                    do { try secretStore.deleteSecret(serverID: action.serverID, key: action.key) }
                    catch { authorityState = .recoveryRequired }
                }
            }
        }

        // 0. Credentials only ever go to the secret store, and only with the user's confirmation
        try Self.validate(canonical)
        if let profile = canonical.profile, profile != oldConfig?.profile, !MCPServerProfile.available.contains(profile) {
            throw MCPTransportError.configurationError("The \(profile.contract.displayName) profile signs in with OAuth, which this Limare version does not support yet.")
        }
        try Self.validateClientSecret(clientSecret, for: canonical)
        if Self.writesCredential(canonical, quarantinedValues: quarantinedValues, clientSecret: clientSecret) {
            guard authorization?.isValid == true else { throw MCPHostControlError.humanConfirmationRequired }
        }
        guard let controlRecords, operationJournal.activeOperations.count < 8 else { throw MCPHostControlError.unavailable }
        let preparedID = managementOperation?.id ?? UUID()
        var preparedJournal = operationJournal
        preparedJournal.activeOperations.append(MCPHostOperationReceipt(id: preparedID, createdAt: Date(), outcome: .pending,
            targetRevision: configurationRevision + 1, commandDigest: managementOperation?.digest,
            candidateCredentialNamespace: rebind ? canonical.credentialStorageID : nil, serverID: server.id))
        preparedJournal.journalRevision += 1
        try controlRecords.writeControlRecord(JSONEncoder().encode(preparedJournal), record: .journal)
        operationJournal = preparedJournal
        operationReceipts = preparedJournal.terminalReceipts + preparedJournal.activeOperations
        preparedConfigurationOperationID = preparedID
        defer {
            if controlDocument.lastCommitOperationID != preparedID {
                do {
                    if rebind { try secretStore.deleteAllSecrets(serverID: canonical.credentialStorageID) }
                    try finishConfigurationOperation(preparedID, outcome: .notCommitted)
                } catch { authorityState = .recoveryRequired }
            }
            preparedConfigurationOperationID = nil
        }

        func storeSecret(_ value: String, key: String) throws {
            let namespace = canonical.credentialStorageID
            do {
                // A fresh binding has nothing to restore; the candidate namespace is wiped on failure.
                let prior = rebind ? nil : try secretStore.loadSecret(serverID: namespace, key: key)
                rollbackActions.append(SecretRollbackAction(serverID: namespace, key: key, priorValue: prior))
                try secretStore.saveSecret(value, serverID: namespace, key: key)
            } catch {
                rollback()
                throw error
            }
        }

        // 1. Sensitive env/header values become references to the binding's namespace
        for (k, v) in canonical.env ?? [:] where MCPServerConfig.isSensitiveKey(k) && !MCPServerConfig.isSecretReference(v) {
            try storeSecret(v, key: MCPSecretKey.env(k))
            canonical.env?[k] = MCPServerConfig.makeKeychainReference(key: k)
        }
        for (k, v) in canonical.headers ?? [:] where MCPServerConfig.isSensitiveKey(k) && !MCPServerConfig.isSecretReference(v) {
            try storeSecret(v, key: MCPSecretKey.header(k))
            canonical.headers?[k] = MCPServerConfig.makeKeychainReference(key: k)
        }
        for (name, value) in quarantinedValues {
            try storeSecret(value, key: MCPSecretKey.quarantine(name))
        }
        if case .replace(let value) = clientSecret {
            try storeSecret(value, key: MCPSecretKey.oauthClientSecret)
        }

        let now = Date().timeIntervalSince1970
        canonical.updatedAt = now

        var candidateServers = servers
        if let index = candidateServers.firstIndex(where: { $0.id == server.id }) {
            canonical.createdAt = servers[index].createdAt ?? now
            candidateServers[index] = canonical
        } else {
            canonical.createdAt = server.createdAt ?? now
            candidateServers.append(canonical)
        }
        candidateServers.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }

        // 3. Durably persist candidate MCP config before advancing in-memory or deleting old secrets
        do {
            try persistServers(candidateServers: candidateServers, retiredNamespaces: retiredNamespaces)
        } catch {
            rollback()
            throw error
        }

        // 4. Advance authoritative state
        servers = candidateServers
        if !rebind, oldConfig != nil {
            do { try sweepUnreferencedSlots(of: canonical) }
            catch {
                authorityState = .recoveryRequired
                logs.error("MCP", "Configuration committed; removing unreferenced credentials remains pending.")
            }
        }

        // 6. Reset existing transport and clear stale tools on config change
        inProgressRefreshTasks[server.id]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: server.id)
        let generation = nextGeneration(for: server.id)

        stopTransport(serverID: server.id)
        toolsByServer.removeValue(forKey: server.id)
        instructionsByServer.removeValue(forKey: server.id)
        discoveredGenerations.removeValue(forKey: server.id)

        if canonical.enabled {
            statuses[server.id] = .connecting
            startRefreshTask(for: server.id, generation: generation)
        } else {
            statuses[server.id] = .disconnected
        }
        refreshCredentialPresence(for: server.id)
    }

    /// Deletes stored slots the definition no longer references. OAuth records are not referenced
    /// by configuration and stay with the binding.
    private func sweepUnreferencedSlots(of server: MCPServerConfig) throws {
        var referenced: Set<String> = [MCPSecretKey.oauthToken]
        if server.oauth?.clientId?.isEmpty == false { referenced.insert(MCPSecretKey.oauthClientSecret) }
        for (_, value) in server.env ?? [:] { if let key = MCPServerConfig.extractKeychainKey(from: value) { referenced.insert(MCPSecretKey.env(key)) } }
        for (_, value) in server.headers ?? [:] { if let key = MCPServerConfig.extractKeychainKey(from: value) { referenced.insert(MCPSecretKey.header(key)) } }
        for name in server.quarantinedFields ?? [] { referenced.insert(MCPSecretKey.quarantine(name)) }
        for key in try secretStore.storedKeys(serverID: server.credentialStorageID) where !referenced.contains(key) {
            try secretStore.deleteSecret(serverID: server.credentialStorageID, key: key)
        }
    }

    private func purgeRuntimeState(for serverID: String) {
        credentialPresenceTasks.removeValue(forKey: serverID)?.cancel()
        credentialPresenceByServer.removeValue(forKey: serverID)
        missingCredentials.removeValue(forKey: serverID)
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        _ = nextGeneration(for: serverID)
        stopTransport(serverID: serverID)
        statuses.removeValue(forKey: serverID)
        toolsByServer.removeValue(forKey: serverID)
        instructionsByServer.removeValue(forKey: serverID)
        discoveredGenerations.removeValue(forKey: serverID)
        connectionGenerations.removeValue(forKey: serverID)
        while let idx = credentialQueue.firstIndex(where: { $0.serverID == serverID }) {
            let item = credentialQueue.remove(at: idx)
            item.continuation.resume(returning: nil)
        }
        advanceCredentialQueue()
    }

    func delete(id: String) throws {
        guard authorityState == .ready else { throw MCPHostControlError.unavailable }
        let candidate = servers.filter { $0.id != id }
        let operationID = try persistServers(candidateServers: candidate, deletionTarget: id)
        servers = candidate
        purgeRuntimeState(for: id)
        do {
            try secretStore.deleteAllBindings(serverID: id)
            try finishConfigurationOperation(operationID, outcome: .committed)
            logs.info("MCP", "Removed server configuration and credentials.")
        } catch {
            // Removal has committed. The journal keeps the deletion tombstone, recovery retries the
            // cleanup, and the receipt reports committed with recovery pending.
            authorityState = .recoveryRequired
            logs.error("MCP", "Server removed; credential cleanup remains pending.")
        }
    }

    func setEnabled(_ isEnabled: Bool, for serverID: String) {
        guard var candidate = servers.first(where: { $0.id == serverID }) else { return }
        candidate.enabled = isEnabled
        do { try addOrUpdate(candidate) }
        catch { statuses[serverID] = .failed(message: "Could not commit the MCP enabled setting.", kind: .credentialStorage) }
    }

    // MARK: - Refresh & Execution

    func reconnect(serverID: String) async {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        let generation = nextGeneration(for: serverID)

        stopTransport(serverID: serverID)
        toolsByServer.removeValue(forKey: serverID)
        instructionsByServer.removeValue(forKey: serverID)
        discoveredGenerations.removeValue(forKey: serverID)

        guard servers[index].enabled else {
            statuses[serverID] = .disconnected
            return
        }

        statuses[serverID] = .connecting
        let task = startRefreshTask(for: serverID, generation: generation)
        await task.value
    }

    // MARK: - OAuth

    func usesOAuth(serverID: String) -> Bool {
        Self.oauthAdmitted && (servers.first(where: { $0.id == serverID }).map(MCPOAuth.appliesTo) ?? false)
    }

    /// Authenticates an HTTP server the way it allows (Claude Code's /mcp "Authenticate", `codex mcp login`):
    /// browser sign-in for OAuth servers; when the server cannot register Limare (no dynamic registration
    /// and no client ID configured) or uses a fixed Authorization header, the token prompt instead.
    /// Ends with a reconnect. Throws when the user cancels or authentication fails. Runs only as the
    /// runtime operation `operationID`, whose Human ticket covers this sign-in or token replacement.
    private func authenticate(serverID: String, operationID: UUID) async throws {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw MCPTransportError.unknownServer(serverID)
        }
        try validateRuntimeAction("authenticate", serverID: serverID)
        defer { refreshCredentialPresence(for: serverID) }
        inProgressRefreshTasks[serverID]?.cancel()
        inProgressRefreshTasks.removeValue(forKey: serverID)
        _ = nextGeneration(for: serverID)
        stopTransport(serverID: serverID)
        toolsByServer.removeValue(forKey: serverID)
        instructionsByServer.removeValue(forKey: serverID)
        discoveredGenerations.removeValue(forKey: serverID)

        let oauth = usesOAuth(serverID: serverID)
        do {
            if oauth {
                // Reachable only once SDK OAuth is admitted with the §9.1 commit adapter.
                throw MCPOAuthError.unavailable
            }
            if server.credentialSlots.isEmpty {
                try await requestToken(for: server, operationID: operationID)
            } else {
                try await requestCredentials(for: server, operationID: operationID)
            }
        } catch MCPOAuthError.cancelled {
            statuses[serverID] = oauth ? .signInRequired : .credentialRequired
            throw MCPOAuthError.cancelled
        } catch {
            let message = SecretMasker.redact(error.localizedDescription, secrets: await collectSecrets(for: serverID))
            if case .failed = statuses[serverID] {
                // Already recorded with its own kind (e.g. the Keychain write failed).
            } else {
                statuses[serverID] = .failed(message: message, kind: .authentication)
            }
            logs.error("MCP", "Authentication for '\(serverID)' failed: \(message)")
            throw error
        }
    }

    /// Asks the user, in Limare's protected prompt, for each referenced credential that has no value
    /// (or for all of them, to replace them), then commits the values into the server's binding.
    private func requestCredentials(for server: MCPServerConfig, operationID: UUID) async throws {
        statuses[server.id] = .credentialRequired
        let slots = server.credentialSlots
        let missing = slots.filter {
            (try? secretStore.secretPresence(serverID: server.credentialStorageID, key: $0.key)) != .present
        }
        let wanted = missing.isEmpty ? slots : missing
        missingCredentials[server.id] = wanted.map(\.name)
        let ticket = try await humanConsentProvider(operationID, "Save credentials for the MCP connection “\(server.id)”.")
        var values: [(name: String, isHeader: Bool, value: String)] = []
        for slot in wanted {
            let prompt = "Enter \(slot.name) for “\(server.id)”. Limare stores it in its private storage and gives it only to this server."
            guard let value = await requestCredential(serverID: server.id, serverName: server.id, promptText: prompt, credentialName: slot.name),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPOAuthError.cancelled
            }
            var entered = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // An Authorization header takes a bare token as a bearer credential, as the token prompt always has.
            if slot.isHeader, slot.name.caseInsensitiveCompare(MCPSecretKey.authorizationHeaderName) == .orderedSame, !entered.contains(" ") {
                entered = "Bearer \(entered)"
            }
            values.append((slot.name, slot.isHeader, entered))
        }
        guard var current = servers.first(where: { $0.id == server.id }) else { throw MCPTransportError.unknownServer(server.id) }
        for entry in values {
            if entry.isHeader { current.headers?[entry.name] = entry.value } else { current.env?[entry.name] = entry.value }
        }
        do {
            try addOrUpdate(current, authorization: ticket)
        } catch {
            statuses[server.id] = .failed(message: "The credential was not committed to secure storage.", kind: .credentialStorage)
            throw error
        }
        missingCredentials.removeValue(forKey: server.id)
        await refreshTools(for: server.id)
    }

    /// Asks for a token in the protected prompt and switches the connection to a fixed Authorization header.
    private func requestToken(for server: MCPServerConfig, operationID: UUID) async throws {
        statuses[server.id] = .credentialRequired
        let ticket = try await humanConsentProvider(operationID, "Replace the access token for the MCP connection “\(server.id)”.")
        let prompt = "Enter the credential for this explicit generic bearer connection in Limare's secure UI."
        let token = await requestCredential(serverID: server.id, serverName: server.id, promptText: prompt)
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPOAuthError.cancelled
        }
        do {
            try saveAuthorizationBearerToken(token, serverID: server.id, authorization: ticket)
        } catch {
            statuses[server.id] = .failed(message: "The credential was not committed to secure storage.", kind: .credentialStorage)
            throw error
        }
        await refreshTools(for: server.id)
    }

    /// Forgets the OAuth token (Claude Code's "Clear authentication", `codex mcp logout`).
    private func signOut(serverID: String) async -> Bool {
        inProgressRefreshTasks.removeValue(forKey: serverID)?.cancel()
        _ = nextGeneration(for: serverID)
        stopTransport(serverID: serverID)
        toolsByServer.removeValue(forKey: serverID)
        instructionsByServer.removeValue(forKey: serverID)
        discoveredGenerations.removeValue(forKey: serverID)
        do {
            try secretStore.deleteSecret(serverID: credentialNamespace(for: serverID), key: MCPSecretKey.oauthToken)
        } catch {
            statuses[serverID] = .failed(message: "Could not remove the stored OAuth credential.", kind: .credentialStorage)
            refreshCredentialPresence(for: serverID)
            return false
        }
        credentialPresenceByServer[serverID]?[MCPSecretKey.oauthToken] = .absent
        logs.info("MCP", "Cleared OAuth token for server '\(serverID)'.")
        await reconnect(serverID: serverID)
        return true
    }

    func refreshTools(for serverID: String) async {
        if let existing = inProgressRefreshTasks[serverID] {
            await existing.value
            return
        }

        let generation = connectionGenerations[serverID, default: 0]
        let task = startRefreshTask(for: serverID, generation: generation)
        await task.value
    }

    private func performRefreshTools(for serverID: String, generation: Int) async {
        defer { refreshCredentialPresence(for: serverID) }
        guard authorityState == .ready else { return }
        #if DEBUG
        let isInjectedDiscovery = toolDiscoveryProvider != nil
        #else
        let isInjectedDiscovery = false
        #endif
        if let server = servers.first(where: { $0.id == serverID }), server.requiresReview {
            statuses[serverID] = .failed(message: "Imported fields await review in Settings before this server can connect.", kind: .other)
            toolsByServer.removeValue(forKey: serverID)
            instructionsByServer.removeValue(forKey: serverID)
            discoveredGenerations.removeValue(forKey: serverID)
            return
        }
        guard Self.productionSDKAdmitted || isInjectedDiscovery else {
            statuses[serverID] = .configSaved
            toolsByServer.removeValue(forKey: serverID)
            instructionsByServer.removeValue(forKey: serverID)
            discoveredGenerations.removeValue(forKey: serverID)
            return
        }
        guard !Task.isCancelled else { return }
        guard connectionGenerations[serverID, default: 0] == generation else { return }
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        guard server.enabled else {
            statuses[serverID] = .disconnected
            toolsByServer.removeValue(forKey: serverID)
            instructionsByServer.removeValue(forKey: serverID)
            return
        }

        // A list-changed refresh keeps the current catalog usable until the new list is complete.
        if statuses[serverID]?.isConnected != true { statuses[serverID] = .connecting }
        logs.info("MCP", "Connecting to server '\(serverID)' (\(server.transportType.rawValue))...")

        do {
            let tools: [MCPTool]
            var instructions: String?
            if let discovery = toolDiscoveryProvider {
                let resolved = try await resolveSecretsForConnection(server)
                tools = try await discovery(resolved)
            } else {
                let connection = try await connection(for: server)
                try await connection.ensureConnected()
                tools = try await connection.listTools()
                instructions = await connection.instructions
            }

            // Stale result guard
            guard !Task.isCancelled else { return }
            guard let currentServer = servers.first(where: { $0.id == serverID }), currentServer.enabled else { return }
            guard connectionGenerations[serverID, default: 0] == generation else { return }

            toolsByServer[serverID] = tools
            instructionsByServer[serverID] = instructions
            missingCredentials.removeValue(forKey: serverID)
            discoveredGenerations[serverID] = generation
            statuses[serverID] = .connected(toolCount: tools.count)
            logs.info("MCP", "Connected to server '\(serverID)' with \(tools.count) tools.")
        } catch {
            guard !Task.isCancelled else { return }
            guard let currentServer = servers.first(where: { $0.id == serverID }), currentServer.enabled else { return }
            guard connectionGenerations[serverID, default: 0] == generation else { return }

            discoveredGenerations.removeValue(forKey: serverID)
            toolsByServer.removeValue(forKey: serverID)
            instructionsByServer.removeValue(forKey: serverID)
            if case MCPTransportError.signInRequired = error {
                statuses[serverID] = .signInRequired
                logs.info("MCP", "Server '\(serverID)' requires OAuth sign-in.")
                return
            }
            if case MCPTransportError.credentialMissing(_, let names) = error {
                statuses[serverID] = .credentialRequired
                missingCredentials[serverID] = names
                logs.info("MCP", "Server '\(serverID)' needs credentials: \(names.joined(separator: ", ")).")
                return
            }
            // Without admitted OAuth, a server that refuses anonymous access takes a bearer token.
            if case MCPTransportError.authenticationRequired = error, !Self.oauthAdmitted, !server.hasStaticAuthorizationHeader {
                statuses[serverID] = .credentialRequired
                logs.info("MCP", "Server '\(serverID)' requires credentials.")
                return
            }

            let rawDesc = error.localizedDescription
            let secretsToRedact = await collectSecrets(for: serverID)
            let redactedDesc = SecretMasker.redact(rawDesc, secrets: secretsToRedact)

            statuses[serverID] = .failed(message: redactedDesc, kind: MCPErrorClassifier.classify(error, url: server.url).failureKind)
            logs.error("MCP", "Failed to connect to server '\(serverID)': \(redactedDesc)")
        }
    }

    func refreshAll() async {
        for server in servers where server.enabled {
            await refreshTools(for: server.id)
        }
    }

    func callTool(
        serverID: String,
        toolName: String,
        arguments: [String: AnyCodable],
        conversationID: UUID? = nil,
        artifactStore: ArtifactStore? = nil
    ) async throws -> MCPToolCallResult {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            throw MCPTransportError.unknownServer(serverID)
        }
        guard server.enabled else {
            throw MCPTransportError.serverDisabled(serverID)
        }
        guard currentDiscoveredTools(for: server).contains(where: { $0.name == toolName }) else {
            throw MCPTransportError.toolUnavailable(serverID: serverID, toolName: toolName)
        }

        let secrets = await collectSecrets(for: serverID)
        do {
            // Only the session whose tools were discovered may run them; discovery owns (re)connection.
            guard let connection = connections[serverID] else { throw MCPTransportError.connectionClosed }
            let result = try await connection.callTool(name: toolName, arguments: arguments,
                                                       conversationID: conversationID, artifactStore: artifactStore)
            if result.isError && !secrets.isEmpty {
                let sanitizedContent = SecretMasker.redact(result.content, secrets: secrets)
                return MCPToolCallResult(
                    content: sanitizedContent,
                    isError: true,
                    resultParts: result.resultParts,
                    attachments: result.attachments
                )
            }
            return result
        } catch {
            if case MCPTransportError.signInRequired = error {
                statuses[serverID] = .signInRequired
                toolsByServer.removeValue(forKey: serverID)
                instructionsByServer.removeValue(forKey: serverID)
                discoveredGenerations.removeValue(forKey: serverID)
            }
            let redacted = SecretMasker.redact(error.localizedDescription, secrets: secrets)
            logs.error("MCP", "Tool '\(toolName)' on server '\(serverID)' failed: \(redacted)")
            throw MCPTransportError.executionFailed(redacted)
        }
    }

    // MARK: - Persistence & Import/Export

    /// Human-only migration; the Agent interface never exposes this method.
    func migrateLegacyConfiguration() async throws {
        guard authorityState == .migrationRequired, let native = secretStore as? KeychainMCPSecretStore else {
            throw MCPHostControlError.unavailable
        }
        let operationID = UUID()
        let consent = try await humanConsentProvider(operationID, "Migrate Limare MCP configuration and credentials to private application storage.")
        guard authorityState == .migrationRequired, consent.isValid,
              try native.readControlRecord(.configuration) == nil,
              try native.readControlRecord(.journal) == nil else { throw MCPHostControlError.unavailable }
        let data = try Data(contentsOf: storageURL)
        guard data.count <= MCPControlRecord.configuration.maximumBytes else { throw MCPHostControlError.capacityExceeded }
        guard let legacyRoot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let legacy = legacyRoot["mcpServers"] as? [String: Any] else { throw MCPHostControlError.invalidRecord }
        guard legacy.count <= 32 else { throw MCPHostControlError.capacityExceeded }
        var candidate: [MCPServerConfig] = []
        var copiedKeys: [(String, String)] = []
        do {
            for (id, raw) in legacy.sorted(by: { $0.key < $1.key }) {
                guard let entry = raw as? [String: Any] else { throw MCPHostControlError.invalidRecord }
                // The parser drops callback ports (ephemeral binding) and quarantines unknown fields;
                // no expired code/token is migrated.
                var (config, quarantined) = try Self.parseImportedEntry(id: id, entry: entry)
                config.startupTimeoutSeconds = entry["startupTimeoutSeconds"] as? Int
                try Self.validate(config)
                for (kind, entries) in [("env", config.env ?? [:]), ("header", config.headers ?? [:])] {
                    for (name, value) in entries {
                        let reference = MCPServerConfig.extractSecretKey(from: value)
                        guard reference != nil || MCPServerConfig.isSensitiveKey(name) else { continue }
                        let key = kind + "." + (reference ?? name)
                        let resolved: String
                        if reference != nil {
                            guard let stored = try native.readLegacySecret(serverID: id, key: key, consent: consent) else {
                                throw MCPHostControlError.invalidRecord
                            }
                            resolved = stored
                        } else { resolved = value }
                        try native.saveSecret(resolved, serverID: config.credentialStorageID, key: key)
                        copiedKeys.append((config.credentialStorageID, key))
                        if kind == "env" { config.env?[name] = MCPServerConfig.makeSecretReference(key: reference ?? name) }
                        else { config.headers?[name] = MCPServerConfig.makeSecretReference(key: reference ?? name) }
                    }
                }
                for (name, value) in quarantined {
                    try native.saveSecret(value, serverID: config.credentialStorageID, key: MCPSecretKey.quarantine(name))
                    copiedKeys.append((config.credentialStorageID, MCPSecretKey.quarantine(name)))
                }
                if !quarantined.isEmpty { config.quarantinedFields = quarantined.keys.sorted() }
                // Old OAuth tokens and client secrets have no validated issuer/binding contract.
                // Human enters the self-owned client setup again; legacy items remain untouched.
                candidate.append(config)
            }
            authorityState = .ready
            try persistServers(candidateServers: candidate)
            servers = candidate
            for config in servers { statuses[config.id] = .configSaved; refreshCredentialPresence(for: config.id) }
        } catch {
            // Preserve the original source. Never claim local cleanup succeeded silently.
            var cleanupFailed = false
            for (id, key) in copiedKeys {
                do { try native.deleteSecret(serverID: id, key: key) }
                catch { cleanupFailed = true }
            }
            // A durable control record changes the recovery case. Do not label it as a
            // fresh migration or delete a receipt that may describe a committed config.
            do {
                if try native.readControlRecord(.configuration) != nil {
                    cleanupFailed = true
                } else if !cleanupFailed {
                    try native.deleteControlRecord(.journal)
                }
            } catch { cleanupFailed = true }
            authorityState = cleanupFailed ? .recoveryRequired : .migrationRequired
            throw error
        }
    }

    func exportJSON(redacted: Bool = true) -> String? {
        var map: [String: MCPServerEntry] = [:]
        for s in servers {
            let configToExport = redacted ? s.redactedCopy() : s
            map[s.id] = MCPServerEntry(
                note: configToExport.note,
                enabled: configToExport.enabled,
                createdAt: configToExport.createdAt,
                updatedAt: configToExport.updatedAt,
                url: configToExport.url,
                headers: configToExport.headers,
                command: configToExport.command,
                args: configToExport.args,
                env: configToExport.env,
                startupTimeoutSeconds: configToExport.startupTimeoutSeconds,
                oauth: configToExport.oauth,
                profile: configToExport.profile
            )
        }
        let file = MCPServersFile(mcpServers: map)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportJSON(for serverID: String, redacted: Bool = true) -> String? {
        guard let s = servers.first(where: { $0.id == serverID }) else { return nil }
        let configToExport = redacted ? s.redactedCopy() : s
        let entry = MCPServerEntry(
            note: configToExport.note,
            enabled: configToExport.enabled,
            createdAt: configToExport.createdAt,
            updatedAt: configToExport.updatedAt,
            url: configToExport.url,
            headers: configToExport.headers,
            command: configToExport.command,
            args: configToExport.args,
            env: configToExport.env,
            startupTimeoutSeconds: configToExport.startupTimeoutSeconds,
            oauth: configToExport.oauth,
            profile: configToExport.profile
        )
        let file = MCPServersFile(mcpServers: [s.id: entry])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fields this Host interprets in Claude Code/Codex-style `mcpServers` entries.
    private nonisolated static let knownImportFields: Set<String> = [
        "type", "command", "args", "env", "url", "headers", "note", "enabled", "startupTimeoutSeconds",
        "oauth", "createdAt", "updatedAt", "profile"
    ]

    /// Parses one imported entry. Unknown inert scalars become extensions; anything else unknown is
    /// quarantined (value returned for the credential namespace, never kept in configuration).
    nonisolated static func parseImportedEntry(id: String, entry: [String: Any]) throws -> (MCPServerConfig, [String: String]) {
        func strings(_ key: String) throws -> [String: String]? {
            guard let value = entry[key] else { return nil }
            guard let map = value as? [String: String] else { throw MCPTransportError.configurationError("'\(key)' must map names to strings.") }
            return map
        }
        let url = entry["url"] as? String
        let command = entry["command"] as? String
        if let type = entry["type"] {
            // Only Streamable HTTP and stdio exist in this Host; a legacy SSE endpoint is not adapted.
            let expected: Set<String> = url != nil ? ["http", "streamable-http", "streamableHttp"] : ["stdio"]
            guard let type = type as? String, expected.contains(type) else {
                throw MCPTransportError.configurationError("Server '\(id)': unsupported transport type.")
            }
        }
        var profile: MCPServerProfile?
        if let raw = entry["profile"] {
            guard let name = raw as? String, let known = MCPServerProfile(rawValue: name) else {
                throw MCPTransportError.configurationError("Server '\(id)': unknown profile.")
            }
            profile = known
        }
        if let oauth = entry["oauth"] as? [String: Any] {
            guard oauth["clientSecret"] == nil else {
                throw MCPTransportError.configurationError("Client secrets belong in the native secure input, never configuration JSON.")
            }
            guard Set(oauth.keys).isSubset(of: ["clientId", "callbackPort"]) else {
                throw MCPTransportError.configurationError("Server '\(id)': unsupported OAuth settings.")
            }
        }
        var config = MCPServerConfig(
            id: id,
            note: entry["note"] as? String,
            enabled: (entry["enabled"] as? Bool) ?? true,
            createdAt: entry["createdAt"] as? Double,
            updatedAt: entry["updatedAt"] as? Double,
            command: command,
            args: entry["args"] as? [String],
            env: try strings("env"),
            startupTimeoutSeconds: (entry["startupTimeoutSeconds"] as? Int) ?? 30,
            url: url,
            headers: try strings("headers"),
            // Browser flows always bind an ephemeral port.
            oauth: (entry["oauth"] as? [String: Any]).map { MCPOAuthSettings(clientId: $0["clientId"] as? String, callbackPort: nil) },
            profile: profile
        )
        var quarantined: [String: String] = [:]
        for (name, value) in entry where !knownImportFields.contains(name) {
            var inert: AnyCodable?
            switch value {
            case let text as String where !SecretMasker.containsCredential(text) && !MCPServerConfig.isSecretReference(text):
                inert = AnyCodable(text)
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
                inert = AnyCodable(number.boolValue)
            case let number as NSNumber:
                inert = CFNumberIsFloatType(number) ? AnyCodable(number.doubleValue) : AnyCodable(number.intValue)
            default: inert = nil
            }
            if let inert, !MCPServerConfig.isSensitiveKey(name) {
                config.extensions = (config.extensions ?? [:]).merging([name: inert]) { $1 }
            } else {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                quarantined[name] = String(decoding: data, as: UTF8.self)
            }
        }
        return (config, quarantined)
    }

    /// Human import (Settings). Every entry is validated before the first commit; credential values
    /// and quarantined fields are confirmed once, through LocalAuthentication, for this import.
    @discardableResult
    func importJSON(_ jsonString: String) async throws -> Int {
        guard let data = jsonString.data(using: .utf8) else {
            throw MCPTransportError.parseError("Invalid text encoding")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPTransportError.parseError("JSON must be an object")
        }

        let serversDict: [String: Any]
        if let dict = root["mcpServers"] as? [String: Any] {
            serversDict = dict
        } else {
            serversDict = root
        }

        // Every entry is parsed and validated before the first commit.
        let now = Date().timeIntervalSince1970
        var parsed: [(MCPServerConfig, [String: String])] = []
        for (id, rawValue) in serversDict.sorted(by: { $0.key < $1.key }) {
            guard let entry = rawValue as? [String: Any] else { continue }
            var (config, quarantined) = try Self.parseImportedEntry(id: id, entry: entry)
            config.createdAt = now
            config.updatedAt = now
            try Self.validate(config)
            parsed.append((config, quarantined))
        }
        var ticket: MCPHumanConsent?
        if parsed.contains(where: { Self.writesCredential($0.0, quarantinedValues: $0.1, clientSecret: .unchanged) }) {
            ticket = try await humanConsentProvider(UUID(), "Import MCP connections with credentials into Limare.")
        }
        for (config, quarantined) in parsed {
            try addOrUpdate(config, quarantinedValues: quarantined, authorization: ticket)
        }
        return parsed.count
    }

    /// Human review outcome for quarantined imported fields: their values are deleted, never applied.
    func discardQuarantinedFields(serverID: String) throws {
        guard var server = servers.first(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
        // The post-commit sweep deletes the now unreferenced values; recovery retries it on failure.
        server.quarantinedFields = nil
        try addOrUpdate(server)
    }

    @discardableResult
    private func persistServers(candidateServers: [MCPServerConfig], deletionTarget: String? = nil, retiredNamespaces: [String] = []) throws -> UUID {
        guard authorityState == .ready, let controlRecords else { throw MCPHostControlError.unavailable }
        var candidate = controlDocument
        candidate.servers = candidateServers
        let comparisonEncoder = JSONEncoder()
        comparisonEncoder.outputFormatting = [.sortedKeys]
        if try comparisonEncoder.encode(candidateServers) != comparisonEncoder.encode(controlDocument.servers) {
            candidate.documentRevision += 1
        }
        let id = preparedConfigurationOperationID ?? managementOperation?.id ?? UUID()
        candidate.lastCommitOperationID = id
        try candidate.validate()
        let data = try JSONEncoder().encode(candidate)
        guard data.count <= MCPControlRecord.configuration.maximumBytes else { throw MCPHostControlError.capacityExceeded }
        var journal = operationJournal
        if let index = journal.activeOperations.firstIndex(where: { $0.id == id }) {
            journal.activeOperations[index].targetRevision = candidate.documentRevision
            journal.activeOperations[index].retiredCredentialNamespaces = retiredNamespaces.isEmpty ? nil : retiredNamespaces
        } else {
            guard journal.activeOperations.count < 8 else { throw MCPHostControlError.capacityExceeded }
            journal.activeOperations.append(MCPHostOperationReceipt(id: id, createdAt: Date(), outcome: .pending, targetRevision: candidate.documentRevision, commandDigest: managementOperation?.digest, deletionTarget: deletionTarget, retiredCredentialNamespaces: retiredNamespaces.isEmpty ? nil : retiredNamespaces, serverID: deletionTarget))
        }
        journal.journalRevision += 1
        try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
        operationJournal = journal
        operationReceipts = journal.terminalReceipts + journal.activeOperations
        do {
            try controlRecords.writeControlRecord(data, record: .configuration)
        } catch {
            journal.finish(id, outcome: .notCommitted)
            do {
                try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
                operationJournal = journal
                operationReceipts = journal.terminalReceipts
            } catch { authorityState = .recoveryRequired }
            throw error
        }
        // Configuration has committed. A failed receipt write cannot roll it back.
        controlDocument = candidate
        configurationRevision = candidate.documentRevision
        if deletionTarget != nil { return id }
        do {
            for namespace in retiredNamespaces { try secretStore.deleteAllSecrets(serverID: namespace) }
        } catch {
            authorityState = .recoveryRequired
            return id
        }
        journal.finish(id, outcome: .committed)
        do {
            try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
            operationJournal = journal
            operationReceipts = journal.terminalReceipts
        } catch {
            authorityState = .recoveryRequired
            logs.error("MCP", "Configuration committed; operation receipt recovery is required.")
        }
        return id
    }

    private func finishConfigurationOperation(_ id: UUID, outcome: MCPHostOperationReceipt.Outcome) throws {
        guard let controlRecords else { throw MCPHostControlError.unavailable }
        var journal = operationJournal
        journal.finish(id, outcome: outcome)
        try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
        operationJournal = journal
        operationReceipts = journal.terminalReceipts
    }

    private func load() {
        guard let controlRecords else { authorityState = .storageUnavailable; return }
        do {
            guard let data = try controlRecords.readControlRecord(.configuration) else {
                guard try controlRecords.readControlRecord(.journal) == nil else {
                    authorityState = .recoveryRequired
                    return
                }
                // Legacy files are recovery sources, never active configuration.
                guard !fileManager.fileExists(atPath: storageURL.path) else {
                    authorityState = .migrationRequired
                    return
                }
                try controlRecords.writeControlRecord(JSONEncoder().encode(controlDocument), record: .configuration)
                try controlRecords.writeControlRecord(JSONEncoder().encode(operationJournal), record: .journal)
                authorityState = .ready
                return
            }
            var document = try JSONDecoder().decode(MCPHostConfigDocument.self, from: data)
            try document.validate()
            let journalData = try controlRecords.readControlRecord(.journal)
            var journal: MCPHostOperationJournal
            if let journalData {
                journal = try JSONDecoder().decode(MCPHostOperationJournal.self, from: journalData)
            } else if document.documentRevision == 0 && document.lastCommitOperationID == nil {
                // Recover an interrupted first initialization, without consulting old files.
                journal = MCPHostOperationJournal()
            } else { throw MCPHostControlError.invalidRecord }
            guard journal.schemaVersion == 1, journal.journalRevision < UInt64.max, journal.activeOperations.count <= 8,
                  journal.terminalReceipts.count <= 128 else { throw MCPHostControlError.invalidRecord }
            for receipt in journal.activeOperations {
                if receipt.action != nil {
                    // A runtime action interrupted by exit may or may not have taken effect.
                    journal.finish(receipt.id, outcome: .outcomeUnknown, safeError: "Limare stopped before the action finished.")
                    continue
                }
                let committed = receipt.id == document.lastCommitOperationID && receipt.targetRevision == document.documentRevision
                do {
                    if committed, let serverID = receipt.deletionTarget {
                        try secretStore.deleteAllBindings(serverID: serverID)
                    }
                    if committed {
                        for namespace in receipt.retiredCredentialNamespaces ?? [] { try secretStore.deleteAllSecrets(serverID: namespace) }
                    }
                    if !committed, let namespace = receipt.candidateCredentialNamespace {
                        try secretStore.deleteAllSecrets(serverID: namespace)
                    }
                    if committed, let server = document.servers.first(where: { $0.id == receipt.serverID }) {
                        try sweepUnreferencedSlots(of: server)
                    }
                } catch {
                    // The records are readable; the owed credential cleanup is what remains.
                    throw MCPHostControlError.invalidRecord
                }
                if !committed {
                    // This journal currently contains only local configuration/deletion jobs.
                    // No OAuth code or refresh transaction is inferred from these markers.
                    journal.finish(receipt.id, outcome: .notCommitted)
                } else { journal.finish(receipt.id, outcome: .committed) }
            }
            try controlRecords.writeControlRecord(JSONEncoder().encode(journal), record: .journal)
            document.servers.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            controlDocument = document
            operationJournal = journal
            configurationRevision = document.documentRevision
            operationReceipts = journal.terminalReceipts
            authorityState = .ready
            servers = document.servers
            for server in servers {
                statuses[server.id] = .disconnected
                refreshCredentialPresence(for: server.id)
            }
        } catch {
            authorityState = (error is DecodingError || error is MCPHostControlError) ? .recoveryRequired : .storageUnavailable
            logs.error("MCP", authorityState.message)
        }
    }

    private nonisolated static func resolveSecrets(in config: MCPServerConfig, using secretStore: any MCPSecretStoring) throws -> MCPServerConfig {
        var resolved = config
        var missing: [String] = []
        for slot in config.credentialSlots {
            guard let secret = try secretStore.loadSecret(serverID: config.credentialStorageID, key: slot.key) else {
                missing.append(slot.name)
                continue
            }
            if slot.isHeader { resolved.headers?[slot.name] = secret } else { resolved.env?[slot.name] = secret }
        }
        guard missing.isEmpty else { throw MCPTransportError.credentialMissing(serverID: config.id, names: missing) }
        return resolved
    }

    private func resolveSecretsForConnection(_ config: MCPServerConfig) async throws -> MCPServerConfig {
        let store = secretStore
        return try await Task.detached(priority: .userInitiated) {
            try Self.resolveSecrets(in: config, using: store)
        }.value
    }

    /// The server's live SDK session, created on first discovery for the current generation.
    private func connection(for config: MCPServerConfig) async throws -> MCPConnection {
        if let existing = connections[config.id] { return existing }
        let resolved = try await resolveSecretsForConnection(config)
        if let existing = connections[config.id] { return existing }
        let generation = connectionGenerations[config.id, default: 0]
        let connection = MCPConnection(config: resolved, workspaceURL: workspaceURLProvider() ?? FileManager.default.temporaryDirectory) {
            [weak self, serverID = config.id] event in
            await self?.handleConnectionEvent(event, serverID: serverID, generation: generation)
        }
        connections[config.id] = connection
        return connection
    }

    private func handleConnectionEvent(_ event: MCPConnection.Event, serverID: String, generation: Int) {
        switch event {
        case .exited(let code):
            handleUnexpectedStdioTermination(serverID: serverID, generation: generation, exitCode: code)
        case .toolListChanged:
            // A real server notification is the only push trigger; changes coalesce into one refresh.
            guard connectionGenerations[serverID] == generation, inProgressRefreshTasks[serverID] == nil else { return }
            startRefreshTask(for: serverID, generation: generation)
        }
    }

    private func stopTransport(serverID: String) {
        if let connection = connections.removeValue(forKey: serverID) {
            Task { await connection.stop() }
        }
    }
}
