import Foundation
import Observation
import WebKit
import AppKit

/// One page in a conversation's browser, or a browser the user opened beside it.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    let conversationID: UUID
    /// The tab's number in its conversation, the `tab_id` the agent names it by. Numbers are not
    /// reused, so a number the model saw earlier never points at a different page.
    var number: Int
    var runtime: BrowserRuntime
    var owner: BrowserControlOwner = .agent
    var controlGeneration: Int = 0
    var lastUsedAt: Date = Date()

    var currentURL: String = ""
    var title: String = ""
    var isLoading: Bool = false

    var canGoBack: Bool { runtime.webView.canGoBack }
    var canGoForward: Bool { runtime.webView.canGoForward }
    var hasSession: Bool { !currentURL.isEmpty }
    var allowsUserInteraction: Bool { owner == .user }

    var activeExecutionTask: Task<BrowserActionResult, Error>?
    var activeRuntimeActionID: UUID?
    var activeAction: String?

    init(
        conversationID: UUID,
        runtime: BrowserRuntime,
        owner: BrowserControlOwner = .agent,
        number: Int = 1,
        controlGeneration: Int = 0,
        lastUsedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.number = number
        self.runtime = runtime
        self.owner = owner
        self.controlGeneration = controlGeneration
        self.lastUsedAt = lastUsedAt
        self.bindRuntime(runtime)
    }

    func bindRuntime(_ rt: BrowserRuntime) {
        rt.onStateChange = { [weak self, weak rt] state in
            guard let self, self.runtime === rt else { return }
            self.currentURL = state.currentURL
            self.title = state.pageTitle
            self.isLoading = state.isLoading
        }
    }

    /// What the agent reads about this tab in `list_tabs` and in results while several are open.
    func summary(isCurrent: Bool) -> [String: Any] {
        var entry: [String: Any] = ["tab_id": number, "url": currentURL, "title": title]
        if isCurrent { entry["current"] = true }
        if owner == .user { entry["controlled_by"] = "user" }
        return entry
    }

    func takeControl(logs: DebugLogStore? = nil) {
        guard owner != .user else { return }
        controlGeneration += 1
        runtime.cancelCurrentAction()
        activeExecutionTask?.cancel()
        activeExecutionTask = nil
        owner = .user
        lastUsedAt = Date()
        logs?.info("Browser", "Browser control switched to USER for conversation \(conversationID).")
    }

    func returnToAgent(logs: DebugLogStore? = nil) {
        guard owner != .agent else { return }
        controlGeneration += 1
        owner = .agent
        runtime.resignWebViewFocus()
        lastUsedAt = Date()
        logs?.info("Browser", "Browser control returned to AGENT for conversation \(conversationID).")
    }

    func goBack() {
        takeControl()
        if runtime.webView.canGoBack {
            runtime.webView.goBack()
        }
    }

    func goForward() {
        takeControl()
        if runtime.webView.canGoForward {
            runtime.webView.goForward()
        }
    }

    func reload() {
        takeControl()
        runtime.webView.reload()
    }

    func navigateByUser(to url: URL) {
        takeControl()
        runtime.load(url)
    }

    func openInExternalBrowser() {
        guard let url = URL(string: currentURL), ["http", "https", "file"].contains(url.scheme?.lowercased()) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func teardown() {
        activeExecutionTask?.cancel()
        activeExecutionTask = nil
        activeRuntimeActionID = nil
        activeAction = nil
        runtime.cancelCurrentAction()
        runtime.teardown()
    }
}

/// One conversation's browser tabs, in the order they opened.
@MainActor
@Observable
final class BrowserTabGroup {
    var tabs: [BrowserTab] = []
    /// The tab the agent's page actions act on.
    var currentTabID: UUID?
    /// The tab the Browser panel shows: the agent's current tab, until the person picks another.
    var shownTabID: UUID?
    var nextNumber = 1
    /// Said once at the head of the agent's next browser result.
    var pendingNotices: [String] = []

    var currentTab: BrowserTab? { tabs.first { $0.id == currentTabID } }
    var shownTab: BrowserTab? { tabs.first { $0.id == shownTabID } ?? currentTab }
    func tab(number: Int) -> BrowserTab? { tabs.first { $0.number == number } }
}

/// Manages the lifecycle of each conversation's browser tabs. All tabs share the common
/// persistent `WKWebsiteDataStore`, so a site signed in to in one is signed in to in all.
@MainActor
@Observable
final class BrowserSessionStore {

    /// Live agent tabs across all conversations: Limare owns their WebKit processes.
    var maxLiveTabs: Int = 8
    private(set) var groups: [UUID: BrowserTabGroup] = [:]
    /// Conversations some window shows: their agent tabs are never evicted.
    var displayedConversationIDs: Set<UUID> = []
    /// The one displayed conversation, for callers that know a single window.
    var displayedConversationID: UUID? {
        get { displayedConversationIDs.first }
        set { displayedConversationIDs = newValue.map { [$0] } ?? [] }
    }
    var hasActiveRun: (@MainActor (UUID) -> Bool)?

    let websiteDataStore: WKWebsiteDataStore
    private let attachmentStore: AttachmentStore
    private let artifactStore: ArtifactStore?
    private let logs: DebugLogStore

    public var snapshotProvider: (@MainActor () async throws -> NSImage)? {
        didSet {
            for tab in allTabs {
                tab.runtime.snapshotProvider = snapshotProvider
            }
        }
    }

    init(
        websiteDataStore: WKWebsiteDataStore? = nil,
        attachmentStore: AttachmentStore? = nil,
        artifactStore: ArtifactStore? = nil,
        logs: DebugLogStore? = nil,
        snapshotProvider: (@MainActor () async throws -> NSImage)? = nil,
        maxLiveTabs: Int = 8
    ) {
        let l = logs ?? DebugLogStore()
        let store = websiteDataStore ?? BrowserWebsiteDataStore.shared.websiteDataStore
        let attStore = attachmentStore ?? AttachmentStore()
        self.websiteDataStore = store
        self.attachmentStore = attStore
        self.artifactStore = artifactStore
        self.logs = l
        self.snapshotProvider = snapshotProvider
        self.maxLiveTabs = maxLiveTabs
    }

    var allTabs: [BrowserTab] { groups.values.flatMap(\.tabs) }
    var liveTabCount: Int { allTabs.count }

    func tabs(for conversationID: UUID) -> [BrowserTab] {
        groups[conversationID]?.tabs ?? []
    }

    /// The conversation's current tab, the one the agent's page actions act on.
    func tab(for conversationID: UUID) -> BrowserTab? {
        groups[conversationID]?.currentTab
    }

    /// The tab the Browser panel shows for the conversation.
    func shownTab(for conversationID: UUID) -> BrowserTab? {
        groups[conversationID]?.shownTab
    }

    func hasSession(for conversationID: UUID) -> Bool {
        tabs(for: conversationID).contains { $0.hasSession }
    }

    @discardableResult
    func getOrCreateTab(for conversationID: UUID) throws -> BrowserTab {
        if let current = tab(for: conversationID) {
            return current
        }
        return try openTab(for: conversationID)
    }

    /// Opens a blank tab in the conversation and shows it. It becomes the agent's current tab
    /// unless `makesCurrent` is false (a tab the person opens) and the conversation has one.
    @discardableResult
    func openTab(for conversationID: UUID, owner: BrowserControlOwner = .agent, makesCurrent: Bool = true) throws -> BrowserTab {
        try makeRoom()
        let group = self.group(for: conversationID)
        let tab = BrowserTab(conversationID: conversationID, runtime: makeRuntime(), owner: owner, number: group.nextNumber)
        add(tab, to: group)
        if makesCurrent || group.currentTab == nil { group.currentTabID = tab.id }
        group.shownTabID = tab.id
        return tab
    }

    /// The panel shows `tab`; the agent's current tab stays where it is.
    func show(_ tab: BrowserTab) {
        groups[tab.conversationID]?.shownTabID = tab.id
    }

    /// Closes a tab the person closed in the panel.
    func closeByUser(_ tab: BrowserTab) {
        close(tab, reason: "closed_by_user")
    }

    private func group(for conversationID: UUID) -> BrowserTabGroup {
        if let group = groups[conversationID] { return group }
        let group = BrowserTabGroup()
        groups[conversationID] = group
        return group
    }

    private func makeRuntime(configuration: WKWebViewConfiguration? = nil) -> BrowserRuntime {
        BrowserRuntime(
            websiteDataStore: websiteDataStore,
            attachmentStore: attachmentStore,
            artifactStore: artifactStore,
            logs: logs,
            snapshotProvider: snapshotProvider,
            configuration: configuration,
            opensWindows: true
        )
    }

    private func add(_ tab: BrowserTab, to group: BrowserTabGroup) {
        group.nextNumber = max(group.nextNumber, tab.number) + 1
        group.tabs.append(tab)
        bindWindows(of: tab)
    }

    /// A page's new window opens as a tab next to it; `window.close()` closes the tab.
    private func bindWindows(of tab: BrowserTab) {
        tab.runtime.onOpenWindow = { [weak self, weak tab] configuration in
            guard let self, let tab else { return nil }
            return self.openWindow(from: tab, configuration: configuration)
        }
        tab.runtime.onCloseWindow = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.close(tab, reason: "closed_by_page")
        }
    }

    /// The window's tab takes over from its opener: it becomes current if the opener was, and
    /// shown if the opener was, as a browser switches to a tab a link opens.
    private func openWindow(from opener: BrowserTab, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard let group = groups[opener.conversationID], group.tabs.contains(where: { $0 === opener }) else { return nil }
        do { try makeRoom() } catch { return nil }
        let wasCurrent = group.currentTabID == opener.id
        let wasShown = group.shownTab === opener
        let tab = BrowserTab(conversationID: opener.conversationID, runtime: makeRuntime(configuration: configuration),
                             owner: opener.owner, number: group.nextNumber)
        add(tab, to: group)
        if wasCurrent { group.currentTabID = tab.id }
        if wasShown { group.shownTabID = tab.id }
        logs.info("Browser", "Page opened tab \(tab.number) for conversation \(opener.conversationID).")
        return tab.runtime.webView
    }

    /// Closes the least recently used idle tab when all tabs are live.
    private func makeRoom() throws {
        guard liveTabCount >= maxLiveTabs else { return }
        guard let victim = evictionCandidate() else {
            throw BrowserSessionStoreError.capacityExceeded
        }
        close(victim, reason: "evicted")
        logs.info("Browser", "Evicted idle browser tab \(victim.number) for conversation \(victim.conversationID).")
    }

    /// Removes a tab. Its conversation's next browser result says so, unless the agent closed it
    /// itself (`reason` nil).
    private func close(_ tab: BrowserTab, reason: String?) {
        guard let group = groups[tab.conversationID], group.tabs.contains(where: { $0 === tab }) else { return }
        group.tabs.removeAll { $0 === tab }
        tab.teardown()
        if group.currentTabID == tab.id {
            group.currentTabID = group.tabs.max { $0.lastUsedAt < $1.lastUsedAt }?.id
        }
        if group.shownTabID == tab.id { group.shownTabID = nil }
        guard let reason else { return }
        if group.tabs.isEmpty {
            group.pendingNotices = ["Your previous browser page was closed (\(reason)). Navigate again if you still need it."]
        } else if let current = group.currentTab {
            group.pendingNotices.append("Browser tab \(tab.number) was closed (\(reason)); the current tab is \(current.number).")
        }
    }

    func preflight(conversationID: UUID, action: BrowserAction = .getPageInfo) -> BrowserActionResult? {
        if action.managesTabs {
            if action == .newTab, liveTabCount >= maxLiveTabs, evictionCandidate() == nil {
                return .capacityExceeded()
            }
            return nil
        }
        if let tab = tab(for: conversationID) {
            if tab.owner == .user {
                return .pausedForUserControl()
            }
            return nil
        }

        if liveTabCount >= maxLiveTabs, evictionCandidate() == nil {
            return .capacityExceeded()
        }
        return nil
    }

    /// The tab to close for a new one: a tab whose conversation no window shows and has no run in
    /// progress. A page the user navigated is kept while its conversation is on screen; once it is
    /// not, it goes after the agent's own pages, least recently used first. Protecting it for good
    /// let six such pages lock every conversation out of the browser.
    private func evictionCandidate() -> BrowserTab? {
        allTabs
            .filter { tab in
                self.hasActiveRun?(tab.conversationID) != true
                    && !self.displayedConversationIDs.contains(tab.conversationID)
            }
            .min { lhs, rhs in
                let lhsUser = lhs.owner == .user, rhsUser = rhs.owner == .user
                return lhsUser != rhsUser ? !lhsUser : lhs.lastUsedAt < rhs.lastUsedAt
            }
    }

    /// The result as the agent reads it: the session fields; the conversation's tabs when it has
    /// several or the action was about tabs; then any notice about tabs closed without it.
    func evidence(_ result: BrowserActionResult, conversationID: UUID, action: BrowserAction? = nil) -> BrowserActionResult {
        let group = groups[conversationID]
        let current = group?.currentTab
        var finalResult = result.sessionEvidence(ownerConversationID: conversationID, generation: current?.controlGeneration ?? 0, reset: nil)

        let tabs = group?.tabs ?? []
        if tabs.count > 1 || action?.managesTabs == true {
            var fields: [String: Any] = ["tabs": tabs.map { $0.summary(isCurrent: $0.id == group?.currentTabID) }]
            if let current { fields["current_tab"] = current.number }
            finalResult = finalResult.addingFields(fields)
        }

        if let group, !group.pendingNotices.isEmpty {
            finalResult = finalResult.prependingNotice(group.pendingNotices.joined(separator: " "))
            group.pendingNotices = []
        }

        return finalResult
    }

    func execute(input: BrowserActionInput, conversationID: UUID) async throws -> BrowserActionResult {
        try Task.checkCancellation()
        if let refusal = preflight(conversationID: conversationID, action: input.action) {
            return evidence(refusal, conversationID: conversationID, action: input.action)
        }
        if input.action.managesTabs {
            let outcome = try await manageTabs(input, conversationID: conversationID)
            return evidence(outcome, conversationID: conversationID, action: input.action)
        }

        let tab: BrowserTab
        do {
            tab = try getOrCreateTab(for: conversationID)
        } catch {
            return evidence(.capacityExceeded(), conversationID: conversationID)
        }
        let outcome = try await perform(input, on: tab, conversationID: conversationID)
        return evidence(outcome, conversationID: conversationID, action: input.action)
    }

    private func manageTabs(_ input: BrowserActionInput, conversationID: UUID) async throws -> BrowserActionResult {
        let group = groups[conversationID]
        switch input.action {
        case .newTab:
            let tab: BrowserTab
            do { tab = try openTab(for: conversationID) } catch { return .capacityExceeded() }
            guard let url = input.url else { return .ok(["action": "new_tab", "tab_id": tab.number]) }
            let navigation = try await perform(.init(action: .navigate, url: url), on: tab, conversationID: conversationID)
            return navigation.addingFields(["action": "new_tab", "tab_id": tab.number])
        case .switchTab:
            guard let number = input.tabID, let group, let tab = group.tab(number: number) else {
                return .error("No browser tab \(input.tabID.map(String.init) ?? "") in this conversation. Use list_tabs to see its tabs.")
            }
            group.currentTabID = tab.id
            group.shownTabID = tab.id
            tab.lastUsedAt = Date()
            return .ok(["action": "switch_tab", "tab_id": tab.number, "url": tab.currentURL, "title": tab.title])
        case .closeTab:
            guard let group, let tab = input.tabID.map({ group.tab(number: $0) }) ?? group.currentTab else {
                return .error("No browser tab \(input.tabID.map(String.init) ?? "") in this conversation. Use list_tabs to see its tabs.")
            }
            guard tab.owner == .agent else {
                return .error("The user controls tab \(tab.number); leave it open for them.", code: "user_has_control")
            }
            close(tab, reason: nil)
            return .ok(["action": "close_tab", "closed_tab": tab.number])
        default:
            return .ok(["action": input.action.rawValue])
        }
    }

    /// Runs a page action on `tab`, after any action queued on it. If the page opens a tab that
    /// becomes current, the result names it once that tab has loaded.
    private func perform(_ input: BrowserActionInput, on tab: BrowserTab, conversationID: UUID) async throws -> BrowserActionResult {
        tab.lastUsedAt = Date()
        let currentControlGen = tab.controlGeneration
        let previousTask = tab.activeExecutionTask
        let actionID = UUID()

        let task = Task { @MainActor () -> BrowserActionResult in
            _ = try? await previousTask?.value
            guard tab.owner == .agent, tab.controlGeneration == currentControlGen else {
                self.logs.info("Browser", "Agent action '\(input.action.rawValue)' aborted because USER took control while action was queued.")
                return tab.owner == .user ? .pausedForUserControl() : .notDispatched(status: "session_reset", reason: "generation_changed", disposition: .sessionReset)
            }
            try Task.checkCancellation()

            tab.activeAction = input.action.rawValue
            tab.activeRuntimeActionID = actionID
            defer {
                if tab.activeRuntimeActionID == actionID {
                    tab.activeRuntimeActionID = nil
                    tab.activeAction = nil
                }
            }

            let startedAt = ContinuousClock.now
            let outcome = try await tab.runtime.execute(input: input, conversationID: conversationID)
            let elapsed = startedAt.duration(to: .now)
            let durationMs = Int(elapsed.components.seconds * 1_000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
            guard tab.controlGeneration == currentControlGen else {
                return .error("Browser session changed while the action was in flight.", code: "session_reset")
            }
            let scope = conversationID.uuidString
            self.logs.info("Browser", "Action '\(input.action.rawValue)' completed in \(durationMs)ms (conversation: \(scope), error: \(outcome.isError)).")
            return outcome
        }

        tab.activeExecutionTask = task
        defer {
            if tab.activeExecutionTask == task {
                tab.activeExecutionTask = nil
            }
        }

        let outcome: BrowserActionResult
        do {
            outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
                Task { @MainActor [weak tab] in
                    guard tab?.activeRuntimeActionID == actionID else { return }
                    tab?.runtime.cancelCurrentAction()
                }
            }
        } catch is CancellationError where !Task.isCancelled && groups[conversationID]?.tabs.contains(where: { $0 === tab }) != true {
            // The page closed its own tab (`window.close()`) during the action; the run goes on.
            outcome = .ok(["action": input.action.rawValue, "closed_tab": tab.number])
        }

        guard let opened = groups[conversationID]?.currentTab, opened !== tab, opened.number > tab.number else {
            return outcome
        }
        try await waitForLoad(of: opened)
        return outcome.addingFields(["opened_tab": opened.number, "url": opened.currentURL, "title": opened.title])
    }

    /// Waits, at most a navigation's timeout, for a tab a page opened to load its first page.
    private func waitForLoad(of tab: BrowserTab) async throws {
        let deadline = ContinuousClock.now + .seconds(BrowserRuntime.navigationTimeout)
        while (tab.isLoading || tab.currentURL.isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Clearing a conversation leaves it one blank tab; its other tabs close.
    func resetSession(ownedBy conversationID: UUID) {
        guard let group = groups[conversationID], let tab = group.currentTab ?? group.tabs.last else {
            return
        }
        for other in group.tabs where other !== tab {
            other.teardown()
        }
        tab.controlGeneration += 1
        tab.activeExecutionTask?.cancel()
        tab.activeExecutionTask = nil
        tab.activeRuntimeActionID = nil
        tab.activeAction = nil
        tab.runtime.teardown()
        tab.owner = .agent
        tab.currentURL = ""
        tab.title = ""
        tab.isLoading = false
        tab.number = 1

        let newRuntime = makeRuntime()
        tab.runtime = newRuntime
        tab.bindRuntime(newRuntime)
        group.tabs = []
        group.nextNumber = 1
        add(tab, to: group)
        group.currentTabID = tab.id
        group.shownTabID = tab.id
        group.pendingNotices = ["Your previous browser page was closed (cleared). Navigate again if you still need it."]
        logs.info("Browser", "Browser session reset for conversation \(conversationID).")
    }

    func releaseSession(ownedBy conversationID: UUID) {
        guard let group = groups.removeValue(forKey: conversationID) else {
            return
        }
        for tab in group.tabs {
            tab.teardown()
        }
        logs.info("Browser", "Browser session released for conversation \(conversationID).")
    }

    func cancelActions(ownedBy conversationID: UUID) {
        for tab in tabs(for: conversationID) {
            tab.activeExecutionTask?.cancel()
            if tab.activeRuntimeActionID != nil {
                tab.runtime.cancelCurrentAction()
            }
        }
    }

    func cancelAll() {
        for tab in allTabs {
            tab.activeExecutionTask?.cancel()
            tab.runtime.cancelCurrentAction()
        }
    }

}

enum BrowserSessionStoreError: Error {
    case capacityExceeded
}
