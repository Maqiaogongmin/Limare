import Foundation
import Darwin

private struct RuntimeFailure: Error, CustomStringConvertible { let description: String }

/// Real processes and sockets against the SDK runtime: process-group termination, request
/// cancellation, list-changed refresh and the Host HTTP policy. Synthetic fixtures only.
@main
struct MCPRuntimeTests {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw RuntimeFailure(description: label) }
        print("PASS \(label)")
    }

    @MainActor
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL MCP runtime: \(error)\n", stderr); exit(1) }
    }

    @MainActor
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[2]).path
        let records = root.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let logs = DebugLogStore(storageRootURL: root, osLogProjection: { _, _, _ in })
        let store = MCPStore(logs: logs, storageRootURL: root, secretStore: InMemoryMCPSecretStore(), workspaceURLProvider: { root })

        // Discovery through the SDK over a supervised stdio child.
        try store.addOrUpdate(MCPServerConfig(id: "fixture", command: "python3", args: ["-u", fixture, "stdio", records.path]))
        await store.refreshTools(for: "fixture")
        try check(store.status(for: "fixture") == .connected(toolCount: 2), "stdio server discovered through the SDK")
        let projection = store.runtimeProjection(for: "fixture")
        try check(projection.transport == "ready" && projection.auth == "anonymous" && projection.identity == "unsupported",
                  "status projects transport, auth and identity separately")

        // The server's initialize instructions reach the model the way Claude Code's "MCP Server
        // Instructions" do: in the system message of the provider request that offers its tools.
        let fixtureInstructions = "Use the typed fixture tools; do not reach for scripts."
        try check(store.instructionsByServer["fixture"] == fixtureInstructions, "initialize instructions are kept per server")
        let promptWorkspace = WorkspaceStore(storageRootURL: root.appendingPathComponent("prompt-ws"), logs: logs)
        let promptPermissions = PermissionStore(logs: logs, defaults: UserDefaults(suiteName: "limare.mcp.runtime.\(UUID().uuidString)")!)
        let coordinator = ConversationRunCoordinator(
            providers: ProviderStore(storageRootURL: root, logs: logs), workspace: promptWorkspace,
            toolExecutor: ToolExecutor(workspace: promptWorkspace, permissions: promptPermissions, logs: logs), logs: logs, mcp: store)
        func systemMessage() -> String {
            guard case .text(let text)? = coordinator.chatRequestHistory(for: UUID()).first?.content else { return "" }
            return text
        }
        try check(systemMessage().contains("# MCP SERVER INSTRUCTIONS") && systemMessage().contains("## fixture\n\(fixtureInstructions)"),
                  "a connected server's instructions are in the provider request")
        // Deferred behind tool_search, the server's tools are still offered, so its instructions stay.
        let many = (0...ConversationRunCoordinator.mcpDeferralThreshold).map {
            MCPTool(serverID: "deferred", name: "t\($0)", description: "", inputSchema: AnyCodable.defaultObjectSchema)
        }
        try store.addOrUpdate(MCPServerConfig(id: "deferred", command: "true"))
        store.simulateDiscoveryForTesting(serverID: "deferred", generation: store.connectionGenerationForTesting(serverID: "deferred"),
                                          tools: many, instructions: String(repeating: "x", count: ConversationRunCoordinator.mcpServerInstructionsLimit + 10))
        let deferredPrompt = systemMessage()
        try check(deferredPrompt.contains("# DEFERRED TOOLS") && deferredPrompt.contains("## deferred\n")
                  && deferredPrompt.contains("[Instructions truncated: showing \(ConversationRunCoordinator.mcpServerInstructionsLimit) of \(ConversationRunCoordinator.mcpServerInstructionsLimit + 10) characters.]"),
                  "deferred servers keep their instructions, bounded with a truncation note")
        store.setEnabled(false, for: "deferred")
        try check(!systemMessage().contains("## deferred\n"), "a disabled server's instructions leave the prompt")

        // Cancelling the Swift task cancels the MCP request and returns promptly.
        let call = Task { try await store.callTool(serverID: "fixture", toolName: "slow", arguments: [:]) }
        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = ContinuousClock.now
        call.cancel()
        _ = try? await call.value
        try check(ContinuousClock.now - cancelledAt < .seconds(2), "a cancelled tool call returns promptly")
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: records.appendingPathComponent("cancelled").path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(FileManager.default.fileExists(atPath: records.appendingPathComponent("cancelled").path),
                  "the server receives notifications/cancelled for the request")

        // tools/list_changed refreshes the catalog once, without polling.
        _ = try await store.callTool(serverID: "fixture", toolName: "grow", arguments: [:])
        for _ in 0..<50 where store.tools(for: "fixture").count != 3 { try await Task.sleep(for: .milliseconds(100)) }
        try check(store.tools(for: "fixture").map(\.name).contains("grown") && store.status(for: "fixture") == .connected(toolCount: 3),
                  "tools/list_changed replaces the catalog with the complete new list")

        // Disconnect terminates the whole process group, descendants included, and reaps the child.
        let grandchild = pid_t(try String(contentsOf: records.appendingPathComponent("grandchild.pid"), encoding: .utf8))!
        try check(kill(grandchild, 0) == 0, "fixture descendant is running before disconnect")
        store.setEnabled(false, for: "fixture")
        for _ in 0..<50 where kill(grandchild, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        try check(kill(grandchild, 0) == -1 && errno == ESRCH, "disabling the server terminates its descendants")

        // A server runs with the user's rights, not the shell's sandbox: one installed outside the
        // workspace and temp writes its own logs folder next to itself (davinci-resolve-mcp does).
        let install = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/limare-mcp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: install) }
        let installed = install.appendingPathComponent("server.py")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: installed)
        let ownLogs = install.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: ownLogs, withIntermediateDirectories: true)
        try store.addOrUpdate(MCPServerConfig(id: "installed", command: "python3", args: ["-u", installed.path, "stdio", ownLogs.path]))
        await store.refreshTools(for: "installed")
        try check(store.status(for: "installed") == .connected(toolCount: 2)
                  && FileManager.default.fileExists(atPath: ownLogs.appendingPathComponent("grandchild.pid").path),
                  "a stdio server writes its own install folder outside the workspace and temp")
        store.setEnabled(false, for: "installed")

        // A fresh user's "connect X" request, driven only through mcp_manage as a model would call it:
        // create → (fails: needs a token) → patch a secret reference → authenticate (secure prompt) → connected.
        let guided = MCPStore(logs: logs, storageRootURL: root.appendingPathComponent("guided"), secretStore: InMemoryMCPSecretStore(),
                              workspaceURLProvider: { root })
        var consented: [UUID] = []
        guided.humanConsentProvider = { id, _ in consented.append(id); return .forTesting(operationID: id) }
        let permissions = PermissionStore(logs: logs, defaults: UserDefaults(suiteName: "limare.mcp.runtime.\(UUID().uuidString)")!, initialMode: .fullAccess)
        let executor = ToolExecutor(workspace: WorkspaceStore(storageRootURL: root.appendingPathComponent("guided-ws"), logs: logs),
                                    permissions: permissions, logs: logs, mcpStore: guided)
        func manage(_ arguments: [String: Any]) async throws -> [String: Any] {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            let outcome = await executor.execute(ProviderToolCall(id: UUID().uuidString, function: .init(name: "mcp_manage", arguments: json))) { _ in }
            return (try? JSONSerialization.jsonObject(with: Data(outcome.content.utf8))) as? [String: Any] ?? ["raw": outcome.content]
        }
        func settle(_ id: String) async throws {
            for _ in 0..<100 where { if case .connecting = guided.status(for: id) { return true }; return false }() {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let description = HarnessToolDefinitions.mcpManageDefinition.function.description
        try check(description.contains("${secret:NAME}") && description.contains("authenticate") && description.contains("cannot install software"),
                  "mcp_manage tells a model how credentials and installation work in Limare")
        var revision = (try await manage(["action": "list"]))["configuration_revision"] as? Int ?? -1
        _ = try await manage(["action": "create", "server_id": "service", "transport": "stdio", "command": "python3",
                              "args": ["-u", fixture, "token", records.path], "expected_revision": revision, "request_id": UUID().uuidString])
        try await settle("service")
        let exited = try await manage(["action": "status", "server_id": "service"])
        try check((exited["next_action"] as? String)?.contains("needs a token") == true && (exited["error"] as? String)?.contains("FIXTURE_TOKEN is not set") == true,
                  "a server that exits without its token tells the model why and what to do next")
        revision = (try await manage(["action": "list"]))["configuration_revision"] as? Int ?? -1
        _ = try await manage(["action": "patch", "server_id": "service", "set": ["env": ["FIXTURE_TOKEN": "${secret:FIXTURE_TOKEN}"]],
                              "expected_revision": revision, "request_id": UUID().uuidString])
        try await settle("service")
        let waiting = try await manage(["action": "status", "server_id": "service"])
        try check(waiting["missing_credentials"] as? [String] == ["FIXTURE_TOKEN"] && waiting["auth_state"] as? String == "signInRequired"
                  && (waiting["next_action"] as? String)?.contains("Call authenticate") == true,
                  "a referenced credential without a value is reported by name with authenticate as the next action")
        revision = (try await manage(["action": "list"]))["configuration_revision"] as? Int ?? -1
        let authenticateRequest = UUID()
        let pending = try await manage(["action": "authenticate", "server_id": "service", "expected_revision": revision, "request_id": authenticateRequest.uuidString])
        try check(pending["outcome"] as? String == "pending", "authenticate on a local server returns a pending receipt")
        for _ in 0..<100 where guided.pendingCredentialRequest == nil { try await Task.sleep(for: .milliseconds(50)) }
        let prompt = guided.pendingCredentialRequest
        try check(prompt?.credentialName == "FIXTURE_TOKEN" && consented == [authenticateRequest],
                  "Limare's secure prompt asks the user for that variable, after a Human ticket bound to the request")
        guided.resolveCredentialRequest(id: prompt!.id, credential: "synthetic-fixture-token")
        for _ in 0..<100 where guided.reportedReceipt(authenticateRequest)?.outcome == .pending { try await Task.sleep(for: .milliseconds(100)) }
        let connected = try await manage(["action": "status", "server_id": "service"])
        try check(connected["status"] as? String == "Connected (2 tools)" && connected["auth_state"] as? String == "authenticated"
                  && connected["missing_credentials"] == nil, "after the user enters it, the server connects with its tools")
        let stored = guided.servers.first(where: { $0.id == "service" })?.env?["FIXTURE_TOKEN"] ?? ""
        try check(MCPServerConfig.isSecretReference(stored) && !"\(connected)".contains("synthetic-fixture-token"),
                  "the value stays out of configuration and every tool result")
        guided.setEnabled(false, for: "service")

        // Optional: the locally installed GitHub server starts and lists tools. No
        // token is configured, so it makes no authenticated GitHub call.
        let githubServer = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/github-mcp-server")
        if ProcessInfo.processInfo.environment["LIMARE_GITHUB_MCP_SMOKE"] == "1", FileManager.default.isExecutableFile(atPath: githubServer) {
            let github = MCPConnection(config: MCPServerConfig(id: "github-smoke", command: githubServer, args: ["stdio", "--read-only"]),
                                       workspaceURL: root) { _ in }
            try await github.ensureConnected()
            let tools = try await github.listTools()
            await github.stop()
            try check(!tools.isEmpty, "github-mcp-server --read-only starts and lists \(tools.count) tools through the SDK")
        }

        // HTTP: a redirect is refused, so the configured credential never reaches another origin.
        let portFile = root.appendingPathComponent("redirect.port")
        let received = root.appendingPathComponent("redirect-target.jsonl")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", fixture, "redirect", portFile.path, received.path]
        try server.run()
        defer { server.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(100)) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let connection = MCPConnection(config: MCPServerConfig(id: "redirect", url: "http://127.0.0.1:\(port)/mcp",
                                                               headers: ["Authorization": "Bearer synthetic-redirect-canary"]),
                                       workspaceURL: root) { _ in }
        do {
            try await connection.ensureConnected()
            throw RuntimeFailure(description: "redirecting endpoint accepted")
        } catch is MCPTransportError { }
        await connection.stop()
        let leaked = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
        try check(leaked.isEmpty, "a redirect is refused and the credential header never reaches the redirect target")
    }
}
