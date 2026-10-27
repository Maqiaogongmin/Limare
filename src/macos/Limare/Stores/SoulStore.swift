import Foundation
import Observation
import AppKit

struct SoulMetadata: Equatable, Sendable {
    var name: String
    var avatar: String
    var style: String
    var lang: String
    var emoji: String
    var icon: String

    var hasCustomAvatar: Bool {
        !avatar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayIcon: String {
        if !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return icon.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    init(
        name: String = "Limare",
        avatar: String = "",
        style: String = "",
        lang: String = "auto",
        emoji: String = "",
        icon: String = ""
    ) {
        self.name = name
        self.avatar = avatar
        self.style = style
        self.lang = lang
        self.emoji = emoji
        self.icon = icon
    }

    init(
        name: String,
        emoji: String,
        style: String,
        lang: String,
        icon: String
    ) {
        self.name = name
        self.avatar = ""
        self.style = style
        self.lang = lang
        self.emoji = emoji
        self.icon = icon
    }

    static let `default` = SoulMetadata(
        name: "Limare",
        avatar: "",
        style: "",
        lang: "auto",
        emoji: "",
        icon: ""
    )
}

struct SoulFile: Equatable, Sendable {
    var metadata: SoulMetadata
    var body: String
}

enum SoulMDParser {
    static func parse(_ source: String) -> SoulFile {
        let trimmedLeading = source.drop(while: { $0 == "\n" || $0 == "\r" })
        guard trimmedLeading.hasPrefix("---") else {
            return SoulFile(metadata: .default, body: source)
        }
        let lines = String(trimmedLeading).components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closeIdx = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            return SoulFile(metadata: .default, body: source)
        }
        let frontmatterLines = Array(lines[1..<closeIdx])
        let bodyLines = Array(lines[(closeIdx + 1)...])
        var body = String(bodyLines.joined(separator: "\n").drop(while: { $0 == "\n" || $0 == "\r" }))
        while body.hasSuffix("\n") || body.hasSuffix("\r") {
            body.removeLast()
        }
        var meta = SoulMetadata.default
        for raw in frontmatterLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                             .replacingOccurrences(of: "\\\\", with: "\\")
            }
            switch key {
            case "name": if !value.isEmpty { meta.name = value }
            case "avatar": meta.avatar = value
            case "emoji":
                meta.emoji = value
                if meta.icon.isEmpty { meta.icon = value }
            case "icon":
                meta.icon = value
            case "style": meta.style = value
            case "lang": if !value.isEmpty { meta.lang = value }
            default: break
            }
        }
        if meta.icon.isEmpty && !meta.emoji.isEmpty {
            meta.icon = meta.emoji
        }
        return SoulFile(metadata: meta, body: String(body))
    }

    static func serialize(_ file: SoulFile) -> String {
        var out = "---\n"
        out += "name: \"\(escape(file.metadata.name))\"\n"
        let cleanAvatar = file.metadata.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanAvatar.isEmpty {
            out += "avatar: \"\(escape(cleanAvatar))\"\n"
        }
        out += "style: \"\(escape(file.metadata.style))\"\n"
        out += "lang: \"\(escape(file.metadata.lang))\"\n"
        out += "---\n\n"
        out += file.body
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum SoulAvatarResolver {
    static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    static func isSafeFilename(_ filename: String) -> Bool {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("..") else { return false }
        guard !trimmed.hasPrefix("/") && !trimmed.hasPrefix("~") else { return false }
        guard !trimmed.contains(":") && !trimmed.contains("\\") else { return false }
        guard (trimmed as NSString).pathComponents.count == 1 else { return false }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return false }
        return true
    }

    static func resolveFileURL(filename: String, avatarsDirectoryURL: URL) -> URL? {
        guard isSafeFilename(filename) else { return nil }
        let candidate = avatarsDirectoryURL.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        let dirPath = avatarsDirectoryURL.standardizedFileURL.path
        guard candidate.path.hasPrefix(dirPath) else { return nil }
        return candidate
    }

    static func loadImage(filename: String, avatarsDirectoryURL: URL) -> NSImage? {
        guard let url = resolveFileURL(filename: filename, avatarsDirectoryURL: avatarsDirectoryURL) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

enum SoulBodyLimitCheck: Equatable, Sendable {
    case ok
    case overLimit(count: Int, cap: Int)

    var isOverLimit: Bool {
        if case .ok = self { return false }
        return true
    }
}

@MainActor
@Observable
final class SoulStore: @unchecked Sendable {
    static let bodyTokenLimit = 2000

    var name: String = SoulMetadata.default.name
    var avatar: String = SoulMetadata.default.avatar
    var style: String = SoulMetadata.default.style
    var lang: String = SoulMetadata.default.lang
    var icon: String = SoulMetadata.default.icon
    var body: String = ""
    private(set) var lastError: String?
    private(set) var cachedAvatarImage: NSImage?

    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored let fileURL: URL
    @ObservationIgnored let avatarsDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        logs: DebugLogStore
    ) {
        self.fileManager = fileManager
        self.logs = logs
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent("\(LimareStorage.bundleIdentifier)/memory", isDirectory: true)
        self.fileURL = root.appendingPathComponent("SOUL.md", isDirectory: false)
        self.avatarsDirectoryURL = root.appendingPathComponent("avatars", isDirectory: true)
        ensureDirectoryExists()
        reload()
    }

    var effectiveDisplayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Limare" : trimmed
    }

    var isBodyOverLimit: Bool {
        Self.isOverLimit(body).isOverLimit
    }

    var bodyTokenCount: Int {
        Self.tokenCount(body)
    }

    static func tokenCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJKScalar(scalar) || isCJKPunctuationScalar(scalar) {
                if inWord { count += 1; inWord = false }
                count += 1
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if inWord { count += 1; inWord = false }
            } else {
                inWord = true
            }
        }
        if inWord { count += 1 }
        return count
    }

    func tokenCount(_ text: String) -> Int {
        Self.tokenCount(text)
    }

    static func isOverLimit(_ text: String) -> SoulBodyLimitCheck {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ok }
        let count = tokenCount(trimmed)
        return count > bodyTokenLimit
            ? .overLimit(count: count, cap: bodyTokenLimit)
            : .ok
    }

    func isOverLimit(_ text: String) -> SoulBodyLimitCheck {
        Self.isOverLimit(text)
    }

    func loadFile() throws -> SoulFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SoulFile(metadata: .default, body: "")
        }
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return SoulMDParser.parse(content)
    }

    func reload() {
        do {
            let file = try loadFile()
            name = file.metadata.name
            avatar = file.metadata.avatar
            style = file.metadata.style
            lang = file.metadata.lang
            icon = file.metadata.icon
            body = file.body
            updateCachedAvatarImage()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logs.error("Soul", "Failed to load SOUL.md: \(error.localizedDescription)")
        }
    }

    func updateCachedAvatarImage() {
        if !avatar.isEmpty {
            cachedAvatarImage = SoulAvatarResolver.loadImage(filename: avatar, avatarsDirectoryURL: avatarsDirectoryURL)
        } else {
            cachedAvatarImage = nil
        }
    }

    func save() throws {
        let meta = SoulMetadata(name: name, avatar: avatar, style: style, lang: lang, icon: icon)
        let file = SoulFile(metadata: meta, body: body)
        try save(file)
    }

    func save(_ file: SoulFile) throws {
        try saveWithAvatar(
            file: file,
            pendingAvatarSourceURL: nil,
            pendingAvatarData: nil,
            pendingAvatarExtension: nil,
            isAvatarRemoved: file.metadata.avatar.isEmpty && !avatar.isEmpty
        )
    }

    func saveWithAvatar(
        file: SoulFile,
        pendingAvatarSourceURL: URL?,
        pendingAvatarData: Data?,
        pendingAvatarExtension: String?,
        isAvatarRemoved: Bool
    ) throws {
        ensureDirectoryExists()
        var updatedFile = file
        var createdNewFileURL: URL?

        if let sourceURL = pendingAvatarSourceURL {
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            guard SoulAvatarResolver.allowedExtensions.contains(ext) else {
                throw NSError(domain: "SoulStore", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Unsupported image format: .\(ext)")])
            }
            let newFilename = "avatar_\(UUID().uuidString).\(ext)"
            let destURL = avatarsDirectoryURL.appendingPathComponent(newFilename, isDirectory: false)
            try fileManager.copyItem(at: sourceURL, to: destURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path)
            createdNewFileURL = destURL
            updatedFile.metadata.avatar = newFilename
        } else if let data = pendingAvatarData {
            let ext = (pendingAvatarExtension?.isEmpty ?? true) ? "png" : (pendingAvatarExtension!.lowercased())
            guard SoulAvatarResolver.allowedExtensions.contains(ext) else {
                throw NSError(domain: "SoulStore", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Unsupported image format: .\(ext)")])
            }
            let newFilename = "avatar_\(UUID().uuidString).\(ext)"
            let destURL = avatarsDirectoryURL.appendingPathComponent(newFilename, isDirectory: false)
            try data.write(to: destURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path)
            createdNewFileURL = destURL
            updatedFile.metadata.avatar = newFilename
        } else if isAvatarRemoved {
            updatedFile.metadata.avatar = ""
        }

        do {
            let serialized = SoulMDParser.serialize(updatedFile)
            try Data(serialized.utf8).write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            if let created = createdNewFileURL {
                try? fileManager.removeItem(at: created)
            }
            throw error
        }

        cleanObsoleteAvatars(activeAvatarFilename: updatedFile.metadata.avatar)

        name = updatedFile.metadata.name
        avatar = updatedFile.metadata.avatar
        style = updatedFile.metadata.style
        lang = updatedFile.metadata.lang
        icon = updatedFile.metadata.icon
        body = updatedFile.body
        updateCachedAvatarImage()
        lastError = nil
        logs.info("Soul", "Saved SOUL.md with avatar \(updatedFile.metadata.avatar).")
    }

    private func cleanObsoleteAvatars(activeAvatarFilename: String) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: avatarsDirectoryURL.path) else { return }
        for item in items {
            if item != activeAvatarFilename {
                let oldURL = avatarsDirectoryURL.appendingPathComponent(item)
                try? fileManager.removeItem(at: oldURL)
            }
        }
    }

    func restoreDefault() throws {
        let defaultFile = SoulFile(metadata: .default, body: "")
        try saveWithAvatar(
            file: defaultFile,
            pendingAvatarSourceURL: nil,
            pendingAvatarData: nil,
            pendingAvatarExtension: nil,
            isAvatarRemoved: true
        )
    }

    func promptFragment() -> String? {
        let effectiveName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Limare"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = "You are \(effectiveName), a capable AI assistant running on macOS."
        var sections = [identity]

        let trimmedStyle = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStyle.isEmpty {
            sections.append("Response style (from SOUL.md `style` — apply to every reply unless the user explicitly asks otherwise):\n\(trimmedStyle)")
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty, !Self.isOverLimit(trimmedBody).isOverLimit {
            sections.append("Personality (from SOUL.md — your character and voice; defer to the user's latest message when it conflicts with anything here):\n\(trimmedBody)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func ensureDirectoryExists() {
        let dir = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: avatarsDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func isCJKPunctuationScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (0x3000...0x303F).contains(v) { return true }
        if (0xFF00...0xFFEF).contains(v) { return true }
        return false
    }

    private static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (0x4E00...0x9FFF).contains(v) { return true }
        if (0x3400...0x4DBF).contains(v) { return true }
        if (0x20000...0x2A6DF).contains(v) { return true }
        if (0x2A700...0x2EBEF).contains(v) { return true }
        if (0x30000...0x323AF).contains(v) { return true }
        if (0x3040...0x309F).contains(v) { return true }
        if (0x30A0...0x30FF).contains(v) { return true }
        if (0x31F0...0x31FF).contains(v) { return true }
        if (0xAC00...0xD7AF).contains(v) { return true }
        if (0x1100...0x11FF).contains(v) { return true }
        if (0x3130...0x318F).contains(v) { return true }
        return false
    }
}

@MainActor
@Observable
final class SoulEditorState {
    var name: String = SoulMetadata.default.name
    var avatar: String = SoulMetadata.default.avatar
    var style: String = SoulMetadata.default.style
    var lang: String = SoulMetadata.default.lang
    var icon: String = SoulMetadata.default.icon
    var bodyText: String = ""

    var pendingAvatarSourceURL: URL?
    var pendingAvatarData: Data?
    var pendingAvatarExtension: String?
    var isAvatarRemoved: Bool = false
    var draftAvatarImage: NSImage?

    var loadedSnapshot: SoulFile?
    var statusMessage: String?
    var isShowingReloadConfirmation: Bool = false
    var isShowingRestoreConfirmation: Bool = false

    var displayAvatarImage: NSImage? {
        draftAvatarImage
    }

    var displayIcon: String {
        if !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return icon.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    var hasCustomAvatar: Bool {
        draftAvatarImage != nil || pendingAvatarSourceURL != nil || pendingAvatarData != nil || (!avatar.isEmpty && !isAvatarRemoved)
    }

    var isDirty: Bool {
        guard let snapshot = loadedSnapshot else { return false }
        let avatarChanged = pendingAvatarSourceURL != nil
            || pendingAvatarData != nil
            || (isAvatarRemoved && !snapshot.metadata.avatar.isEmpty)
            || (avatar != snapshot.metadata.avatar)
        return name != snapshot.metadata.name
            || style != snapshot.metadata.style
            || lang != snapshot.metadata.lang
            || bodyText != snapshot.body
            || avatarChanged
    }

    var tokenCount: Int {
        SoulStore.tokenCount(bodyText)
    }

    var isOverLimit: Bool {
        SoulStore.isOverLimit(bodyText).isOverLimit
    }

    func selectAvatar(from url: URL) {
        if let image = NSImage(contentsOf: url) {
            draftAvatarImage = image
            pendingAvatarSourceURL = url
            pendingAvatarData = nil
            pendingAvatarExtension = url.pathExtension.lowercased()
            isAvatarRemoved = false
        }
    }

    func selectAvatarData(_ data: Data, fileExtension: String = "png") {
        if let image = NSImage(data: data) {
            draftAvatarImage = image
            pendingAvatarSourceURL = nil
            pendingAvatarData = data
            pendingAvatarExtension = fileExtension.lowercased()
            isAvatarRemoved = false
        }
    }

    func removeAvatar() {
        draftAvatarImage = nil
        pendingAvatarSourceURL = nil
        pendingAvatarData = nil
        pendingAvatarExtension = nil
        isAvatarRemoved = true
    }

    func load(from soulStore: SoulStore) {
        do {
            let file = try soulStore.loadFile()
            soulStore.reload()
            loadedSnapshot = file
            name = file.metadata.name
            avatar = file.metadata.avatar
            style = file.metadata.style
            lang = file.metadata.lang
            icon = file.metadata.icon
            bodyText = file.body
            pendingAvatarSourceURL = nil
            pendingAvatarData = nil
            pendingAvatarExtension = nil
            isAvatarRemoved = false
            draftAvatarImage = soulStore.cachedAvatarImage
            statusMessage = nil
        } catch {
            statusMessage = String(localized: "Reload failed: \(error.localizedDescription)")
        }
    }

    func save(to soulStore: SoulStore) throws {
        guard !isOverLimit else {
            throw NSError(domain: "SoulEditor", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Personality exceeds the 2000 token limit.")])
        }
        let meta = SoulMetadata(name: name, avatar: avatar, style: style, lang: lang, icon: icon)
        let file = SoulFile(metadata: meta, body: bodyText)
        try soulStore.saveWithAvatar(
            file: file,
            pendingAvatarSourceURL: pendingAvatarSourceURL,
            pendingAvatarData: pendingAvatarData,
            pendingAvatarExtension: pendingAvatarExtension,
            isAvatarRemoved: isAvatarRemoved
        )
        let reloadedFile = try soulStore.loadFile()
        loadedSnapshot = reloadedFile
        avatar = reloadedFile.metadata.avatar
        pendingAvatarSourceURL = nil
        pendingAvatarData = nil
        pendingAvatarExtension = nil
        isAvatarRemoved = false
        draftAvatarImage = soulStore.cachedAvatarImage
        statusMessage = String(localized: "Saved to SOUL.md.")
    }

    func requestReload(from soulStore: SoulStore) {
        if isDirty {
            isShowingReloadConfirmation = true
        } else {
            performReload(from: soulStore)
        }
    }

    func confirmReload(from soulStore: SoulStore) {
        performReload(from: soulStore)
        isShowingReloadConfirmation = false
    }

    private func performReload(from soulStore: SoulStore) {
        do {
            let file = try soulStore.loadFile()
            soulStore.reload()
            loadedSnapshot = file
            name = file.metadata.name
            avatar = file.metadata.avatar
            style = file.metadata.style
            lang = file.metadata.lang
            icon = file.metadata.icon
            bodyText = file.body
            pendingAvatarSourceURL = nil
            pendingAvatarData = nil
            pendingAvatarExtension = nil
            isAvatarRemoved = false
            draftAvatarImage = soulStore.cachedAvatarImage
            statusMessage = String(localized: "Reloaded from disk.")
        } catch {
            statusMessage = String(localized: "Reload failed: \(error.localizedDescription)")
        }
    }

    func cancelReload() {
        isShowingReloadConfirmation = false
    }

    func requestRestoreDefault() {
        isShowingRestoreConfirmation = true
    }

    func confirmRestoreDefault(to soulStore: SoulStore) throws {
        do {
            try soulStore.restoreDefault()
            let file = try soulStore.loadFile()
            loadedSnapshot = file
            name = file.metadata.name
            avatar = file.metadata.avatar
            style = file.metadata.style
            lang = file.metadata.lang
            icon = file.metadata.icon
            bodyText = file.body
            pendingAvatarSourceURL = nil
            pendingAvatarData = nil
            pendingAvatarExtension = nil
            isAvatarRemoved = false
            draftAvatarImage = nil
            statusMessage = String(localized: "Restored default personality.")
            isShowingRestoreConfirmation = false
        } catch {
            statusMessage = String(localized: "Restore failed: \(error.localizedDescription)")
            isShowingRestoreConfirmation = false
            throw error
        }
    }

    func cancelRestoreDefault() {
        isShowingRestoreConfirmation = false
    }
}
