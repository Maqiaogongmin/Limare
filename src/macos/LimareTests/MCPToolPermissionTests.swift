import XCTest
@testable import Limare

@MainActor
final class MCPToolPermissionTests: XCTestCase {
    func testLocalToolApprovalRememberAndRevoke() async throws {
        let suite = "MCPToolPermissionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PermissionStore(logs: DebugLogStore(), defaults: defaults, initialMode: .requestApproval)
        let grant = MCPToolGrant(serverID: "local", toolName: "first", serverFingerprint: "server-v1")
        func request(_ grant: MCPToolGrant) -> ToolPermissionRequest {
            ToolPermissionRequest(toolName: "mcp_tool", summary: "fixture", workspaceURL: nil, mcpTool: grant)
        }
        let pending = Task { await store.authorize(request(grant)) }
        for _ in 0..<100 where store.pendingApproval == nil { await Task.yield() }
        let approval = try XCTUnwrap(store.pendingApproval)
        store.resolvePendingApproval(id: approval.id, approved: true, rememberMCPTool: true)
        let result = await pending.value
        XCTAssertEqual(result, .approved)
        let restored = PermissionStore(logs: DebugLogStore(), defaults: defaults, initialMode: .requestApproval)
        let remembered = await restored.authorize(request(grant))
        XCTAssertEqual(remembered, .notRequired)
        let different = MCPToolGrant(serverID: "local", toolName: "second", serverFingerprint: "server-v1")
        let secondPending = Task { await restored.authorize(request(different)) }
        for _ in 0..<100 where restored.pendingApproval == nil { await Task.yield() }
        let secondApproval = try XCTUnwrap(restored.pendingApproval)
        restored.resolvePendingApproval(id: secondApproval.id, approved: false)
        let secondResult = await secondPending.value
        XCTAssertEqual(secondResult, .denied)
        XCTAssertFalse(restored.mcpToolGrants.contains(MCPToolGrant(serverID: "local", toolName: "first", serverFingerprint: "server-v2")))
        restored.revokeMCPToolGrant(grant)
        XCTAssertTrue(restored.mcpToolGrants.isEmpty)
    }
}
