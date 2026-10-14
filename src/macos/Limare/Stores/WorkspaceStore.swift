import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceStore {
    enum Persistence {
        case durable
        case runScoped
    }

    private(set) var configuration: WorkspaceConfiguration?
    private(set) var errorMessage: String?
    @ObservationIgnored
    var onWorkspaceChange: ((URL?) -> Void)?

    private let fileURL: URL?
    private let picker: any WorkspacePicking
    private let logs: DebugLogStore
    private var isAccessingSecurityScopedResource = false
    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        persistence: Persistence = .durable,
        picker: (any WorkspacePicking)? = nil,
        logs: DebugLogStore
    ) {
        switch persistence {
        case .durable:
            let root = storageRootURL
                ?? LimareStorage.applicationSupport
                    .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
            try? fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            fileURL = root.appendingPathComponent("workspace.json")
        case .runScoped:
            fileURL = nil
        }
        self.picker = picker ?? WorkspacePicker()
        self.logs = logs
        restore()
    }

    isolated deinit {
        if isAccessingSecurityScopedResource, let configuration {
            configuration.url.stopAccessingSecurityScopedResource()
        }
    }

    var url: URL? { configuration?.url }

    func chooseWorkspace() {
        guard let url = picker.chooseWorkspace() else { return }
        do {
            try setWorkspace(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setWorkspace(_ rawURL: URL) throws {
        let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspacePathError.pathNotFound(url.path)
        }

        stopCurrentAccess()
        let bookmark: Data?
        let usesSecurityScope: Bool
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = true
        } catch {
            bookmark = try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = false
        }

        configuration = WorkspaceConfiguration(
            name: url.lastPathComponent,
            path: url.path,
            bookmarkData: bookmark,
            usesSecurityScope: usesSecurityScope
        )
        beginAccessIfNeeded()
        try persist()
        errorMessage = nil
        logs.info("Workspace", "Selected Workspace \(url.path).")
        onWorkspaceChange?(url)
    }

    func clearWorkspace() {
        stopCurrentAccess()
        configuration = nil
        errorMessage = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        logs.info("Workspace", "Cleared the active Workspace selection.")
        onWorkspaceChange?(nil)
    }

    func restoreWorkspaceConfiguration(_ config: WorkspaceConfiguration?) {
        stopCurrentAccess()
        guard var newConfig = config else {
            configuration = nil
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            logs.info("Workspace", "Cleared active Workspace.")
            onWorkspaceChange?(nil)
            return
        }

        if let bookmarkData = newConfig.bookmarkData {
            var stale = false
            let options: URL.BookmarkResolutionOptions = newConfig.usesSecurityScope ? [.withSecurityScope] : []
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                newConfig = WorkspaceConfiguration(
                    name: resolved.lastPathComponent,
                    path: resolved.standardizedFileURL.path,
                    bookmarkData: bookmarkData,
                    usesSecurityScope: newConfig.usesSecurityScope
                )
            }
        }
        configuration = newConfig
        beginAccessIfNeeded()
        try? persist()
        errorMessage = nil
        logs.info("Workspace", "Restored Workspace \(newConfig.path).")
        onWorkspaceChange?(newConfig.url)
    }

    private func restore() {
        guard let fileURL else { return }
        guard let data = try? Data(contentsOf: fileURL),
              var saved = try? JSONDecoder().decode(WorkspaceConfiguration.self, from: data) else {
            return
        }

        if let bookmarkData = saved.bookmarkData {
            var stale = false
            let options: URL.BookmarkResolutionOptions = saved.usesSecurityScope ? [.withSecurityScope] : []
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                saved = WorkspaceConfiguration(
                    name: resolved.lastPathComponent,
                    path: resolved.standardizedFileURL.path,
                    bookmarkData: bookmarkData,
                    usesSecurityScope: saved.usesSecurityScope
                )
            }
        }
        configuration = saved
        beginAccessIfNeeded()
    }

    private func persist() throws {
        guard let fileURL else { return }
        guard let configuration else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func beginAccessIfNeeded() {
        guard let configuration, configuration.usesSecurityScope else { return }
        isAccessingSecurityScopedResource = configuration.url.startAccessingSecurityScopedResource()
    }

    private func stopCurrentAccess() {
        if isAccessingSecurityScopedResource, let configuration {
            configuration.url.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScopedResource = false
    }
}
