import XCTest
@testable import Limare

@MainActor
final class MCPManageAndRemoteLiveTests: XCTestCase {

    private func makeHarness(tempDir: URL) -> (ToolExecutor, MCPStore, InMemoryMCPSecretStore, DebugLogStore) {
        let logs = DebugLogStore(storageRootURL: tempDir, osLogProjection: { _, _, _ in })
        let secretStore = InMemoryMCPSecretStore()
        let mcpStore = MCPStore(logs: logs, storageRootURL: tempDir, secretStore: secretStore)
        let permissions = PermissionStore(logs: logs, initialMode: .fullAccess)
        let workspace = WorkspaceStore(logs: logs)

        let executor = ToolExecutor(
            workspace: workspace,
            permissions: permissions,
            logs: logs,
            mcpStore: mcpStore
        )
        return (executor, mcpStore, secretStore, logs)
    }

    // MARK: - 1. mcp_manage List & Status Tests

    func testMCPManageListAndStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, _, _) = makeHarness(tempDir: tempDir)

        let testServer = MCPServerConfig(
            id: "docs-server",
            note: "Documentation Search Secret Note",
            enabled: true,
            url: "https://example.com/mcp"
        )
        try mcpStore.addOrUpdate(testServer)

        // 1. List: verify server is returned, but note is strictly excluded
        let listCall = ProviderToolCall(
            id: "call_list",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"list\"}")
        )
        let listOutcome = await executor.execute(listCall, onUpdate: { _ in })
        XCTAssertFalse(listOutcome.isError, "mcp_manage(list) should succeed")
        XCTAssertTrue(listOutcome.content.contains("docs-server"))
        XCTAssertTrue(listOutcome.content.contains("https://example.com/mcp") || listOutcome.content.contains("http"))
        XCTAssertFalse(listOutcome.content.contains("Documentation Search Secret Note"), "mcp_manage(list) must not expose note to prevent credential leakage")

        // 2. Status
        let statusCall = ProviderToolCall(
            id: "call_status",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"status\", \"server_id\": \"docs-server\"}")
        )
        let statusOutcome = await executor.execute(statusCall, onUpdate: { _ in })
        XCTAssertFalse(statusOutcome.isError, "mcp_manage(status) should succeed")
        XCTAssertTrue(statusOutcome.content.contains("docs-server"))

        // 3. Status on non-existent server
        let notFoundCall = ProviderToolCall(
            id: "call_not_found",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"status\", \"server_id\": \"nonexistent\"}")
        )
        let notFoundOutcome = await executor.execute(notFoundCall, onUpdate: { _ in })
        XCTAssertTrue(notFoundOutcome.isError)
        XCTAssertTrue(notFoundOutcome.content.contains("not found"))
    }

    // MARK: - 2. Security Gate: Sensitive Parameters & Credentials Refusal

    func testMCPManageSecurityGateRejectsCredentials() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_sec_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, _, _) = makeHarness(tempDir: tempDir)

        // Sensitive key 'token'
        let tokenCall = ProviderToolCall(
            id: "call_sec_1",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"token\": \"ghp_secret\"}")
        )
        let tokenOutcome = await executor.execute(tokenCall, onUpdate: { _ in })
        XCTAssertTrue(tokenOutcome.isError)
        XCTAssertTrue(tokenOutcome.content.contains("Unsupported field 'token'"))

        // Sensitive key 'authorization'
        let authCall = ProviderToolCall(
            id: "call_sec_2",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"authorization\": \"Bearer 123\"}")
        )
        let authOutcome = await executor.execute(authCall, onUpdate: { _ in })
        XCTAssertTrue(authOutcome.isError)
        XCTAssertTrue(authOutcome.content.contains("Unsupported field 'authorization'"))

        // Arbitrary 'note' parameter rejected
        let noteCall = ProviderToolCall(
            id: "call_sec_note",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"http\", \"url\": \"https://example.com/mcp\", \"note\": \"stashed_token_123\"}")
        )
        let noteOutcome = await executor.execute(noteCall, onUpdate: { _ in })
        XCTAssertTrue(noteOutcome.isError)
        XCTAssertTrue(noteOutcome.content.contains("Unsupported field 'note'"))

        // Embedded credentials in URL: user:password
        let userPassCall = ProviderToolCall(
            id: "call_sec_userpass",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"http\", \"url\": \"https://user:password@example.com/mcp\"}")
        )
        let userPassOutcome = await executor.execute(userPassCall, onUpdate: { _ in })
        XCTAssertTrue(userPassOutcome.isError)
        XCTAssertTrue(userPassOutcome.content.contains("must not carry credentials"))

        // Embedded token in URL query
        let urlCall = ProviderToolCall(
            id: "call_sec_3",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"http\", \"url\": \"https://example.com?token=abc123\"}")
        )
        let urlOutcome = await executor.execute(urlCall, onUpdate: { _ in })
        XCTAssertTrue(urlOutcome.isError)
        XCTAssertTrue(urlOutcome.content.contains("must not carry credentials"))

        // Embedded token in command: ghp_, gho_, github_pat_
        let cmdCall = ProviderToolCall(
            id: "call_sec_4",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"stdio\", \"command\": \"ghp_1234567890abcdefghijklmnopqrstuvwxyz\"}")
        )
        let cmdOutcome = await executor.execute(cmdCall, onUpdate: { _ in })
        XCTAssertTrue(cmdOutcome.isError)
        XCTAssertTrue(cmdOutcome.content.contains("Command cannot contain sensitive credentials"))

        let ghoCmdCall = ProviderToolCall(
            id: "call_sec_gho_cmd",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"stdio\", \"command\": \"/usr/bin/tool\", \"args\": [\"--token\", \"gho_1234567890abcdefghijklmnopqrstuvwxyz\"]}")
        )
        let ghoCmdOutcome = await executor.execute(ghoCmdCall, onUpdate: { _ in })
        XCTAssertTrue(ghoCmdOutcome.isError)
        XCTAssertTrue(ghoCmdOutcome.content.contains("Command arguments cannot contain sensitive credentials"))

        let patCmdCall = ProviderToolCall(
            id: "call_sec_pat_cmd",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"test\", \"transport\": \"stdio\", \"command\": \"github_pat_11ABCD_1234567890abcdefghijklmnop\"}")
        )
        let patCmdOutcome = await executor.execute(patCmdCall, onUpdate: { _ in })
        XCTAssertTrue(patCmdOutcome.isError)
        XCTAssertTrue(patCmdOutcome.content.contains("Command cannot contain sensitive credentials"))

        // Sensitive token in server_id
        let badIdCall = ProviderToolCall(
            id: "call_sec_bad_id",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"github_pat_11ABCD_1234567890abcdefghijklmnop\", \"transport\": \"stdio\", \"command\": \"echo\"}")
        )
        let badIdOutcome = await executor.execute(badIdCall, onUpdate: { _ in })
        XCTAssertTrue(badIdOutcome.isError)
        XCTAssertTrue(badIdOutcome.content.contains("Server ID cannot contain sensitive credentials"))

        // Store level validation: addOrUpdate with embedded user:password directly throws invalidURL
        let directBadServer = MCPServerConfig(
            id: "bad-url-server",
            enabled: true,
            url: "https://user:secret@api.example.com/mcp"
        )
        XCTAssertThrowsError(try mcpStore.addOrUpdate(directBadServer)) { error in
            guard let mcpErr = error as? MCPTransportError, case .invalidURL(let msg) = mcpErr else {
                XCTFail("Expected MCPTransportError.invalidURL, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("must not carry credentials"))
        }

        // Store level validation: addOrUpdate with token in ID, command, args throws configurationError
        let badIdServer = MCPServerConfig(id: "gho_1234567890abcdefghijklmnopqrstuvwxyz", enabled: true, command: "echo")
        XCTAssertThrowsError(try mcpStore.addOrUpdate(badIdServer)) { error in
            guard let mcpErr = error as? MCPTransportError, case .configurationError(let msg) = mcpErr else {
                XCTFail("Expected configurationError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Server ID"))
        }

        let badCmdServer = MCPServerConfig(id: "bad-cmd-srv", enabled: true, command: "github_pat_11ABCD_1234567890abcdefghijklmnop")
        XCTAssertThrowsError(try mcpStore.addOrUpdate(badCmdServer)) { error in
            guard let mcpErr = error as? MCPTransportError, case .configurationError(let msg) = mcpErr else {
                XCTFail("Expected configurationError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Command"))
        }

        let badArgsServer = MCPServerConfig(id: "bad-args-srv", enabled: true, command: "echo", args: ["--api-key=test-only"])
        XCTAssertThrowsError(try mcpStore.addOrUpdate(badArgsServer)) { error in
            guard let mcpErr = error as? MCPTransportError, case .configurationError(let msg) = mcpErr else {
                XCTFail("Expected configurationError, got \(error)")
                return
            }
            XCTAssertTrue(msg.contains("Command arguments"))
        }

        // Names that merely resemble a token prefix are not credentials
        XCTAssertNoThrow(try MCPStore.validate(MCPServerConfig(id: "ghp-tools", command: "/usr/local/bin/ghp_token_bin")))
        // A note carrying a credential is rejected, not silently dropped
        XCTAssertThrowsError(try mcpStore.addOrUpdate(MCPServerConfig(id: "noted", note: "Bearer abcdef1234567890", url: "https://example.com/mcp")))
    }

    // MARK: - 3. Conflict Detection

    func testMCPManageConflictDetection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_conflict_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, _, _) = makeHarness(tempDir: tempDir)

        let stdioServer = MCPServerConfig(
            id: "existing-stdio",
            enabled: true,
            command: "echo",
            args: ["hello"]
        )
        try mcpStore.addOrUpdate(stdioServer)

        // Attempting to overwrite existing stdio server with http transport
        let conflictCall = ProviderToolCall(
            id: "call_conflict_1",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"existing-stdio\", \"transport\": \"http\", \"url\": \"https://example.com\"}")
        )
        let conflictOutcome = await executor.execute(conflictCall, onUpdate: { _ in })
        XCTAssertTrue(conflictOutcome.isError)
        XCTAssertTrue(conflictOutcome.content.contains("Cannot overwrite existing stdio server"))

        // The removed GitHub preset is an unsupported field, not a special case
        let presetCall = ProviderToolCall(
            id: "call_conflict_2",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"upsert\", \"server_id\": \"gh\", \"preset\": \"github-remote\"}")
        )
        let presetOutcome = await executor.execute(presetCall, onUpdate: { _ in })
        XCTAssertTrue(presetOutcome.isError)
        XCTAssertTrue(presetOutcome.content.contains("Unsupported field 'preset'"))
    }

    // MARK: - 4. login on a token-header server uses the protected prompt

    /// A connection with a fixed Authorization header authenticates through Limare's protected prompt:
    /// the token never appears in tool output and lands in the secret store as a Bearer header.
    func testMCPManageLoginStoresTokenThroughProtectedPrompt() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_cred_wf_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, secretStore, _) = makeHarness(tempDir: tempDir)
        mcpStore.toolDiscoveryProvider = { _ in [] }
        try mcpStore.addOrUpdate(MCPServerConfig(
            id: "token-srv",
            url: "https://example.com/mcp",
            headers: ["Authorization": MCPServerConfig.makeKeychainReference(key: "Authorization")]
        ))
        let token = "ghp_1234567890abcdefghijklmnopqrstuvwxyz"

        let resolutionTask = Task { @MainActor in
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let req = mcpStore.pendingCredentialRequest {
                    XCTAssertEqual(req.serverID, "token-srv")
                    mcpStore.resolveCredentialRequest(id: req.id, credential: token)
                    return
                }
            }
            XCTFail("Timed out waiting for pendingCredentialRequest")
        }

        let loginCall = ProviderToolCall(
            id: "call_login_token",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"login\", \"server_id\": \"token-srv\"}")
        )
        var updates: [ToolExecutionUpdate] = []
        let outcome = await executor.execute(loginCall, onUpdate: { updates.append($0) })
        try await resolutionTask.value

        XCTAssertFalse(outcome.isError, outcome.content)
        XCTAssertFalse(updates.contains { $0.output.contains(token) }, "Progress events must not reveal the token")
        XCTAssertFalse(outcome.content.contains(token))
        XCTAssertEqual(try secretStore.loadSecret(serverID: "token-srv", key: "header.Authorization"), "Bearer \(token)")
        XCTAssertEqual(mcpStore.status(for: "token-srv"), .connected(toolCount: 0))
    }

    // MARK: - 5. Credential Cancellation

    func testMCPManageCredentialCancellation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_cred_cancel_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, _, _) = makeHarness(tempDir: tempDir)
        mcpStore.toolDiscoveryProvider = { _ in [] }
        try mcpStore.addOrUpdate(MCPServerConfig(
            id: "token-srv",
            url: "https://example.com/mcp",
            headers: ["Authorization": MCPServerConfig.makeKeychainReference(key: "Authorization")]
        ))

        let cancelTask = Task { @MainActor in
            for _ in 0..<50 {
                try await Task.sleep(nanoseconds: 50_000_000)
                if let req = mcpStore.pendingCredentialRequest {
                    mcpStore.resolveCredentialRequest(id: req.id, credential: nil)
                    return
                }
            }
            XCTFail("Timed out waiting for pendingCredentialRequest")
        }

        let loginCall = ProviderToolCall(
            id: "call_cancel_login",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"login\", \"server_id\": \"token-srv\"}")
        )
        let outcome = await executor.execute(loginCall, onUpdate: { _ in })
        try await cancelTask.value

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.content.contains("\"cancelled\""))
        XCTAssertEqual(mcpStore.status(for: "token-srv"), .credentialRequired)
    }

    // MARK: - 6. Credential Generation & Timeout Validation

    func testMCPCredentialRequestGenerationValidation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_gen_val_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, mcpStore, secretStore, _) = makeHarness(tempDir: tempDir)

        let server = MCPServerConfig(id: "test-gen-srv", enabled: true, url: "https://example.com/mcp")
        try mcpStore.addOrUpdate(server)

        // Start request
        let reqTask = Task { @MainActor in
            await mcpStore.requestCredential(serverID: "test-gen-srv", serverName: "Test Server", promptText: "Enter PAT", timeoutSeconds: 5)
        }

        // Wait for request to be queued
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let req = mcpStore.pendingCredentialRequest else {
            XCTFail("Missing pendingCredentialRequest")
            return
        }

        // Advance generation while credential request is pending (simulating concurrent reconnect/edit)
        await mcpStore.reconnect(serverID: "test-gen-srv")

        // Now attempt to resolve with stale generation
        mcpStore.resolveCredentialRequest(id: req.id, credential: "ghp_stale_token")

        let result = await reqTask.value
        XCTAssertNil(result, "Stale generation credential request must be dropped and return nil")

        // Secret store should NOT have stored the stale credential
        let saved = try? secretStore.loadSecret(serverID: "test-gen-srv", key: "header.Authorization")
        XCTAssertNil(saved, "Stale credential must not be saved to secret store")
    }

    func testMCPCredentialRequestTimeout() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_timeout_val_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, mcpStore, _, _) = makeHarness(tempDir: tempDir)

        let server = MCPServerConfig(id: "timeout-srv", enabled: true, url: "https://example.com/mcp")
        try mcpStore.addOrUpdate(server)

        // Request credential with 0.1s timeout
        let result = await mcpStore.requestCredential(
            serverID: "timeout-srv",
            serverName: "Timeout Server",
            promptText: "Enter PAT",
            timeoutSeconds: 0.1
        )
        XCTAssertNil(result, "Timed out credential request must return nil")
        XCTAssertNil(mcpStore.pendingCredentialRequest, "Pending credential request must be cleared after timeout")
    }

    // MARK: - 7. Error Classifier Tests

    func testMCPErrorClassifierCategories() {
        // 401
        let err401 = MCPErrorClassifier.classify(NSError(
            domain: "HTTP",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 401: Unauthorized"]
        ))
        if case .authenticationRequired(let msg) = err401 {
            XCTAssertTrue(msg.contains("401"))
            XCTAssertFalse(msg.contains("GitHub"), "Generic MCP auth failures must not assume a GitHub PAT")
        } else {
            XCTFail("Expected .authenticationRequired, got \(err401)")
        }

        // 403
        let err403 = MCPErrorClassifier.classify(NSError(
            domain: "HTTP",
            code: 403,
            userInfo: [NSLocalizedDescriptionKey: "HTTP 403: Forbidden - Organization policy violation"]
        ))
        if case .accessForbidden(let msg) = err403 {
            XCTAssertTrue(msg.contains("403"))
        } else {
            XCTFail("Expected .accessForbidden, got \(err403)")
        }

        // Timeout
        let timeoutError = URLError(.timedOut)
        let classifiedTimeout = MCPErrorClassifier.classify(timeoutError)
        if case .timeout(let sec) = classifiedTimeout {
            XCTAssertEqual(sec, MCPErrorClassifier.httpRequestTimeoutSeconds)
        } else {
            XCTFail("Expected .timeout, got \(classifiedTimeout)")
        }

        // UI display comes from the failure kind decided at the boundary, not from re-reading messages
        XCTAssertEqual(err401.failureKind, .authentication)
        XCTAssertEqual(MCPErrorClassifier.details(for: .authentication, message: "x").explanation, "Authentication failed")
        XCTAssertEqual(MCPErrorClassifier.details(for: .other, message: "Configuration path could not be read").explanation, "Connection failed")
        XCTAssertEqual(MCPErrorClassifier.classify(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Configuration path could not be read"])).failureKind, .other,
                       "The substring 'pat' in 'path' must not imply an authentication failure")

        let protocolFailure = MCPErrorClassifier.classify(NSError(
            domain: "MCP",
            code: -32600,
            userInfo: [NSLocalizedDescriptionKey: "Missing or invalid protocol session ID"]
        ))
        if case .protocolError = protocolFailure {
            // The generic phrase "missing or invalid" is insufficient to identify a 401.
        } else {
            XCTFail("Expected protocol error, got \(protocolFailure)")
        }
    }

    // MARK: - 9. Delete Atomicity & Rollback Verification

    func testMCPManageDeleteConsistencyAndRollbackOnFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_del_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (executor, mcpStore, secretStore, _) = makeHarness(tempDir: tempDir)

        let server = MCPServerConfig(id: "srv-to-delete", enabled: true, url: "https://example.com/mcp")
        try mcpStore.addOrUpdate(server)
        try mcpStore.commitBearerForTesting("token_123", serverID: "srv-to-delete")

        XCTAssertTrue(mcpStore.servers.contains(where: { $0.id == "srv-to-delete" }))
        XCTAssertTrue(try mcpStore.hasAuthorizationSecret(serverID: "srv-to-delete"))

        // Case 1: Non-existent server delete returns error outcome, not false "removed"
        let notFoundCall = ProviderToolCall(
            id: "call_del_notfound",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"remove\", \"server_id\": \"nonexistent-server\"}")
        )
        let notFoundOutcome = await executor.execute(notFoundCall, onUpdate: { _ in })
        XCTAssertTrue(notFoundOutcome.isError)
        XCTAssertTrue(notFoundOutcome.content.contains("not found"))

        // Case 2: Successful delete via mcp_manage cleans up memory, disk, and secrets
        let delCall = ProviderToolCall(
            id: "call_del_1",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"remove\", \"server_id\": \"srv-to-delete\"}")
        )
        let delOutcome = await executor.execute(delCall, onUpdate: { _ in })
        XCTAssertFalse(delOutcome.isError)
        XCTAssertTrue(delOutcome.content.contains("\"status\":\"removed\"") || delOutcome.content.contains("\"status\": \"removed\""))
        XCTAssertFalse(mcpStore.servers.contains(where: { $0.id == "srv-to-delete" }))
        XCTAssertFalse(try mcpStore.hasAuthorizationSecret(serverID: "srv-to-delete"))

        // Case 3: Persistence failure during delete: memory and secrets must NOT be corrupted
        let unwriteableDir = tempDir.appendingPathComponent("unwriteable_dir")
        try FileManager.default.createDirectory(at: unwriteableDir, withIntermediateDirectories: true)
        let failingStore = MCPStore(logs: DebugLogStore(storageRootURL: unwriteableDir, osLogProjection: { _, _, _ in }), storageRootURL: unwriteableDir, secretStore: secretStore)

        let failServer = MCPServerConfig(id: "srv-fail-persist", enabled: true, url: "https://example.com/mcp")
        try failingStore.addOrUpdate(failServer)
        try failingStore.commitBearerForTesting("secret_token_abc", serverID: "srv-fail-persist")

        // Make storage file unwriteable by creating a directory at mcp_servers.json path
        let serversFile = unwriteableDir.appendingPathComponent("mcp_servers.json")
        try? FileManager.default.removeItem(at: serversFile)
        try FileManager.default.createDirectory(at: serversFile, withIntermediateDirectories: true)

        let failingExecutor = ToolExecutor(
            workspace: WorkspaceStore(logs: DebugLogStore(storageRootURL: unwriteableDir, osLogProjection: { _, _, _ in })),
            permissions: PermissionStore(logs: DebugLogStore(storageRootURL: unwriteableDir, osLogProjection: { _, _, _ in }), initialMode: .fullAccess),
            logs: DebugLogStore(storageRootURL: unwriteableDir, osLogProjection: { _, _, _ in }),
            mcpStore: failingStore
        )

        let failDelCall = ProviderToolCall(
            id: "call_del_fail",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"remove\", \"server_id\": \"srv-fail-persist\"}")
        )
        let failOutcome = await failingExecutor.execute(failDelCall, onUpdate: { _ in })
        XCTAssertTrue(failOutcome.isError, "Delete must return error when disk persistence fails")
        XCTAssertTrue(failOutcome.content.contains("Failed to remove MCP server"))

        // Verify in-memory state and secret store were preserved (no zombie or ghost state)
        XCTAssertTrue(failingStore.servers.contains(where: { $0.id == "srv-fail-persist" }), "Server must remain in memory when disk write fails")
        // Case 4: SecretStore deleteAllSecrets failure during delete: must throw error, rollback disk, and preserve memory!
        let failingSecStore = FailingMCPSecretStore()
        failingSecStore.failDeleteAll = true
        let storeWithFailingSecrets = MCPStore(logs: DebugLogStore(storageRootURL: tempDir, osLogProjection: { _, _, _ in }), storageRootURL: tempDir, secretStore: failingSecStore)
        let srvWithSecretFail = MCPServerConfig(id: "srv-secret-del-fail", enabled: true, url: "https://example.com/mcp")
        try storeWithFailingSecrets.addOrUpdate(srvWithSecretFail)

        XCTAssertThrowsError(try storeWithFailingSecrets.delete(id: "srv-secret-del-fail")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Keychain delete denied"))
        }

        // State recovery assertions (Blocker 2 verification):
        // 1. In-memory state MUST be preserved (server did NOT vanish)
        XCTAssertTrue(storeWithFailingSecrets.servers.contains(where: { $0.id == "srv-secret-del-fail" }),
                      "Server must remain in memory when secret deletion fails (no half-completed delete)")
        // 2. Disk state MUST be rolled back (server exists upon reload)
        let diskCheckStore = MCPStore(logs: DebugLogStore(storageRootURL: tempDir, osLogProjection: { _, _, _ in }), storageRootURL: tempDir, secretStore: InMemoryMCPSecretStore())
        XCTAssertTrue(diskCheckStore.servers.contains(where: { $0.id == "srv-secret-del-fail" }),
                      "Disk file must have rolled back to preserve server when secret deletion fails")

        // Case 5: When secret deletion fails AND disk configuration rollback also fails:
        // Must throw an explicit configurationError mentioning both failures and keep memory aligned with disk
        let doubleFailDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_double_fail_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: doubleFailDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: doubleFailDir)
        }
        let failingSecStore2 = FailingMCPSecretStore()
        failingSecStore2.failDeleteAll = true
        let serversFilePath = doubleFailDir.appendingPathComponent("mcp_servers.json")
        failingSecStore2.onBeforeDeleteAll = {
            // Right after candidateServers is written to disk, corrupt/lock the file path so rollback write throws
            try? FileManager.default.removeItem(at: serversFilePath)
            try? FileManager.default.createDirectory(at: serversFilePath, withIntermediateDirectories: true)
        }
        let doubleFailStore = MCPStore(logs: DebugLogStore(storageRootURL: doubleFailDir, osLogProjection: { _, _, _ in }), storageRootURL: doubleFailDir, secretStore: failingSecStore2)
        let srvDoubleFail = MCPServerConfig(id: "srv-double-fail", enabled: true, url: "https://example.com/mcp")
        try doubleFailStore.addOrUpdate(srvDoubleFail)

        XCTAssertThrowsError(try doubleFailStore.delete(id: "srv-double-fail")) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Failed to delete stored secrets") && desc.contains("disk configuration rollback also failed"),
                          "Error description must explain both failures: \(desc)")
        }
        // Memory state must remain consistent with the fact that disk no longer has the server
        XCTAssertFalse(doubleFailStore.servers.contains(where: { $0.id == "srv-double-fail" }),
                       "Memory must be updated to candidateServers to prevent diverging from disk state")

        // Case 6: MCPStore.delete with Keychain partial deletion failure ("先成功删除一项、再失败")
        // Verifies that when secretStore fails on second secret, first secret is restored,
        // disk configuration rolls back, and memory still retains the server and all secrets!
        let partialMCPDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_partial_delete_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: partialMCPDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partialMCPDir) }

        let partialKCService = "com.limare.test.mcp.partial.\(UUID().uuidString)"
        let partialKCStore = KeychainMCPSecretStore(service: partialKCService, storageRootURL: partialMCPDir)
        let partialMCPStore = MCPStore(logs: DebugLogStore(storageRootURL: partialMCPDir, osLogProjection: { _, _, _ in }), storageRootURL: partialMCPDir, secretStore: partialKCStore)

        let srvPartial = MCPServerConfig(id: "srv-partial-test", enabled: true, url: "https://example.com/mcp")
        try partialMCPStore.addOrUpdate(srvPartial)
        try partialKCStore.saveSecret("sec1_data", serverID: "srv-partial-test", key: "env.SEC1")
        try partialKCStore.saveSecret("sec2_data", serverID: "srv-partial-test", key: "env.SEC2")

        // Fail on second secret during delete
        partialKCStore.itemDeleteHook = { (account: String, count: Int) -> OSStatus? in
            if count == 0 { return nil }
            return errSecAuthFailed
        }

        XCTAssertThrowsError(try partialMCPStore.delete(id: "srv-partial-test"))
        partialKCStore.itemDeleteHook = nil

        // Both secrets must still exist in Keychain!
        XCTAssertEqual(try partialKCStore.loadSecret(serverID: "srv-partial-test", key: "env.SEC1"), "sec1_data", "First secret must be restored after partial delete failure")
        XCTAssertEqual(try partialKCStore.loadSecret(serverID: "srv-partial-test", key: "env.SEC2"), "sec2_data", "Second secret must remain intact")

        // Memory and disk must both retain the server!
        XCTAssertTrue(partialMCPStore.servers.contains(where: { $0.id == "srv-partial-test" }), "Memory must retain server on partial delete failure")
        let reloadStore = MCPStore(logs: DebugLogStore(storageRootURL: partialMCPDir, osLogProjection: { _, _, _ in }), storageRootURL: partialMCPDir, secretStore: partialKCStore)
        XCTAssertTrue(reloadStore.servers.contains(where: { $0.id == "srv-partial-test" }), "Disk must retain server after rollback")
        try partialKCStore.deleteAllSecrets(serverID: "srv-partial-test")

        // Case 7: MCPStore.delete with Keychain partial deletion failure WHERE RESTORE ALSO FAILS
        // ("先成功删除一项、第二项失败、且第一项恢复也失败")
        // Verifies that when restore also fails (unrecoverable credential loss):
        // 1. delete(id:) throws a configuration error describing the restoration failure
        // 2. delete(id:) does NOT roll back to originalServers on disk
        // 3. Memory removes the server (servers = candidateServers) to match disk
        // 4. Runtime state is purged (transports stopped, statuses cleaned up)
        // 5. Reloading from disk confirms the server is NOT present (no ghost server with missing credentials)
        let unrecDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_unrec_delete_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unrecDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrecDir) }

        let unrecKCService = "com.limare.test.mcp.unrec.\(UUID().uuidString)"
        let unrecKCStore = KeychainMCPSecretStore(service: unrecKCService, storageRootURL: unrecDir)
        let unrecMCPStore = MCPStore(logs: DebugLogStore(storageRootURL: unrecDir, osLogProjection: { _, _, _ in }), storageRootURL: unrecDir, secretStore: unrecKCStore)

        let srvUnrec = MCPServerConfig(id: "srv-unrec-test", enabled: true, url: "https://example.com/mcp")
        try unrecMCPStore.addOrUpdate(srvUnrec)
        try unrecKCStore.saveSecret("sec1_data", serverID: "srv-unrec-test", key: "env.SEC1")
        try unrecKCStore.saveSecret("sec2_data", serverID: "srv-unrec-test", key: "env.SEC2")

        // 1st secret delete succeeds, 2nd secret delete fails, and restoring 1st secret ALSO fails!
        unrecKCStore.itemDeleteHook = { (account: String, count: Int) -> OSStatus? in
            if count == 0 { return nil }
            return errSecAuthFailed
        }
        unrecKCStore.itemRestoreHook = { (account: String, count: Int) -> OSStatus? in
            return errSecIO
        }

        XCTAssertThrowsError(try unrecMCPStore.delete(id: "srv-unrec-test")) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("restoring secrets was unsuccessful") || desc.contains("restoring previously deleted secrets also failed"),
                          "Expected error to describe unrecoverable credential restoration failure: \(desc)")
        }
        unrecKCStore.itemDeleteHook = nil
        unrecKCStore.itemRestoreHook = nil

        // Memory must NOT retain the server!
        XCTAssertFalse(unrecMCPStore.servers.contains(where: { $0.id == "srv-unrec-test" }),
                       "Memory must remove server when credentials were lost and cannot be restored")

        // Disk must NOT have rolled back to originalServers (server is removed on disk)
        let unrecReloadStore = MCPStore(logs: DebugLogStore(storageRootURL: unrecDir, osLogProjection: { _, _, _ in }), storageRootURL: unrecDir, secretStore: unrecKCStore)
        XCTAssertFalse(unrecReloadStore.servers.contains(where: { $0.id == "srv-unrec-test" }),
                       "Disk must NOT retain server with lost credentials")

        // Self-convergence verification through the production entry point:
        // 1. Secret 2 still remains in Keychain after the partial deletion failure:
        XCTAssertEqual(try unrecKCStore.loadSecret(serverID: "srv-unrec-test", key: "env.SEC2"), "sec2_data",
                       "Secret 2 must remain in Keychain after first failed deletion")
        XCTAssertTrue(try unrecMCPStore.hasStoredSecrets(serverID: "srv-unrec-test"),
                      "MCPStore must report lingering stored secrets for unlisted server")

        // 2. In production, calling MCPStore.delete(id:) again for this unlisted server must NOT do a no-op return.
        // It must clean up lingering secrets via the production entry point!
        try unrecMCPStore.delete(id: "srv-unrec-test")

        // 3. Assert self-convergence: all secrets are now completely gone from Keychain!
        XCTAssertNil(try unrecKCStore.loadSecret(serverID: "srv-unrec-test", key: "env.SEC1"), "Secret 1 must be gone")
        XCTAssertNil(try unrecKCStore.loadSecret(serverID: "srv-unrec-test", key: "env.SEC2"), "Secret 2 must now be deleted by retry")
        XCTAssertFalse(try unrecMCPStore.hasStoredSecrets(serverID: "srv-unrec-test"), "No lingering secrets remain")

        // 4. Calling delete once more when truly clean does not throw
        try unrecMCPStore.delete(id: "srv-unrec-test")

        // Case 8: ToolExecutor (mcp_manage remove) self-convergence for unlisted server with lingering secrets:
        let toolConvDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_tool_conv_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: toolConvDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: toolConvDir) }

        let (toolConvExec, toolConvMCPStore, toolConvKCStore, _) = makeHarness(tempDir: toolConvDir)
        // Store an orphan secret for a server that does NOT exist in mcpStore.servers
        try toolConvKCStore.saveSecret("lingering_pat", serverID: "lingering-srv", key: "header.Authorization")
        XCTAssertFalse(toolConvMCPStore.servers.contains(where: { $0.id == "lingering-srv" }))
        XCTAssertTrue(try toolConvMCPStore.hasStoredSecrets(serverID: "lingering-srv"))

        // mcp_manage remove must admit the deletion and clean up orphan secrets instead of returning "not found"
        let lingeringRemoveCall = ProviderToolCall(
            id: "call_del_lingering",
            function: .init(name: "mcp_manage", arguments: "{\"action\": \"remove\", \"server_id\": \"lingering-srv\"}")
        )
        let lingeringOutcome = await toolConvExec.execute(lingeringRemoveCall, onUpdate: { _ in })
        XCTAssertFalse(lingeringOutcome.isError, "mcp_manage remove must succeed when cleaning lingering secrets: \(lingeringOutcome.content)")
        XCTAssertTrue(lingeringOutcome.content.contains("\"status\":\"removed\"") || lingeringOutcome.content.contains("\"status\": \"removed\""))
        XCTAssertFalse(try toolConvMCPStore.hasStoredSecrets(serverID: "lingering-srv"), "Lingering secrets must be cleaned up")

        // Now that secrets are truly gone, subsequent remove returns error 'not found'
        let afterCleanOutcome = await toolConvExec.execute(lingeringRemoveCall, onUpdate: { _ in })
        XCTAssertTrue(afterCleanOutcome.isError)
        XCTAssertTrue(afterCleanOutcome.content.contains("not found"))
    }

    func testOrphanSecretLookupFailureIsReportedAndCanBeRetried() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_lookup_failure_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logs = DebugLogStore(storageRootURL: tempDir, osLogProjection: { _, _, _ in })
        let secrets = KeychainMCPSecretStore(service: "com.limare.test.mcp.lookup.\(UUID().uuidString)", storageRootURL: tempDir)
        let store = MCPStore(logs: logs, storageRootURL: tempDir, secretStore: secrets)
        let executor = ToolExecutor(
            workspace: WorkspaceStore(logs: logs),
            permissions: PermissionStore(logs: logs, initialMode: .fullAccess),
            logs: logs,
            mcpStore: store
        )
        try secrets.saveSecret("orphaned-value", serverID: "orphaned-server", key: "env.TOKEN")

        secrets.itemPresenceStatusHook = { errSecInteractionNotAllowed }
        XCTAssertThrowsError(try store.hasStoredSecrets(serverID: "orphaned-server"))

        let removeCall = ProviderToolCall(
            id: "call_orphan_lookup_failure",
            function: .init(name: "mcp_manage", arguments: "{\"action\":\"remove\",\"server_id\":\"orphaned-server\"}")
        )
        let failedOutcome = await executor.execute(removeCall, onUpdate: { _ in })
        XCTAssertTrue(failedOutcome.isError)
        XCTAssertFalse(failedOutcome.content.contains("not found"), "A Keychain lookup failure must not be presented as an absent server")
        XCTAssertEqual(try secrets.loadSecret(serverID: "orphaned-server", key: "env.TOKEN"), "orphaned-value")

        secrets.itemPresenceStatusHook = nil
        let retriedOutcome = await executor.execute(removeCall, onUpdate: { _ in })
        XCTAssertFalse(retriedOutcome.isError, "The production remove entry should clean up after Keychain recovers")
        XCTAssertNil(try secrets.loadSecret(serverID: "orphaned-server", key: "env.TOKEN"))
    }

    // MARK: - 10. SecretStore Failure Fixture

    private final class FailingMCPSecretStore: MCPSecretStoring, @unchecked Sendable {
        var failDeleteAll = false
        var unrecoverableCredentialLoss = false
        var onBeforeDeleteAll: (@Sendable () -> Void)? = nil

        func saveSecret(_ value: String, serverID: String, key: String) throws {
            throw NSError(domain: "SecretStoreError", code: 999, userInfo: [NSLocalizedDescriptionKey: "Keychain write denied."])
        }
        func loadSecret(serverID: String, key: String) throws -> String? { nil }
        func deleteSecret(serverID: String, key: String) throws {}
        func deleteAllSecrets(serverID: String) throws {
            onBeforeDeleteAll?()
            if unrecoverableCredentialLoss {
                throw MCPSecretStoreError.unrecoverablePartialDeletion(
                    serverID: serverID,
                    failedAccount: "\(serverID):brokenKey",
                    deleteStatus: errSecAuthFailed,
                    restoreFailures: [MCPSecretRestoreFailure(account: "\(serverID):prevKey", status: errSecIO)]
                )
            }
            if failDeleteAll {
                throw NSError(domain: "SecretStoreError", code: 998, userInfo: [NSLocalizedDescriptionKey: "Keychain delete denied."])
            }
        }
        func hasStoredSecrets(serverID: String) throws -> Bool { false }
    }

    // MARK: - 11. GUI State Contract on Pause and Steer

    func testGUIStateContractOnPauseAndSteer() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp_gui_contract_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appState = AppState(storageRootURL: tempDir)
        let conv = appState.conversations.newConversation()
        appState.conversations.renameConversation(id: conv.id, title: "Pause GUI Contract")
        appState.conversations.selectConversation(id: conv.id)

        // 1. Initial idle state
        XCTAssertFalse(appState.chat.isStreaming)
        XCTAssertFalse(appState.chat.isPaused)
        XCTAssertFalse(appState.chat.isPausing)

        // 2. Active run state & pause
        let runID = UUID()
        let activeRun = ConversationRun(id: runID, conversationID: conv.id, status: .running)
        appState.conversationRuns.testInjectActiveRun(conv.id, run: activeRun)

        XCTAssertFalse(appState.conversationRuns.isPaused(conversationID: conv.id))
        appState.chat.pause()
        XCTAssertTrue(appState.conversationRuns.isPausing(conversationID: conv.id))
        XCTAssertTrue(appState.chat.isPausing)

        // 3. Resume while pausing clears pausing state
        _ = appState.chat.resume()
        XCTAssertFalse(appState.conversationRuns.isPausing(conversationID: conv.id))
        XCTAssertFalse(appState.chat.isPausing)

        // 4. Run transitions to paused at safe boundary
        let pausedRun = ConversationRun(id: runID, conversationID: conv.id, status: .paused)
        appState.conversationRuns.testInjectActiveRun(conv.id, run: pausedRun)
        XCTAssertTrue(appState.conversationRuns.isPaused(conversationID: conv.id))
        XCTAssertTrue(appState.chat.isPaused)
        XCTAssertFalse(appState.chat.isPausing)

        // 5. Steer message into paused run: steer persists message and auto-resumes run to .running
        let steerMessage = ChatMessage(role: .user, content: "Steer instruction while paused")
        let steered = appState.conversationRuns.steer(conversationID: conv.id, message: steerMessage)
        XCTAssertTrue(steered)
        appState.conversationRuns.markResumingFromNewMessage(conversationID: conv.id)
        let resumed = appState.conversationRuns.resume(conversationID: conv.id)
        XCTAssertTrue(resumed)
        XCTAssertTrue(appState.conversationRuns.isRunning(conversationID: conv.id))
        XCTAssertFalse(appState.chat.isPaused)
    }
}

private extension MCPStore {
    /// The Human token-replacement commit, with a test ticket instead of LocalAuthentication.
    func commitBearerForTesting(_ token: String, serverID: String) throws {
        guard var server = servers.first(where: { $0.id == serverID }) else { throw MCPTransportError.unknownServer(serverID) }
        server.headers = (server.headers ?? [:]).merging(["Authorization": "Bearer \(token)"]) { $1 }
        try addOrUpdate(server, authorization: .forTesting())
    }
}
