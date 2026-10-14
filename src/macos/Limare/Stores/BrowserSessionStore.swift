import Foundation
import Observation
import WebKit
import AppKit

/// Represents an independent browser tab owned by a specific conversation.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let conversationID: UUID
    var runtime: BrowserRuntime
    var owner: BrowserControlOwner = .agent
    var controlGeneration: Int = 0
    var lastUsedAt: Date = Date()
    var pendingNotice: String? = nil

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
        controlGeneration: Int = 0,
        lastUsedAt: Date = Date(),
        pendingNotice: String? = nil
    ) {
        self.id = conversationID
        self.conversationID = conversationID
        self.runtime = runtime
        self.owner = owner
        self.controlGeneration = controlGeneration
        self.lastUsedAt = lastUsedAt
        self.pendingNotice = pendingNotice
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

/// Manages the lifecycle, tabs, and per-conversation browser runtimes for Limare.
/// Ensures each conversation has at most one independent browser tab, sharing
/// the common persistent `WKWebsiteDataStore`.
@MainActor
@Observable
final class BrowserSessionStore {

    var maxLiveTabs: Int = 6
    private(set) var tabs: [UUID: BrowserTab] = [:]
    var displayedConversationID: UUID?
    var hasActiveRun: (@MainActor (UUID) -> Bool)?


    private var pendingNotices: [UUID: String] = [:]

    let websiteDataStore: WKWebsiteDataStore
    private let attachmentStore: AttachmentStore
    private let artifactStore: ArtifactStore?
    private let logs: DebugLogStore

    public var snapshotProvider: (@MainActor () async throws -> NSImage)? {
        didSet {
            for tab in tabs.values {
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
        maxLiveTabs: Int = 6
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

    func tab(for conversationID: UUID) -> BrowserTab? {
        tabs[conversationID]
    }

    func hasSession(for conversationID: UUID) -> Bool {
        tabs[conversationID]?.hasSession == true
    }

    @discardableResult
    func getOrCreateTab(for conversationID: UUID) throws -> BrowserTab {
        if let existing = tabs[conversationID] {
            return existing
        }

        if tabs.count >= maxLiveTabs {
            let candidateTabs = tabs.values.filter { tab in
                let hasRun = self.hasActiveRun?(tab.conversationID) == true
                let isUserControl = tab.owner == .user
                let isDisplayed = tab.conversationID == self.displayedConversationID
                return !hasRun && !isUserControl && !isDisplayed
            }

            guard let victim = candidateTabs.min(by: { $0.lastUsedAt < $1.lastUsedAt }) else {
                throw BrowserSessionStoreError.capacityExceeded
            }

            victim.activeExecutionTask?.cancel()
            victim.runtime.teardown()
            tabs.removeValue(forKey: victim.conversationID)
            pendingNotices[victim.conversationID] = "evicted"
            logs.info("Browser", "Evicted idle browser tab for conversation \(victim.conversationID).")
        }

        let rt = BrowserRuntime(
            websiteDataStore: websiteDataStore,
            attachmentStore: attachmentStore,
            artifactStore: artifactStore,
            logs: logs,
            snapshotProvider: snapshotProvider
        )

        let notice = pendingNotices.removeValue(forKey: conversationID)
        let newTab = BrowserTab(
            conversationID: conversationID,
            runtime: rt,
            owner: .agent,
            controlGeneration: 0,
            lastUsedAt: Date(),
            pendingNotice: notice
        )
        tabs[conversationID] = newTab
        return newTab
    }

    func preflight(conversationID: UUID) -> BrowserActionResult? {
        if let tab = tabs[conversationID] {
            if tab.owner == .user {
                return .pausedForUserControl()
            }
            return nil
        }

        if tabs.count >= maxLiveTabs {
            let canEvict = tabs.values.contains { tab in
                let hasRun = self.hasActiveRun?(tab.conversationID) == true
                let isUserControl = tab.owner == .user
                let isDisplayed = tab.conversationID == self.displayedConversationID
                return !hasRun && !isUserControl && !isDisplayed
            }
            if !canEvict {
                return .capacityExceeded()
            }
        }
        return nil
    }

    func evidence(_ result: BrowserActionResult, conversationID: UUID) -> BrowserActionResult {
        let gen = tabs[conversationID]?.controlGeneration ?? 0
        var finalResult = result.sessionEvidence(ownerConversationID: conversationID, generation: gen, reset: nil)

        if let tab = tabs[conversationID], let notice = tab.pendingNotice {
            let prefix = "Your previous browser page was closed (\(notice)). Navigate again if you still need it."
            finalResult = finalResult.prependingNotice(prefix)
            tab.pendingNotice = nil
        }

        return finalResult
    }

    func execute(input: BrowserActionInput, conversationID: UUID) async throws -> BrowserActionResult {
        try Task.checkCancellation()
        if let refusal = preflight(conversationID: conversationID) {
            return evidence(refusal, conversationID: conversationID)
        }

        let tab: BrowserTab
        do {
            tab = try getOrCreateTab(for: conversationID)
        } catch {
            return evidence(.capacityExceeded(), conversationID: conversationID)
        }

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

        return try await withTaskCancellationHandler {
            let outcome = try await task.value
            return evidence(outcome, conversationID: conversationID)
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak tab] in
                guard tab?.activeRuntimeActionID == actionID else { return }
                tab?.runtime.cancelCurrentAction()
            }
        }
    }


    func resetSession(ownedBy conversationID: UUID) {
        guard let tab = tabs[conversationID] else {
            return
        }
        tab.controlGeneration += 1
        tab.activeExecutionTask?.cancel()
        tab.activeExecutionTask = nil
        tab.activeRuntimeActionID = nil
        tab.activeAction = nil
        tab.runtime.teardown()
        tab.owner = .agent
        tab.pendingNotice = "cleared"
        tab.currentURL = ""
        tab.title = ""
        tab.isLoading = false

        let newRuntime = BrowserRuntime(
            websiteDataStore: websiteDataStore,
            attachmentStore: attachmentStore,
            artifactStore: artifactStore,
            logs: logs,
            snapshotProvider: snapshotProvider
        )
        tab.runtime = newRuntime
        tab.bindRuntime(newRuntime)
        logs.info("Browser", "Browser session reset for conversation \(conversationID).")
    }

    func releaseSession(ownedBy conversationID: UUID) {
        pendingNotices.removeValue(forKey: conversationID)
        guard let tab = tabs.removeValue(forKey: conversationID) else {
            return
        }
        tab.activeExecutionTask?.cancel()
        tab.activeExecutionTask = nil
        tab.activeRuntimeActionID = nil
        tab.activeAction = nil
        tab.runtime.teardown()
        logs.info("Browser", "Browser session released for conversation \(conversationID).")
    }

    func cancelActions(ownedBy conversationID: UUID) {
        guard let tab = tabs[conversationID] else { return }
        tab.activeExecutionTask?.cancel()
        if tab.activeRuntimeActionID != nil {
            tab.runtime.cancelCurrentAction()
        }
    }

    func cancelAll() {
        for tab in tabs.values {
            tab.activeExecutionTask?.cancel()
            tab.runtime.cancelCurrentAction()
        }
    }

}

enum BrowserSessionStoreError: Error {
    case capacityExceeded
}
