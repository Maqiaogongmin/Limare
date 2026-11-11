import XCTest
@testable import Limare

@MainActor
final class BrowserSitePermissionTests: XCTestCase {
    func testOriginAndConversationScopedGrant() async throws {
        XCTAssertEqual(ToolExecutor.browserSite("example.com/a"), "https://example.com")
        XCTAssertEqual(ToolExecutor.browserSite("https://EXAMPLE.com:8443/a?q=secret"), "https://example.com:8443")
        XCTAssertNil(ToolExecutor.browserSite("file:///tmp/example.html"))
        let suite = "BrowserSitePermissionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PermissionStore(logs: DebugLogStore(), defaults: defaults, initialMode: .requestApproval)
        let conversation = UUID(), other = UUID()
        func request(_ id: UUID, _ site: String) -> ToolPermissionRequest {
            ToolPermissionRequest(conversationID: id, toolName: "browser_use", summary: "Scroll", workspaceURL: nil,
                                  requestsNetwork: true, browserSite: site)
        }
        let pending = Task { await store.authorize(request(conversation, "https://example.com")) }
        for _ in 0..<100 where store.pendingApproval == nil { await Task.yield() }
        let approval = try XCTUnwrap(store.pendingApproval)
        store.resolvePendingApproval(id: approval.id, approved: true, rememberBrowserSite: true)
        let first = await pending.value
        XCTAssertEqual(first, .approved)
        let same = await store.authorize(request(conversation, "https://example.com"))
        XCTAssertEqual(same, .notRequired)
        let next = Task { await store.authorize(request(conversation, "https://other.example")) }
        for _ in 0..<100 where store.pendingApproval == nil { await Task.yield() }
        let nextApproval = try XCTUnwrap(store.pendingApproval)
        store.resolvePendingApproval(id: nextApproval.id, approved: false)
        let nextResult = await next.value
        XCTAssertEqual(nextResult, .denied)
        XCTAssertNil(store.browserSiteGrants[other])
        store.revokeBrowserSite("https://example.com", conversationID: conversation)
        XCTAssertNil(store.browserSiteGrants[conversation])
    }
}
