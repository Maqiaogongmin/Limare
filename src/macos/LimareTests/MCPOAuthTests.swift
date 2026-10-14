import XCTest
import MCP
@testable import Limare

@MainActor
final class MCPOAuthTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_oauth_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Which servers use OAuth

    func testOAuthAppliesOnlyToHTTPSServersWithoutFixedAuthorization() {
        XCTAssertTrue(MCPOAuth.appliesTo(MCPServerConfig(id: "hf", url: "https://huggingface.co/mcp")))
        XCTAssertTrue(MCPOAuth.appliesTo(MCPServerConfig(id: "local", url: "http://127.0.0.1:8080/mcp")))
        XCTAssertFalse(
            MCPOAuth.appliesTo(MCPServerConfig(id: "gh", url: "https://api.githubcopilot.com/mcp/",
                                               headers: ["Authorization": "${keychain:Authorization}"])),
            "A fixed Authorization header wins over OAuth"
        )
        XCTAssertFalse(MCPOAuth.appliesTo(MCPServerConfig(id: "lan", url: "http://192.168.1.5:8000/mcp")),
                       "The SDK authorizer rejects plain HTTP off loopback; such servers keep the plain transport")
        XCTAssertFalse(MCPOAuth.appliesTo(MCPServerConfig(id: "cmd", command: "npx", args: ["server"])))
    }

    // MARK: - Configuration

    func testOAuthSettingsRoundTripAndClientSecretStaysOutOfConfigFile() async throws {
        let dir = try makeTempDir()
        let logs = DebugLogStore(storageRootURL: dir, osLogProjection: { _, _, _ in })
        let secrets = InMemoryMCPSecretStore()
        let store = MCPStore(logs: logs, storageRootURL: dir, secretStore: secrets)
        store.toolDiscoveryProvider = { _ in [] }
        store.humanConsentProvider = { operationID, _ in .forTesting(operationID: operationID) }

        let json = """
        {"mcpServers": {"github": {"url": "https://mcp.example.com/mcp",
          "oauth": {"clientId": "Iv1.test"}}}}
        """
        let imported = try await store.importJSON(json)
        XCTAssertEqual(imported, 1)
        let configured = try XCTUnwrap(store.servers.first(where: { $0.id == "github" }))
        try await store.saveConfiguration(configured, clientSecret: .replace("s3cret-value"))
        let bound = try XCTUnwrap(store.servers.first(where: { $0.id == "github" }))
        XCTAssertEqual(try secrets.loadSecret(serverID: bound.credentialStorageID, key: MCPSecretKey.oauthClientSecret), "s3cret-value")

        let file = String(data: try XCTUnwrap(secrets.readControlRecord(.configuration)), encoding: .utf8)!
        XCTAssertTrue(file.contains("Iv1.test"))
        XCTAssertFalse(file.contains("s3cret-value"), "The client secret must never reach mcp_servers.json")

        let reloaded = MCPStore(logs: logs, storageRootURL: dir, secretStore: secrets)
        let server = try XCTUnwrap(reloaded.servers.first(where: { $0.id == "github" }))
        XCTAssertEqual(server.oauth, MCPOAuthSettings(clientId: "Iv1.test", callbackPort: nil))
        XCTAssertTrue(MCPOAuth.appliesTo(server), "The reloaded configuration remains OAuth-eligible")
        XCTAssertFalse(reloaded.usesOAuth(serverID: "github"), "The SDK OAuth runtime gate remains closed in this release")
    }

    func testChangingServerURLDropsTheBoundToken() async throws {
        let dir = try makeTempDir()
        let logs = DebugLogStore(storageRootURL: dir, osLogProjection: { _, _, _ in })
        let secrets = InMemoryMCPSecretStore()
        let store = MCPStore(logs: logs, storageRootURL: dir, secretStore: secrets)
        store.toolDiscoveryProvider = { _ in [] }

        try store.addOrUpdate(MCPServerConfig(id: "hf", url: "https://huggingface.co/mcp"))
        let binding = try XCTUnwrap(store.servers.first?.credentialStorageID)
        try secrets.saveSecret("{}", serverID: binding, key: MCPSecretKey.oauthToken)
        try store.addOrUpdate(MCPServerConfig(id: "hf", note: "renamed", url: "https://huggingface.co/mcp"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.credentialPresence(serverID: "hf", key: MCPSecretKey.oauthToken), .present, "Unrelated edits keep the sign-in")

        try store.addOrUpdate(MCPServerConfig(id: "hf", url: "https://example.com/mcp"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.credentialPresence(serverID: "hf", key: MCPSecretKey.oauthToken), .absent, "A token is bound to its resource")
    }

    func testPlainNoteIsKept() throws {
        let dir = try makeTempDir()
        let logs = DebugLogStore(storageRootURL: dir, osLogProjection: { _, _, _ in })
        let store = MCPStore(logs: logs, storageRootURL: dir, secretStore: InMemoryMCPSecretStore())
        store.toolDiscoveryProvider = { _ in [] }
        try store.addOrUpdate(MCPServerConfig(id: "github-remote", note: "GitHub Remote MCP Server",
                                              url: "https://api.githubcopilot.com/mcp/"))
        XCTAssertEqual(store.servers.first?.note, "GitHub Remote MCP Server")
    }

    // MARK: - Live endpoints (LIMARE_LIVE=1)

    private func requireLive() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIMARE_LIVE"] == "1", "Set LIMARE_LIVE=1 for live MCP OAuth checks")
    }

    /// Without admitted OAuth, an unauthenticated GitHub connect reports that credentials are needed.
    func testLiveGitHubWithoutTokenRequiresCredentials() async throws {
        try requireLive()
        let connection = MCPConnection(config: MCPServerConfig(id: "gh-live", url: "https://api.githubcopilot.com/mcp/"),
                                       workspaceURL: FileManager.default.temporaryDirectory) { _ in }
        defer { Task { await connection.stop() } }
        do {
            try await connection.ensureConnected()
            XCTFail("An unauthenticated GitHub connect cannot succeed")
        } catch MCPTransportError.authenticationRequired {
        }
    }

    func testGitHubProfileRejectsStaticTokenFallback() throws {
        var config = MCPServerProfile.githubRemote.configuration(id: "github")
        XCTAssertNoThrow(try MCPStore.validate(config))
        config.headers?["Authorization"] = MCPServerConfig.makeSecretReference(key: "Authorization")
        XCTAssertThrowsError(try MCPStore.validate(config))
    }

    /// Hugging Face is anonymous by default and forces auth with `?login`, which asks for a token while OAuth is closed.
    func testLiveHuggingFaceAnonymousAndLoginForced() async throws {
        try requireLive()
        let anonymous = MCPConnection(config: MCPServerConfig(id: "hf-anon", url: "https://huggingface.co/mcp"),
                                      workspaceURL: FileManager.default.temporaryDirectory) { _ in }
        try await anonymous.ensureConnected()
        let tools = try await anonymous.listTools()
        await anonymous.stop()
        XCTAssertFalse(tools.isEmpty, "Hugging Face serves anonymous tools")

        let dir = try makeTempDir()
        let logs = DebugLogStore(storageRootURL: dir, osLogProjection: { _, _, _ in })
        let store = MCPStore(logs: logs, storageRootURL: dir, secretStore: InMemoryMCPSecretStore())
        try store.addOrUpdate(MCPServerConfig(id: "hf-login", url: "https://huggingface.co/mcp?login"))
        await store.refreshTools(for: "hf-login")
        XCTAssertEqual(store.status(for: "hf-login"), .credentialRequired)
        XCTAssertTrue(store.activeTools.isEmpty)
    }
}
