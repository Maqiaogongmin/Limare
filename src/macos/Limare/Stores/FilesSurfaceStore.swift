import Foundation
import Observation
import AppKit
import CoreGraphics
import ImageIO

/// Source origin of a previewed file or attachment.
public enum FilePreviewSource: Equatable, Sendable {
    case workspace(URL)
    case attachment(id: UUID, filename: String, url: URL)
    /// A file a tool registered or produced for the conversation (see `ArtifactStore`).
    case artifact(id: UUID, filename: String, url: URL)

    /// What the preview shows, for finding a tab that already shows it.
    var identity: String {
        switch self {
        case .workspace(let url): return url.path
        case .attachment(let id, _, _), .artifact(let id, _, _): return id.uuidString
        }
    }

    /// The name the preview goes by.
    var displayName: String {
        switch self {
        case .workspace(let url): return url.lastPathComponent
        case .attachment(_, let filename, _), .artifact(_, let filename, _): return filename
        }
    }
}

/// Store managing the state, file tree, and read-only preview content of the Files Work Surface.
/// Scoped strictly to the active conversation's effective workspace and safe chat attachments.
@MainActor
@Observable
public final class FilesSurfaceStore {

    /// 2 MiB safety threshold for text/code preview loading.
    public nonisolated static let maximumTextPreviewBytes: Int64 = 2 * 1024 * 1024

    /// 10 MiB safety threshold for image preview loading.
    public nonisolated static let maximumImagePreviewBytes: Int64 = 10 * 1024 * 1024

    /// 50 MiB safety threshold for PDF preview loading.
    public nonisolated static let maximumPDFPreviewBytes: Int64 = 50 * 1024 * 1024

    public private(set) var rootURL: URL? = nil
    public private(set) var selectedFileURL: URL? = nil
    public private(set) var previewSource: FilePreviewSource? = nil
    public private(set) var treeNodes: [FileTreeNode] = []
    public private(set) var expandedPaths: Set<String> = []
    public private(set) var previewState: FilePreviewState = .idle
    public private(set) var isLoadingTree: Bool = false
    public private(set) var treeErrorMessage: String? = nil

    /// Whether there is currently an active preview (workspace file or chat attachment).
    public var hasActivePreview: Bool {
        previewSource != nil || previewState != .idle
    }

    /// Test hook to deterministically pause background preview loading.
    public var previewLoadBarrier: ((URL) async -> Void)? = nil

    private var activeLoadTask: Task<Void, Never>? = nil
    private var currentLoadID: UUID = UUID()

    private static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "DerivedData", ".build", ".svn", ".hg", "Pods"
    ]

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
        if let rootURL {
            reloadTree(for: rootURL)
        }
    }

    // MARK: - Root Workspace Scope

    /// Sets the effective workspace root URL. If the root changes, invalidates selections outside the new root.
    public func setRootURL(_ url: URL?) {
        guard rootURL != url else { return }
        rootURL = url

        activeLoadTask?.cancel()
        currentLoadID = UUID()

        if let selected = selectedFileURL, let url {
            if !WorkspacePathResolver.isInsideWorkspace(selected, workspaceURL: url) {
                selectedFileURL = nil
                previewSource = nil
                previewState = .idle
            }
        } else if case .workspace = previewSource {
            selectedFileURL = nil
            previewSource = nil
            previewState = .idle
        }

        if let url {
            reloadTree(for: url)
        } else {
            treeNodes = []
            treeErrorMessage = nil
        }
    }

    // MARK: - File Selection & Preview Loading

    /// Selects a file within the workspace, validates containment, and starts asynchronous preview loading.
    public func selectFile(url: URL) {
        guard let root = rootURL else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            selectedFileURL = nil
            previewSource = nil
            previewState = .error("No active workspace.")
            return
        }

        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard WorkspacePathResolver.isInsideWorkspace(standardized, workspaceURL: root) else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            selectedFileURL = nil
            previewSource = nil
            previewState = .error("File is outside the active workspace.")
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            selectedFileURL = nil
            previewSource = nil
            previewState = .error("File not found: \(standardized.lastPathComponent)")
            return
        }

        if isDir.boolValue {
            toggleDirectory(url: standardized)
            return
        }

        selectedFileURL = standardized
        previewSource = .workspace(standardized)
        reloadTree(for: root)
        loadPreview(for: standardized, displayName: standardized.lastPathComponent)
    }

    /// Convenience async selection helper for tests and programmatic callers wanting to await preview completion.
    public func selectFileAsync(url: URL) async {
        selectFile(url: url)
        if let task = activeLoadTask {
            _ = await task.value
        }
    }

    /// Selects and previews a chat attachment, validating that it resides inside the AttachmentStore storage boundary.
    public func selectAttachment(attachment: ChatAttachment, attachmentStore: AttachmentStore) {
        guard let url = try? attachmentStore.fileURL(for: attachment) else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            previewState = .error("Attachment could not be resolved.")
            return
        }

        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let storageRoot = attachmentStore.storageRootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard standardized.path.hasPrefix(storageRoot.path) else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            previewState = .error("Attachment path outside storage boundary.")
            return
        }

        guard FileManager.default.fileExists(atPath: standardized.path) else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            previewState = .error("Attachment file not found on disk.")
            return
        }

        selectedFileURL = nil
        previewSource = .attachment(id: attachment.id, filename: attachment.filename, url: standardized)
        loadPreview(for: standardized, displayName: attachment.filename)
    }

    /// Selects and previews a conversation's artifact, validating that it resides inside the
    /// ArtifactStore's storage.
    public func selectArtifact(id: UUID, conversationID: UUID, artifactStore: ArtifactStore) {
        guard let descriptor = try? artifactStore.resolveDescriptor(artifactID: id, conversationID: conversationID),
              let url = try? artifactStore.resolveFileURL(artifactID: id, conversationID: conversationID)
        else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            previewState = .error("File could not be found.")
            return
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        let storageRoot = artifactStore.artifactsDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard standardized.path.hasPrefix(storageRoot.path + "/") else {
            activeLoadTask?.cancel()
            currentLoadID = UUID()
            previewState = .error("File path outside storage boundary.")
            return
        }

        selectedFileURL = nil
        let source = FilePreviewSource.artifact(id: id, filename: descriptor.filename, url: standardized)
        previewSource = source
        loadPreview(for: standardized, displayName: descriptor.filename)
    }

    public func selectAttachmentAsync(attachment: ChatAttachment, attachmentStore: AttachmentStore) async {
        selectAttachment(attachment: attachment, attachmentStore: attachmentStore)
        if let task = activeLoadTask {
            _ = await task.value
        }
    }

    public func loadPreview(for url: URL, displayName: String? = nil) {
        activeLoadTask?.cancel()
        let loadID = UUID()
        currentLoadID = loadID

        previewState = .loading(url)
        let barrier = previewLoadBarrier
        let display = displayName ?? url.lastPathComponent

        activeLoadTask = Task { [weak self] in
            if let barrier {
                await barrier(url)
            }

            let result = await Task.detached(priority: .userInitiated) { () -> FilePreviewState in
                return Self.loadFilePreviewInBackground(url: url, displayName: display)
            }.value

            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.currentLoadID == loadID else { return }

            self.previewState = result
        }
    }

    private nonisolated static func loadFilePreviewInBackground(url: URL, displayName: String) -> FilePreviewState {
        let filename = displayName
        let ext = (displayName as NSString).pathExtension.lowercased()

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let sizeBytes = (attrs[.size] as? Int64) ?? (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let modifiedDate = attrs[.modificationDate] as? Date

        let kind = FilePreviewClassifier.classify(url: URL(fileURLWithPath: displayName))

        switch kind {
        case .unsupported:
            let metadata = FileMetadata(
                url: url,
                filename: filename,
                fileExtension: ext,
                sizeBytes: sizeBytes,
                modifiedDate: modifiedDate
            )
            return .unsupported(metadata)

        case .pdf:
            let metadata = FileMetadata(
                url: url,
                filename: filename,
                fileExtension: ext,
                sizeBytes: sizeBytes,
                modifiedDate: modifiedDate
            )
            if sizeBytes == 0 {
                return .emptyFile(metadata)
            }
            if sizeBytes > maximumPDFPreviewBytes {
                return .tooLarge(metadata)
            }
            return .loaded(FilePreviewData(kind: .pdf, metadata: metadata, content: .pdf(url)))

        case .image:
            var dimensions: CGSize? = nil
            if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
                let width = (properties[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
                let height = (properties[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
                if width > 0 && height > 0 {
                    dimensions = CGSize(width: width, height: height)
                }
            }

            let metadata = FileMetadata(
                url: url,
                filename: filename,
                fileExtension: ext,
                sizeBytes: sizeBytes,
                modifiedDate: modifiedDate,
                dimensions: dimensions
            )

            if sizeBytes == 0 {
                return .emptyFile(metadata)
            }
            if sizeBytes > maximumImagePreviewBytes {
                return .tooLarge(metadata)
            }
            guard let data = try? Data(contentsOf: url) else {
                return .error("Could not read image file.")
            }
            let isSVG = (ext == "svg")
            return .loaded(FilePreviewData(kind: .image, metadata: metadata, content: .image(data: data, isSVG: isSVG)))

        case .markdown, .text, .code, .html:
            if sizeBytes == 0 {
                let metadata = FileMetadata(
                    url: url,
                    filename: filename,
                    fileExtension: ext,
                    sizeBytes: sizeBytes,
                    modifiedDate: modifiedDate
                )
                return .emptyFile(metadata)
            }
            if sizeBytes > maximumTextPreviewBytes {
                let metadata = FileMetadata(
                    url: url,
                    filename: filename,
                    fileExtension: ext,
                    sizeBytes: sizeBytes,
                    modifiedDate: modifiedDate
                )
                return .tooLarge(metadata)
            }

            guard let data = try? Data(contentsOf: url) else {
                return .error("Could not read file contents.")
            }

            guard let string = String(data: data, encoding: .utf8) else {
                return .error("Unable to decode file as UTF-8 text.")
            }

            let lineCount = string.split(separator: "\n", omittingEmptySubsequences: false).count
            let metadata = FileMetadata(
                url: url,
                filename: filename,
                fileExtension: ext,
                sizeBytes: sizeBytes,
                modifiedDate: modifiedDate,
                lineCount: lineCount
            )

            let content: FilePreviewContent
            switch kind {
            case .markdown:
                content = .markdown(string)
            case .text:
                content = .text(string)
            case .code(let lang):
                content = .code(code: string, language: lang)
            case .html:
                content = .html(source: string, fileURL: url)
            default:
                content = .text(string)
            }

            return .loaded(FilePreviewData(kind: kind, metadata: metadata, content: content))
        }
    }

    // MARK: - File Tree Directory Operations

    /// Toggles expansion of a directory node.
    public func toggleDirectory(url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
        if let root = rootURL {
            reloadTree(for: root)
        }
    }

    /// Explicitly expands a directory path.
    public func expandDirectory(url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        expandedPaths.insert(path)
        if let root = rootURL {
            reloadTree(for: root)
        }
    }

    /// Refreshes the workspace file tree and reloads the currently selected file.
    public func refresh() {
        if let root = rootURL {
            reloadTree(for: root)
        }
        if let selected = selectedFileURL {
            loadPreview(for: selected)
        } else if case .attachment(_, let filename, let url) = previewSource {
            loadPreview(for: url, displayName: filename)
        } else if case .artifact(_, let filename, let url) = previewSource {
            loadPreview(for: url, displayName: filename)
        }
    }

    /// Clears the active file selection.
    public func clearSelection() {
        activeLoadTask?.cancel()
        currentLoadID = UUID()
        selectedFileURL = nil
        previewSource = nil
        previewState = .idle
    }

    // MARK: - Tree Construction

    private func reloadTree(for root: URL) {
        isLoadingTree = true
        treeErrorMessage = nil

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            treeNodes = []
            isLoadingTree = false
            treeErrorMessage = String(localized: "Workspace is unavailable.")
            return
        }

        treeNodes = loadDirectory(at: root)
        isLoadingTree = false
    }

    private func loadDirectory(at dirURL: URL) -> [FileTreeNode] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var directories: [FileTreeNode] = []
        var files: [FileTreeNode] = []

        for entry in entries {
            let name = entry.lastPathComponent
            if Self.ignoredDirectoryNames.contains(name) {
                continue
            }

            let resourceValues = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false

            if isDirectory {
                let path = entry.standardizedFileURL.resolvingSymlinksInPath().path
                let isExpanded = expandedPaths.contains(path)
                let children = isExpanded ? loadDirectory(at: entry) : nil

                directories.append(
                    FileTreeNode(
                        url: entry,
                        name: name,
                        isDirectory: true,
                        children: children
                    )
                )
            } else {
                files.append(
                    FileTreeNode(
                        url: entry,
                        name: name,
                        isDirectory: false
                    )
                )
            }
        }

        directories.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return directories + files
    }

    // MARK: - System App Affordances

    public func openInDefaultApp(url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
