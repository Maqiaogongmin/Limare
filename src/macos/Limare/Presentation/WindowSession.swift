import AppKit
import Observation

/// What one window presents: its conversation (through a ChatStore of its own), its Work
/// Surface and Files, and whether it shows the chat or Settings. Runs, conversations and every
/// other store belong to the app and are shared by all windows.
@MainActor
@Observable
final class WindowSession: Identifiable {
    /// The scene every Limare window belongs to.
    static let sceneID = "conversation"

    let id = UUID()
    let chat: ChatStore
    let workSurface: WorkSurfaceStore
    let files: FilesSurfaceStore
    var screen: AppScreen = .chat
    /// Bumped by the Focus Composer command; the composer makes its editor first responder.
    var composerFocusRequest = 0
    /// The last request a composer acted on. A request made from Settings is acted on when the
    /// chat's composer appears.
    @ObservationIgnored var composerFocusServed = 0
    @ObservationIgnored weak var app: AppState?
    /// The AppKit window presenting this session, once it is on screen.
    @ObservationIgnored weak var hostWindow: NSWindow?

    init(chat: ChatStore) {
        self.chat = chat
        self.workSurface = WorkSurfaceStore()
        self.files = FilesSurfaceStore()
    }

    var conversationID: UUID? { chat.viewedConversationID }
    var conversation: ConversationRecord? { chat.viewedConversation }

    /// Shows a conversation. Leaving another one stops what belonged to it in this window:
    /// dictation into this composer, reading one of its messages aloud, and the Computer Use
    /// session if that conversation holds it. Other windows are not touched.
    func show(_ record: ConversationRecord) {
        guard let app else {
            chat.loadConversation(record)
            return
        }
        if let leaving = chat.lastLoadedConversationID, leaving != record.id {
            if app.voiceInput.isTarget(chat) { app.voiceInput.cancel() }
            if let playing = app.voiceOutput.state.activeMessageID, chat.messages.contains(where: { $0.id == playing }) {
                app.voiceOutput.stop()
            }
            app.conversationRuns.resetForConversationBoundary(leaving: leaving)
        }
        chat.loadConversation(record)
        if app.focusedWindow === self, app.conversations.activeConversationID != record.id {
            app.conversations.activeConversationID = record.id
        }
        syncFilesRoot()
        app.windowContentChanged()
    }

    /// Files follow the effective working directory of the window's conversation. File tabs
    /// belong to a workspace: they close when it changes, and stay open when the next
    /// conversation works in the same one.
    func syncFilesRoot() {
        guard let app else { return }
        let root = conversationID.map { app.conversations.effectiveWorkingDirectory(for: $0) }
        if root != files.rootURL {
            workSurface.clearFilePreviews()
        }
        files.setRootURL(root)
    }

    // MARK: - Work Surface

    func addSurface(_ kind: WorkSurfaceKind) {
        guard let app else { return }
        if kind == .browser {
            if !workSurface.tabs.contains(where: { $0.kind == .browser }) {
                workSurface.openBrowser()
            } else {
                let key = UUID().uuidString
                let rt = BrowserRuntime(
                    websiteDataStore: app.browser.websiteDataStore,
                    attachmentStore: app.attachments,
                    artifactStore: app.artifacts,
                    logs: app.logs,
                    snapshotProvider: app.browser.snapshotProvider
                )
                let tab = BrowserTab(
                    conversationID: UUID(),
                    runtime: rt,
                    owner: .user
                )
                workSurface.additionalBrowsers[key] = tab
                workSurface.open(kind: .browser, contentID: key, title: "Browser")
            }
        } else {
            openFilesTree()
        }
    }

    /// Shows a Files tab with nothing previewed: one already open, else the navigator, else a new one.
    private func openFilesTree() {
        if let tab = workSurface.tabs.first(where: { $0.kind == .files && filesStore(for: $0)?.previewSource == nil }) {
            filesStore(for: tab)?.clearSelection()
            workSurface.focus(id: tab.id)
        } else if !workSurface.tabs.contains(where: { $0.matches(kind: .files, contentID: WorkSurfaceStore.filesNavigatorID) }) {
            workSurface.openFiles()
        } else {
            let key = UUID().uuidString
            workSurface.filePreviews[key] = FilesSurfaceStore(rootURL: files.rootURL)
            workSurface.open(kind: .files, contentID: key)
        }
    }

    // MARK: - File previews
    //
    // A Files tab shows the workspace tree and, once a file is chosen, that file's preview beside
    // it. A tab showing only the tree opens the first file chosen in place; from a tab that
    // already shows a file, the next one gets its own tab, so several files stay open at once.
    // The navigator is the Files tab backed by `files`; every other Files tab has its own store.
    // Opening a file a tab already shows focuses that tab.

    /// Previews a workspace file in its own tab.
    func previewWorkspaceFile(_ url: URL) {
        openPreviewTab { $0.selectFile(url: url) }
    }

    /// Previews a chat attachment in its own tab.
    func previewAttachment(_ attachment: ChatAttachment) {
        guard let app else { return }
        openPreviewTab { $0.selectAttachment(attachment: attachment, attachmentStore: app.attachments) }
    }

    /// Previews a conversation's artifact in its own tab.
    func previewArtifact(id: UUID, conversationID: UUID) {
        guard let artifacts = app?.artifacts else { return }
        if let source = workspaceSource(ofArtifact: id, conversationID: conversationID) {
            previewWorkspaceFile(source)
            return
        }
        openPreviewTab { $0.selectArtifact(id: id, conversationID: conversationID, artifactStore: artifacts) }
    }

    /// The workspace file an artifact was registered from, while it is still there. Such an
    /// artifact opens as that file, as a file link does in Codex: one tab with the tree's,
    /// showing the current content. The stored copy stands in once the file is gone.
    func workspaceSource(ofArtifact id: UUID, conversationID: UUID) -> URL? {
        guard let descriptor = try? app?.artifacts?.resolveDescriptor(artifactID: id, conversationID: conversationID),
              descriptor.producerProvenance == .workspaceRegistration,
              let source = descriptor.workspaceProvenance,
              let root = files.rootURL,
              FileManager.default.fileExists(atPath: source.path),
              WorkspacePathResolver.isInsideWorkspace(source.standardizedFileURL.resolvingSymlinksInPath(), workspaceURL: root)
        else { return nil }
        return source
    }

    /// Closes a Work Surface tab. A Files tab forgets the file it showed, the navigator too,
    /// so Files opens on the tree next time.
    func closeWorkSurfaceTab(id: UUID) {
        if let tab = workSurface.tabs.first(where: { $0.id == id }) {
            filesStore(for: tab)?.clearSelection()
        }
        workSurface.close(id: id)
    }

    /// Opens `url`, chosen in the tree of the tab backed by `store`, the way every file click
    /// opens (`FileOpening`). A preview goes in that tab when it shows only the tree, otherwise
    /// in a tab of its own.
    func openTreeFile(_ url: URL, in store: FilesSurfaceStore) {
        FileOpening.open(url) {
            let source = FilePreviewSource.workspace(url.standardizedFileURL.resolvingSymlinksInPath())
            if let tab = filesTab(showing: source) {
                workSurface.focus(id: tab.id)
            } else if store.previewSource == nil {
                store.selectFile(url: url)
            } else {
                previewWorkspaceFile(url)
            }
        }
    }

    /// The store behind a Files tab.
    func filesStore(for tab: WorkSurfaceTab) -> FilesSurfaceStore? {
        guard tab.kind == .files else { return nil }
        return tab.contentID == WorkSurfaceStore.filesNavigatorID ? files : workSurface.filePreviews[tab.contentID]
    }

    /// A Files tab is named by the file it shows; a browser tab the user opened, by its page,
    /// as in a browser. The agent's own browser tab stays "Browser".
    func workSurfaceTitle(for tab: WorkSurfaceTab) -> String {
        switch tab.kind {
        case .files:
            return filesStore(for: tab)?.previewSource?.displayName ?? tab.kind.defaultTitle
        case .browser:
            let pageTitle = workSurface.additionalBrowsers[tab.contentID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return pageTitle.isEmpty ? tab.title : pageTitle
        }
    }

    func workSurfaceSystemImage(for tab: WorkSurfaceTab) -> String {
        guard tab.kind == .files, filesStore(for: tab)?.previewSource != nil else { return tab.systemImage }
        return "doc.text"
    }

    /// Lets `select` validate and load a file into a new store, then focuses a tab already
    /// showing that file or opens a tab for it. A file that fails validation opens nothing.
    private func openPreviewTab(_ select: (FilesSurfaceStore) -> Void) {
        let preview = FilesSurfaceStore(rootURL: files.rootURL)
        select(preview)
        guard let source = preview.previewSource else {
            app?.logs.info("Files", "Nothing to preview: \(preview.previewState)")
            return
        }
        if let tab = filesTab(showing: source) {
            preview.clearSelection()
            workSurface.focus(id: tab.id)
            return
        }
        let key = UUID().uuidString
        workSurface.filePreviews[key] = preview
        workSurface.open(kind: .files, contentID: key, title: source.displayName)
    }

    private func filesTab(showing source: FilePreviewSource) -> WorkSurfaceTab? {
        workSurface.tabs.first { filesStore(for: $0)?.previewSource?.identity == source.identity }
    }
}
