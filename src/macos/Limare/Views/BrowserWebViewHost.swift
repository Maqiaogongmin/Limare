import SwiftUI
import WebKit
import AppKit

/// Thin SwiftUI host for an existing `WKWebView` instance owned by `BrowserRuntime`.
/// Never instantiates its own `WKWebView`.
public struct BrowserWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    public init(webView: WKWebView) {
        self.webView = webView
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        if webView.superview != nil {
            webView.removeFromSuperview()
        }
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if webView.superview != nsView {
            if webView.superview != nil {
                webView.removeFromSuperview()
            }
            webView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                webView.topAnchor.constraint(equalTo: nsView.topAnchor),
                webView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor)
            ])
        }
    }
}
