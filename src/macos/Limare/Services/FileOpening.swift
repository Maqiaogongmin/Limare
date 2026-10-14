import AppKit
import UniformTypeIdentifiers

/// How Limare opens a file the user clicks: one decision for every file card and file link.
///
/// What the Files surface can preview (`FilePreviewClassifier`) opens there; anything else opens
/// in the Mac's default app for its type, as Finder would. A file that would run when opened (an
/// app, an executable, a script the previewer does not show as code) is only revealed in Finder:
/// a file in a conversation never launches from one click. Supporting a new type in the previewer
/// moves it from the default app to the preview, with nothing to change here.
enum FileOpening {
    enum Route: Equatable {
        /// The Files surface previews it.
        case preview
        /// The system opens it in the default app for its type.
        case defaultApp
        /// Finder shows it selected; nothing is opened.
        case revealInFinder
    }

    /// The route for the file at `url`. `canPreview` is false when the previewer cannot reach the
    /// file (a file outside the workspace), so it goes to the system instead.
    static func route(for url: URL, canPreview: Bool = true) -> Route {
        if canPreview, isPreviewable(url) { return .preview }
        return isLaunchable(url) ? .revealInFinder : .defaultApp
    }

    static func isPreviewable(_ url: URL) -> Bool {
        if case .unsupported = FilePreviewClassifier.classify(url: url) { return false }
        return true
    }

    /// Whether opening `url` would run something rather than show it.
    static func isLaunchable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isExecutableKey, .isDirectoryKey, .contentTypeKey])
        if values?.isApplication == true { return true }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        if let type, [UTType.application, .executable, .script, .shellScript, .applicationBundle].contains(where: type.conforms(to:)) {
            return true
        }
        // An executable bit on a plain file (not a directory, where it only means searchable).
        return values?.isExecutable == true && values?.isDirectory != true
    }

    /// Opens `url` by its route; `preview` shows it in the Files surface.
    @MainActor
    static func open(_ url: URL, canPreview: Bool = true, preview: () -> Void) {
        switch route(for: url, canPreview: canPreview) {
        case .preview:
            preview()
        case .defaultApp:
            NSWorkspace.shared.open(url)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
