import Foundation
import WebKit
import AppKit

/// Core WebKit browser runtime for Limare.
/// Owns a single `WKWebView` instance per session and executes browser actions serially.
@MainActor
final class BrowserRuntime: NSObject, WKNavigationDelegate, WKUIDelegate {

    private(set) var webView: WKWebView
    private(set) var currentURL: String = ""
    private(set) var pageTitle: String = ""
    private(set) var isLoading: Bool = false

    var onStateChange: (@MainActor (BrowserRuntimeState) -> Void)?

    private func publishState() {
        let state = BrowserRuntimeState(
            currentURL: currentURL,
            pageTitle: pageTitle,
            isLoading: isLoading
        )
        onStateChange?(state)
    }

    private let attachmentStore: AttachmentStore
    private let artifactStore: ArtifactStore?
    private let logs: DebugLogStore
    private var navigationGeneration = 0
    private var activeNavigation: (generation: Int, navigation: WKNavigation?, continuation: CheckedContinuation<Void, Error>)?
    private var pendingDownloadError: BrowserRuntimeError?
    private var activeActionTask: Task<BrowserActionResult, Error>?

    static let defaultViewport = CGSize(width: 1280, height: 800)
    static let navigationTimeout: TimeInterval = 30.0

    public typealias SnapshotProvider = @MainActor () async throws -> NSImage
    public var snapshotProvider: SnapshotProvider?

    init(
        websiteDataStore: WKWebsiteDataStore? = nil,
        attachmentStore: AttachmentStore? = nil,
        artifactStore: ArtifactStore? = nil,
        logs: DebugLogStore? = nil,
        snapshotProvider: SnapshotProvider? = nil
    ) {
        let store = websiteDataStore ?? BrowserWebsiteDataStore.shared.websiteDataStore
        self.attachmentStore = attachmentStore ?? AttachmentStore()
        self.artifactStore = artifactStore
        self.logs = logs ?? DebugLogStore()
        self.snapshotProvider = snapshotProvider

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let frame = CGRect(origin: .zero, size: Self.defaultViewport)
        self.webView = WKWebView(frame: frame, configuration: config)
        self.webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        super.init()

        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    // MARK: - Execute Action (Serialized)

    public func execute(input: BrowserActionInput, conversationID: UUID? = nil) async throws -> BrowserActionResult {
        try Task.checkCancellation()

        // Wait for any existing action to finish or cancel
        if let existing = activeActionTask {
            _ = try? await existing.value
        }

        let task = Task { @MainActor () -> BrowserActionResult in
            try Task.checkCancellation()
            return try await self.performAction(input, conversationID: conversationID)
        }
        self.activeActionTask = task

        defer {
            if self.activeActionTask == task {
                self.activeActionTask = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performAction(_ input: BrowserActionInput, conversationID: UUID? = nil) async throws -> BrowserActionResult {
        switch input.action {
        case .navigate:
            return try await navigate(to: input.url)
        case .getPageInfo:
            return try await getPageInfo()
        case .getText:
            return try await getText(selector: input.selector)
        case .getReadable:
            return try await getReadable()
        case .findElements:
            return try await findElements(selector: input.selector)
        case .click:
            return try await click(selector: input.selector)
        case .type:
            return try await type(selector: input.selector, text: input.text)
        case .scroll:
            return try await scroll(direction: input.direction ?? .down, amount: input.amount ?? 600)
        case .screenshot:
            return try await screenshot(conversationID: conversationID)
        case .waitForDomStable:
            return try await waitForDomStable(timeoutSeconds: input.timeoutSeconds ?? 10)
        }
    }

    // MARK: - Navigate

    /// Loads a web page, or a local file the way browsers open one: WebKit may read the file's
    /// folder, so a built page finds its scripts, styles and images beside it.
    @discardableResult
    func load(_ url: URL) -> WKNavigation? {
        if url.isFileURL {
            return webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: Self.navigationTimeout))
    }

    /// A local file named by `file://`, an absolute path or `~/`, as a browser's address bar
    /// takes them; nil for anything else.
    nonisolated static func localFileURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("file://") {
            return URL(string: trimmed).flatMap { $0.isFileURL && !$0.path.isEmpty ? $0 : nil }
        }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    /// Why a local file cannot be opened: missing, a folder, or one of Limare's reserved paths.
    nonisolated static func localFileProblem(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return "File not found: \(url.path)"
        }
        if isDirectory.boolValue { return "\(url.path) is a folder; open a file in it, such as index.html." }
        do { try MCPInfrastructureBoundary.requireAgentFileAccess(to: url) }
        catch { return "\(url.path) is in Limare's reserved data and cannot be opened." }
        return nil
    }

    public func navigate(to urlString: String?) async throws -> BrowserActionResult {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .error("Missing 'url' parameter.")
        }

        let url: URL
        if let fileURL = Self.localFileURL(raw) {
            if let problem = Self.localFileProblem(fileURL) { return .error(problem) }
            url = fileURL
        } else {
            var normalized = raw
            if !normalized.contains("://") {
                normalized = "https://\(normalized)"
            }

            guard let parsed = URL(string: normalized), let scheme = parsed.scheme?.lowercased() else {
                return .error("Invalid URL: '\(raw)'.")
            }

            guard ["http", "https"].contains(scheme) else {
                return .error("Unsupported URL scheme '\(scheme)://'. Use http://, https:// or a local file (file:// or an absolute path).")
            }

            // Host check
            guard let host = parsed.host, !host.isEmpty else {
                return .error("Invalid URL host for: '\(raw)'.")
            }
            url = parsed
        }

        navigationGeneration += 1
        let currentGen = navigationGeneration
        isLoading = true
        pendingDownloadError = nil
        publishState()

        let wkNav = load(url)

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(Self.navigationTimeout * 1_000_000_000))
            await MainActor.run {
                if let nav = self.activeNavigation, nav.generation == currentGen {
                    self.activeNavigation = nil
                    self.webView.stopLoading()
                    self.isLoading = false
                    self.publishState()
                    nav.continuation.resume(throwing: BrowserRuntimeError.navigationTimeout(url.absoluteString))
                }
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.activeNavigation = (generation: currentGen, navigation: wkNav, continuation: cont)
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelCurrentAction()
                }
            }
            timeoutTask.cancel()
        } catch is CancellationError {
            timeoutTask.cancel()
            webView.stopLoading()
            isLoading = false
            publishState()
            throw CancellationError()
        } catch let error as BrowserRuntimeError {
            timeoutTask.cancel()
            webView.stopLoading()
            isLoading = false
            publishState()
            return .error(error.localizedDescription, code: error.code)
        } catch {
            timeoutTask.cancel()
            webView.stopLoading()
            isLoading = false
            publishState()
            return .error("Navigation error: \(error.localizedDescription)")
        }

        // Short settle delay
        try? await Task.sleep(nanoseconds: 120_000_000)

        currentURL = webView.url?.absoluteString ?? url.absoluteString
        pageTitle = webView.title ?? ""
        isLoading = false
        publishState()

        let payload: [String: Any] = [
            "status": "ok",
            "action": "navigate",
            "url": currentURL,
            "title": pageTitle
        ]

        return .ok(payload)
    }

    // MARK: - Page Info

    private func getPageInfo() async throws -> BrowserActionResult {
        try await evaluateAsyncScript(BrowserDOMScripts.pageInfoScript)
    }

    // MARK: - Get Text

    private func getText(selector: String?) async throws -> BrowserActionResult {
        var args: [String: Any] = [:]
        if let s = selector { args["selector"] = s }
        return try await evaluateAsyncScript(BrowserDOMScripts.getTextScript, arguments: args)
    }

    // MARK: - Get Readable

    private func getReadable() async throws -> BrowserActionResult {
        try await evaluateAsyncScript(BrowserDOMScripts.getReadableScript)
    }

    // MARK: - Find Elements

    private func findElements(selector: String?) async throws -> BrowserActionResult {
        var args: [String: Any] = [:]
        if let s = selector { args["selector"] = s }
        return try await evaluateAsyncScript(BrowserDOMScripts.findElementsScript, arguments: args)
    }

    // MARK: - Click

    private func click(selector: String?) async throws -> BrowserActionResult {
        guard let sel = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return .error("click requires a non-empty 'selector'.")
        }

        navigationGeneration += 1
        let currentGen = navigationGeneration
        pendingDownloadError = nil

        let jsResult = try await evaluateAsyncScript(BrowserDOMScripts.clickScript, arguments: ["selector": sel])
        if jsResult.isError {
            return jsResult
        }

        // Wait up to 200ms to see if navigation or download starts
        var waitedNs: UInt64 = 0
        let stepNs: UInt64 = 20_000_000 // 20ms
        while !self.isLoading && !self.webView.isLoading && self.pendingDownloadError == nil && waitedNs < 200_000_000 {
            try? await Task.sleep(nanoseconds: stepNs)
            waitedNs += stepNs
        }

        if let dlError = pendingDownloadError {
            pendingDownloadError = nil
            return .error(dlError.localizedDescription, code: dlError.code)
        }

        if self.isLoading || self.webView.isLoading {
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(Self.navigationTimeout * 1_000_000_000))
                await MainActor.run {
                    if let nav = self.activeNavigation, nav.generation == currentGen {
                        self.activeNavigation = nil
                        self.webView.stopLoading()
                        self.isLoading = false
                        nav.continuation.resume(throwing: BrowserRuntimeError.navigationTimeout(self.currentURL))
                    }
                }
            }

            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        if !self.isLoading && !self.webView.isLoading {
                            cont.resume()
                            return
                        }
                        if let dlError = self.pendingDownloadError {
                            self.pendingDownloadError = nil
                            cont.resume(throwing: dlError)
                            return
                        }
                        self.activeNavigation = (generation: currentGen, navigation: nil, continuation: cont)
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        self?.cancelCurrentAction()
                    }
                }
                timeoutTask.cancel()
            } catch is CancellationError {
                timeoutTask.cancel()
                webView.stopLoading()
                isLoading = false
                throw CancellationError()
            } catch let error as BrowserRuntimeError {
                timeoutTask.cancel()
                webView.stopLoading()
                isLoading = false
                return .error(error.localizedDescription, code: error.code)
            } catch {
                timeoutTask.cancel()
                webView.stopLoading()
                isLoading = false
                return .error("Navigation error: \(error.localizedDescription)")
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
            currentURL = webView.url?.absoluteString ?? currentURL
            if let t = webView.title, !t.isEmpty {
                pageTitle = t
            } else if let docTitle = try? await webView.evaluateJavaScript("document.title") as? String, !docTitle.isEmpty {
                pageTitle = docTitle
            }
            isLoading = false

            return .ok([
                "status": "ok",
                "action": "click",
                "clicked": true,
                "selector": sel,
                "navigated": true,
                "url": currentURL,
                "title": pageTitle
            ])
        }

        // Pure DOM mutation without navigation
        if let newURL = webView.url?.absoluteString, newURL != currentURL {
            currentURL = newURL
            pageTitle = webView.title ?? ""
        }
        return jsResult
    }

    // MARK: - Type

    private func type(selector: String?, text: String?) async throws -> BrowserActionResult {
        guard let sel = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return .error("type requires a non-empty 'selector'.")
        }
        guard let textToType = text else {
            return .error("type requires 'text'.")
        }

        return try await evaluateAsyncScript(BrowserDOMScripts.typeScript, arguments: ["selector": sel, "text": textToType])
    }

    // MARK: - Scroll

    private func scroll(direction: BrowserScrollDirection, amount: Int) async throws -> BrowserActionResult {
        return try await evaluateAsyncScript(BrowserDOMScripts.scrollScript, arguments: ["direction": direction.rawValue, "amount": amount])
    }

    // MARK: - Screenshot

    private func screenshot(conversationID: UUID? = nil) async throws -> BrowserActionResult {
        let image: NSImage
        do {
            if let customProvider = snapshotProvider {
                image = try await customProvider()
            } else {
                let config = WKSnapshotConfiguration()
                image = try await webView.takeSnapshot(configuration: config)
            }
        } catch {
            return .error("Screenshot capture failed: \(error.localizedDescription)")
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return .error("Failed to encode screenshot as PNG.")
        }

        let attachment: ChatAttachment
        do {
            attachment = try attachmentStore.saveGeneratedImage(data: pngData, suggestedFilename: "Screenshot.png")
        } catch {
            return .error("Failed to store screenshot: \(error.localizedDescription)")
        }

        guard let store = artifactStore else {
            attachmentStore.deleteAttachment(attachment)
            return .error("ArtifactStore is unavailable for screenshot artifactization.")
        }
        guard let convID = conversationID else {
            attachmentStore.deleteAttachment(attachment)
            return .error("Active conversation scope is required for screenshot artifactization.")
        }

        let artifactDescriptor: ArtifactDescriptor
        do {
            artifactDescriptor = try store.save(
                data: pngData,
                conversationID: convID,
                filename: "Screenshot.png",
                mimeType: "image/png",
                producerProvenance: .browserScreenshot,
                retentionClass: .temporaryExtraction
            )
        } catch {
            attachmentStore.deleteAttachment(attachment)
            logs.error("Browser", "Failed to save screenshot artifact: \(error.localizedDescription)")
            return .error("Failed to save screenshot artifact: \(error.localizedDescription)")
        }

        // Verify task not cancelled; clean orphan if cancelled
        if Task.isCancelled {
            attachmentStore.deleteAttachment(attachment)
            throw CancellationError()
        }

        let filename = (attachment.relativePath as NSString).lastPathComponent
        let uri = "limare://attachments/\(filename)"

        let imageDict: [String: Any] = [
            "path": uri,
            "mime_type": "image/png",
            "width": attachment.width ?? Int(image.size.width),
            "height": attachment.height ?? Int(image.size.height),
            "artifact_id": artifactDescriptor.artifactID.uuidString
        ]

        let payload: [String: Any] = [
            "status": "ok",
            "action": "screenshot",
            "url": webView.url?.absoluteString ?? currentURL,
            "image": imageDict
        ]

        let resultParts: [ToolResultPart] = [
            .artifact(id: artifactDescriptor.artifactID, semanticRole: .screenshot, mimeType: "image/png")
        ]

        return .ok(payload, attachments: [attachment], resultParts: resultParts)
    }

    // MARK: - Wait for DOM Stable

    private func waitForDomStable(timeoutSeconds: Int) async throws -> BrowserActionResult {
        let maxTimeout = min(max(timeoutSeconds, 1), 20)
        _ = try? await webView.evaluateJavaScript(BrowserDOMScripts.setupMutationObserver())

        let intervalNs: UInt64 = 300_000_000 // 300ms
        let maxIterations = max(1, Int(Double(maxTimeout) / 0.3))

        var lastMutationCount = -1
        var stableCount = 0
        var timedOut = true

        for _ in 0..<maxIterations {
            try Task.checkCancellation()
            try? await Task.sleep(nanoseconds: intervalNs)

            let countRaw = try? await webView.evaluateJavaScript("window.__limareDomMutations || 0")
            let count = (countRaw as? NSNumber)?.intValue ?? (countRaw as? Int) ?? 0

            if count == lastMutationCount {
                stableCount += 1
                if stableCount >= 2 { // 600ms of consecutive zero changes
                    timedOut = false
                    break
                }
            } else {
                stableCount = 0
                lastMutationCount = count
            }
        }

        return .ok([
            "status": "ok",
            "action": "wait_for_dom_stable",
            "stable": !timedOut,
            "timed_out": timedOut
        ])
    }

    // MARK: - Script Helpers

    private func evaluateAsyncScript(_ script: String, arguments: [String: Any] = [:]) async throws -> BrowserActionResult {
        do {
            let result: Any? = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            if let dict = result as? [String: Any] {
                if let errorMsg = dict["error"] as? String {
                    return .error(errorMsg, code: dict["code"] as? String)
                }
                return .ok(dict)
            } else if let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorMsg = dict["error"] as? String {
                    return .error(errorMsg, code: dict["code"] as? String)
                }
                return .ok(dict)
            }
            return .error("Unexpected response from webpage.")
        } catch {
            return .error("JavaScript execution error: \(error.localizedDescription)")
        }
    }

    // MARK: - Cancellation, Focus & Teardown

    public func resignWebViewFocus() {
        if let window = webView.window {
            window.makeFirstResponder(nil)
        }
    }

    public func cancelCurrentAction() {
        activeActionTask?.cancel()
        activeActionTask = nil
        webView.stopLoading()
        isLoading = false
        publishState()
        if let nav = activeNavigation {
            activeNavigation = nil
            nav.continuation.resume(throwing: CancellationError())
        }
    }

    public func teardown() {
        cancelCurrentAction()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        currentURL = ""
        pageTitle = ""
        isLoading = false
        publishState()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if #available(macOS 11.3, *) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.cancel)
                self.isLoading = false
                self.publishState()
                if let nav = activeNavigation, nav.generation == navigationGeneration {
                    activeNavigation = nil
                    nav.continuation.resume(throwing: BrowserRuntimeError.downloadNotSupported)
                } else {
                    pendingDownloadError = .downloadNotSupported
                }
                return
            }
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" && url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        // Local files: WebKit limits them to the folder granted when the file was opened.
        guard ["http", "https", "file"].contains(scheme),
              scheme != "file" || Self.localFileProblem(url) == nil else {
            decisionHandler(.cancel)
            return
        }

        // Single Tab policy: If link has target="_blank" / nil targetFrame, open in current frame
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        var isDownload = !navigationResponse.canShowMIMEType
        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            let headers = httpResponse.allHeaderFields
            for (key, value) in headers {
                if let keyStr = key as? String, keyStr.caseInsensitiveCompare("Content-Disposition") == .orderedSame {
                    if let valStr = value as? String, valStr.lowercased().contains("attachment") {
                        isDownload = true
                        break
                    }
                }
            }
        }

        if isDownload {
            decisionHandler(.cancel)
            self.isLoading = false
            self.publishState()
            if let nav = activeNavigation, nav.generation == navigationGeneration {
                activeNavigation = nil
                nav.continuation.resume(throwing: BrowserRuntimeError.downloadNotSupported)
            } else {
                pendingDownloadError = .downloadNotSupported
            }
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        publishState()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? pageTitle
        publishState()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = webView.isLoading
        currentURL = webView.url?.absoluteString ?? currentURL
        if let t = webView.title, !t.isEmpty {
            pageTitle = t
        }
        publishState()

        guard let nav = activeNavigation,
              nav.generation == navigationGeneration,
              (nav.navigation == nil || nav.navigation === navigation) else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let title = try? await self.webView.evaluateJavaScript("document.title") as? String, !title.isEmpty {
                    self.pageTitle = title
                    self.publishState()
                }
            }
            return
        }
        activeNavigation = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let title = try? await self.webView.evaluateJavaScript("document.title") as? String, !title.isEmpty {
                self.pageTitle = title
                self.publishState()
            }
            nav.continuation.resume()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = webView.isLoading
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? pageTitle
        publishState()

        guard let nav = activeNavigation,
              nav.generation == navigationGeneration,
              (nav.navigation == nil || nav.navigation === navigation) else {
            return
        }
        activeNavigation = nil
        nav.continuation.resume(throwing: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = webView.isLoading
        currentURL = webView.url?.absoluteString ?? currentURL
        pageTitle = webView.title ?? pageTitle
        publishState()

        guard let nav = activeNavigation,
              nav.generation == navigationGeneration,
              (nav.navigation == nil || nav.navigation === navigation) else {
            return
        }
        activeNavigation = nil
        nav.continuation.resume(throwing: error)
    }

    // MARK: - WKUIDelegate (Dialog policies)

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        completionHandler(false)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        completionHandler(nil)
    }
}
