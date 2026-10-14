import Foundation
import WebKit
import Observation

/// Sandbox configuration and navigation policy enforcing strictly passive, read-only previews
/// with zero JavaScript execution and zero outbound HTTP/HTTPS network requests.
/// Implements strict Fail-Closed security: will NEVER produce a configuration without the blocking rule list.
@MainActor
@Observable
public final class PassivePreviewSandbox {
    public static let shared = PassivePreviewSandbox()

    public private(set) var isReady: Bool = false
    public private(set) var compilationFailed: Bool = false
    private var compiledRuleList: WKContentRuleList?
    private var compilationTask: Task<WKContentRuleList?, Never>?

    public init() {
        startCompilation()
    }

    private func startCompilation() {
        compilationTask = Task { @MainActor in
            let ruleJSON = """
            [
                {
                    "trigger": { "url-filter": "^https?://.*" },
                    "action": { "type": "block" }
                }
            ]
            """
            do {
                let list = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "LimarePassivePreviewBlockRemote_\(UUID().uuidString)",
                    encodedContentRuleList: ruleJSON
                )
                self.compiledRuleList = list
                self.isReady = true
                return list
            } catch {
                self.compilationFailed = true
                return nil
            }
        }
    }

    /// Ensures that the remote blocking content rule list is compiled and ready.
    public func ensureCompiled() async {
        if compiledRuleList != nil { return }
        if let task = compilationTask {
            self.compiledRuleList = await task.value
            if self.compiledRuleList != nil {
                self.isReady = true
            }
        } else {
            startCompilation()
            self.compiledRuleList = await compilationTask?.value
            if self.compiledRuleList != nil {
                self.isReady = true
            }
        }
    }

    /// Creates a dedicated, isolated, non-persistent WKWebViewConfiguration with:
    /// 1. Non-persistent website data store (isolated from agent and user cookies/storage).
    /// 2. JavaScript completely disabled.
    /// 3. Outbound HTTP/HTTPS network blocking rule list attached.
    ///
    /// - Returns: `WKWebViewConfiguration` if and only if the blocking rule list is compiled and attached.
    ///   Returns `nil` (Fail-Closed) if the rule list is compiling or unavailable.
    public func makeConfiguration() -> WKWebViewConfiguration? {
        guard let ruleList = compiledRuleList else {
            return nil // Fail closed: never create an unrestricted or un-sandboxed WebView
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(ruleList)
        return config
    }

    /// Async convenience returning a guaranteed safe configuration once compilation finishes.
    public func ensureConfiguration() async -> WKWebViewConfiguration? {
        await ensureCompiled()
        return makeConfiguration()
    }
}

/// Navigation delegate that strictly forbids external network requests and navigation
/// to HTTP/HTTPS destinations.
public final class PassiveNavigationDelegate: NSObject, WKNavigationDelegate {
    public override init() {
        super.init()
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // Strictly allow local file, about, and data schemes. Reject http, https, and custom schemes.
        if url.isFileURL || url.scheme == "about" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
