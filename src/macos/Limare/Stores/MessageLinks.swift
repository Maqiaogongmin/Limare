import AppKit
import Foundation

/// Links in rendered Markdown: what a link's destination names, and where a click on it goes.
enum MessageLinks {
    /// What a clicked link opens.
    enum Target: Equatable {
        /// A web page, in its own Work Surface browser tab.
        case web(URL)
        /// An existing local file, opened as `FileOpening` decides.
        case file(URL)
        /// Anything else, such as mailto:, and a web link ⌘-clicked: the system opens it.
        case system(URL)
    }

    /// The URL a link's destination names, as written: autolinks and `[text](url)` destinations
    /// arrive as strings, and one without a scheme stays relative (a file path or a bare host,
    /// told apart by `target`). A destination that is only a fragment ("#part") names nothing.
    static func url(forDestination destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        return URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: $0) }
    }

    /// Where a click on `url` goes. A scheme-less destination is a file when one exists there
    /// (relative to the workspace), else a web address when it starts with a host
    /// ("example.com/page"), else nothing.
    static func target(
        for url: URL,
        workspaceURL: URL?,
        inDefaultBrowser: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Target? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return inDefaultBrowser ? .system(url) : .web(url)
        case "file":
            // ⌘ does not apply to files: `FileOpening` decides how each opens.
            return fileExists(url) ? .file(url.standardizedFileURL) : nil
        case nil:
            let path = url.path(percentEncoded: false)
            if let fileURL = fileURL(forPath: path, workspaceURL: workspaceURL), fileExists(fileURL) {
                return .file(fileURL)
            }
            let host = url.relativeString.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            guard host.contains("."), !host.hasPrefix("."),
                  let web = URL(string: "https://" + url.relativeString)
            else { return nil }
            return inDefaultBrowser ? .system(web) : .web(web)
        default:
            return .system(url)
        }
    }

    private static func fileURL(forPath path: String, workspaceURL: URL?) -> URL? {
        guard !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return workspaceURL.map { $0.appendingPathComponent(path).standardizedFileURL }
    }
}

extension AppState {
    /// The Work Surface tab a link opens in: one per link, so opening another link never
    /// replaces a page already open, and opening the same link again returns to its tab.
    static func linkBrowserContentID(for url: URL) -> String {
        "link:" + url.absoluteString
    }

    /// Opens a link clicked in a message (see `MessageLinks.Target`). A web link opens in its own
    /// Work Surface browser tab, the user's to use; the agent's shared browser is never
    /// navigated, so a click never takes it away from a run.
    func openMessageLink(_ url: URL, inDefaultBrowser: Bool = false) {
        let workspaceURL = conversations.activeConversationID.map {
            conversations.effectiveWorkingDirectory(for: $0)
        } ?? workspace.url
        switch MessageLinks.target(for: url, workspaceURL: workspaceURL, inDefaultBrowser: inDefaultBrowser) {
        case let .web(webURL):
            openLinkInBrowserTab(webURL)
        case let .file(fileURL):
            // The Files surface previews only the workspace; other files go to the system.
            let inWorkspace = workspaceURL.map { WorkspacePathResolver.isInsideWorkspace(fileURL, workspaceURL: $0) } ?? false
            FileOpening.open(fileURL, canPreview: inWorkspace) { previewWorkspaceFile(fileURL) }
        case let .system(systemURL):
            NSWorkspace.shared.open(systemURL)
        case nil:
            logs.info("Links", "Nothing to open for link '\(url.relativeString)'.")
        }
    }

    private func openLinkInBrowserTab(_ url: URL) {
        let contentID = Self.linkBrowserContentID(for: url)
        if workSurface.additionalBrowsers[contentID] != nil {
            workSurface.open(kind: .browser, contentID: contentID)
            return
        }
        let rt = BrowserRuntime(
            websiteDataStore: browser.websiteDataStore,
            attachmentStore: attachments,
            artifactStore: artifacts,
            logs: logs,
            snapshotProvider: browser.snapshotProvider
        )
        let tab = BrowserTab(
            conversationID: UUID(),
            runtime: rt,
            owner: .user
        )
        workSurface.additionalBrowsers[contentID] = tab
        workSurface.open(kind: .browser, contentID: contentID, title: url.host() ?? WorkSurfaceKind.browser.defaultTitle)
        tab.navigateByUser(to: url)
    }
}
