import CryptoKit
import Darwin
import Foundation

enum UndoFileSystemError: LocalizedError {
    case backupFailed(String, String)
    case restoreFailed(String, String)
    case missingBlob(String)

    var errorDescription: String? {
        switch self {
        case let .backupFailed(path, reason): String(localized: "Couldn't back up \(path): \(reason)")
        case let .restoreFailed(path, reason): String(localized: "Couldn't restore \(path): \(reason)")
        case let .missingBlob(name): String(localized: "The backup content \(name) no longer exists")
        }
    }
}

/// Content-addressed store of file backups for undo, plus the few filesystem primitives undo
/// needs. Backups are APFS clones where the volume allows, so backing up a large unchanged
/// file costs almost nothing until either copy changes.
final class UndoBlobStore: @unchecked Sendable {
    let directoryURL: URL
    /// Files larger than this are not backed up; their changes cannot be restored.
    let maximumBackupFileBytes: Int64
    private let fileManager = FileManager.default

    init(rootURL: URL, maximumBackupFileBytes: Int64 = 512 * 1024 * 1024) {
        self.directoryURL = rootURL.appendingPathComponent("blobs", isDirectory: true)
        self.maximumBackupFileBytes = maximumBackupFileBytes
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func url(for blob: String) -> URL { directoryURL.appendingPathComponent(blob) }

    func contains(_ blob: String) -> Bool { fileManager.fileExists(atPath: url(for: blob).path) }

    /// The state of `path` right now, for directories Limare owns (snapshots, the blob store).
    /// Project and working-copy paths go through the anchored overload.
    func captureState(of path: String, backup: Bool) throws -> UndoFileState {
        try captureState(at: .atParent(of: path), backup: backup)
    }

    /// The state of `location` right now, read without following any link below its root. With
    /// `backup`, a regular file's content is stored first, so the state can later be restored.
    /// Throws `AnchoredFileError.redirected` when a directory on the way is no longer one.
    func captureState(at location: AnchoredPath, backup: Bool) throws -> UndoFileState {
        guard let info = try AnchoredFileSystem.status(location) else { return .absent }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let mode = UInt16(info.st_mode & 0o7777)
            let size = Int64(info.st_size)
            guard let descriptor = try AnchoredFileSystem.openFile(location) else { return .absent }
            defer { close(descriptor) }
            if backup, size <= maximumBackupFileBytes {
                let (hash, blob) = try store(descriptor: descriptor, path: location.path)
                return .file(sha256: hash, size: size, mode: mode, blob: blob)
            }
            return .file(sha256: try Self.sha256(descriptor: descriptor, path: location.path), size: size, mode: mode, blob: nil)
        case S_IFLNK:
            return .symlink(target: try AnchoredFileSystem.readLink(location) ?? "")
        case S_IFDIR:
            return .other(kind: "directory")
        default:
            return .other(kind: "special")
        }
    }

    /// Clones the file into the store under its SHA-256 and returns (hash, blob name).
    func store(fileAt path: String) throws -> (String, String) {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw UndoFileSystemError.backupFailed(path, String(cString: strerror(errno))) }
        defer { close(descriptor) }
        return try store(descriptor: descriptor, path: path)
    }

    private func store(descriptor: Int32, path: String) throws -> (String, String) {
        let name = ".incoming-\(UUID().uuidString)"
        let temporary = directoryURL.appendingPathComponent(name)
        let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw UndoFileSystemError.backupFailed(path, String(cString: strerror(errno))) }
        defer { close(directory) }
        if fclonefileat(descriptor, directory, name, 0) != 0 {
            let output = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw UndoFileSystemError.backupFailed(path, String(cString: strerror(errno))) }
            let copied = fcopyfile(descriptor, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
            let reason = String(cString: strerror(errno))
            close(output)
            guard copied else {
                unlink(temporary.path)
                throw UndoFileSystemError.backupFailed(path, reason)
            }
        }
        do {
            let hash = try Self.sha256(ofFileAt: temporary.path)
            let final = url(for: hash)
            if fileManager.fileExists(atPath: final.path) {
                try? fileManager.removeItem(at: temporary)
            } else {
                chmod(temporary.path, 0o400)
                // Atomic and idempotent: a concurrent backup of identical content may have
                // landed first; replacing it with the same bytes is harmless.
                guard rename(temporary.path, final.path) == 0 else {
                    let reason = String(cString: strerror(errno))
                    try? fileManager.removeItem(at: temporary)
                    throw UndoFileSystemError.backupFailed(path, reason)
                }
            }
            return (hash, hash)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw UndoFileSystemError.backupFailed(path, error.localizedDescription)
        }
    }

    /// Makes `location` hold `state`, atomically (staged next to it and renamed over it), never
    /// through a link below the location's root. Returns the directories it had to create.
    @discardableResult
    func apply(_ state: UndoFileState, at location: AnchoredPath, replaceNonDirectories: Bool = false) throws -> [String] {
        switch state {
        case .absent:
            try AnchoredFileSystem.remove(location, replaceNonDirectories: replaceNonDirectories)
            return []
        case let .file(_, _, mode, blob):
            guard let blob else { throw UndoFileSystemError.missingBlob(location.path) }
            let source = open(url(for: blob).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw UndoFileSystemError.missingBlob(blob) }
            defer { close(source) }
            return try AnchoredFileSystem.copyFile(from: source, to: location, mode: mode_t(mode), replaceNonDirectories: replaceNonDirectories)
        case let .symlink(destination):
            return try AnchoredFileSystem.makeSymlink(destination, at: location, replaceNonDirectories: replaceNonDirectories)
        case .other(let kind):
            throw UndoFileSystemError.restoreFailed(location.path, String(localized: "Restoring this kind of item isn't supported: \(kind)"))
        }
    }

    /// Removes directories a change created, deepest first, as long as they are empty.
    func removeEmptyDirectories(_ paths: [String], root: String) {
        AnchoredFileSystem.removeEmptyDirectories(paths, root: root)
    }

    func delete(_ blob: String) {
        let blobURL = url(for: blob)
        chmod(blobURL.path, 0o600)
        try? fileManager.removeItem(at: blobURL)
    }

    /// Every stored blob with its allocated size.
    func inventory() -> [String: Int64] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return [:] }
        var result: [String: Int64] = [:]
        for name in names where !name.hasPrefix(".") {
            var info = stat()
            if lstat(url(for: name).path, &info) == 0 { result[name] = Int64(info.st_size) }
        }
        return result
    }

    /// Removes staging files left by a crash.
    func removeIncomingLeftovers() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for name in names where name.hasPrefix(".incoming-") {
            try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }
    }

    static func sha256(ofFileAt path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw UndoFileSystemError.backupFailed(path, String(localized: "It can't be read")) }
        defer { close(descriptor) }
        return try sha256(descriptor: descriptor, path: path)
    }

    static func sha256(descriptor: Int32, path: String) throws -> String {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Ancestors of `path` (below `stop`) that do not exist yet, outermost first.
    static func missingAncestors(of path: String, stoppingAt stop: String?) -> [String] {
        var missing: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty, current != "/", current != stop, !FileManager.default.fileExists(atPath: current) {
            missing.insert(current, at: 0)
            current = (current as NSString).deletingLastPathComponent
        }
        return missing
    }
}
