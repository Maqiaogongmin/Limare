import Darwin
import Foundation

/// A location below an allowed root (the project, a working copy, the directory an external
/// write was approved in). Every operation opens the root, checks it is still the directory it
/// was, and walks down component by component without following symbolic links, so a parent
/// directory that was swapped for a link (or a file) is reported instead of written through.
struct AnchoredPath: Codable, Equatable, Hashable, Sendable {
    /// The root's kernel path (`realpath`), fixed when the location was recorded.
    let root: String
    /// Path below the root, `/`-separated, without `.` or `..` components; never empty.
    let relative: String

    struct DirectoryIdentity: Codable, Equatable, Hashable, Sendable {
        let device: Int32
        let inode: UInt64
        init(_ info: stat) { device = info.st_dev; inode = UInt64(info.st_ino) }
    }

    /// Persisted identities, not merely names. Optional for older v1 records which did not
    /// record this evidence; loading them must not fabricate historical identities.
    let rootIdentity: DirectoryIdentity?
    let parentIdentities: [String: DirectoryIdentity]?

    init(root: String, relative: String) {
        self.root = root
        self.relative = relative
        let identities = Self.captureDirectories(root: root, relative: relative)
        rootIdentity = identities[""]
        parentIdentities = identities.filter { !$0.key.isEmpty }
    }

    /// Identities observed on the opened directory descriptors, including newly created
    /// parents. Never reacquire a missing parent's identity by resolving its path later.
    init(root: String, relative: String, rootIdentity: DirectoryIdentity, parentIdentities: [String: DirectoryIdentity]) {
        self.root = root
        self.relative = relative
        self.rootIdentity = rootIdentity
        self.parentIdentities = parentIdentities
    }

    /// Parents removed by the recorded turn may legitimately be recreated by undo. Preserve
    /// identities of parents still present, while requiring any existing parent to remain the
    /// original one. Missing parents carry no stale inode into the new restore plan.
    func allowingRecreationOfMissingParents() throws -> AnchoredPath {
        let current = AnchoredPath(root: root, relative: relative)
        guard let currentRoot = current.rootIdentity, rootIdentity == nil || rootIdentity == currentRoot else {
            throw AnchoredFileError.rootMoved(root)
        }
        for (path, expected) in parentIdentities ?? [:] {
            if let actual = current.parentIdentities?[path], actual != expected {
                throw AnchoredFileError.redirected(self.path)
            }
        }
        // The caller has already read through the original anchor without following links.
        // Capture only what exists now; the original identity is never replaced by a new one.
        return current
    }

    private static func captureDirectories(root: String, relative: String) -> [String: DirectoryIdentity] {
        var descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return [:] }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return [:] }
        var result = ["": DirectoryIdentity(info)]
        var walked = ""
        for component in relative.split(separator: "/").dropLast() {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { break }
            Darwin.close(descriptor)
            descriptor = next
            guard fstat(descriptor, &info) == 0 else { break }
            walked += (walked.isEmpty ? "" : "/") + component
            result[walked] = DirectoryIdentity(info)
        }
        return result
    }

    /// `path` relative to `root` (either may use any spelling that resolves to the same
    /// directory); nil when `path` is not strictly below `root`.
    init?(path: String, under root: String) {
        let real = FileSystemPaths.realPath(root)
        var candidates = [root, real]
        let foundation = FileSystemPaths.canonical(root)
        if !candidates.contains(foundation) { candidates.append(foundation) }
        let standardized = (path as NSString).standardizingPath
        guard let prefix = candidates.first(where: { standardized.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return nil }
        let relative = String(standardized.dropFirst(prefix.hasSuffix("/") ? prefix.count : prefix.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        self.init(root: real, relative: components.joined(separator: "/"))
    }

    /// For a path with no recorded root: anchored at the real path of its nearest existing
    /// directory as it is now, so missing parents are created by the anchored walk instead of
    /// the absent root being reported as moved.
    static func atParent(of path: String) -> AnchoredPath {
        let standardized = (path as NSString).standardizingPath
        var root = (standardized as NSString).deletingLastPathComponent
        var relative = [(standardized as NSString).lastPathComponent]
        var isDirectory: ObjCBool = false
        while root != "/", !(FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue) {
            relative.insert((root as NSString).lastPathComponent, at: 0)
            root = (root as NSString).deletingLastPathComponent
        }
        return AnchoredPath(root: FileSystemPaths.realPath(root), relative: relative.joined(separator: "/"))
    }

    var path: String { root + "/" + relative }
    var components: [String] { relative.split(separator: "/").map(String.init) }
}

enum AnchoredFileError: LocalizedError, Equatable {
    /// A directory on the way to the path is no longer a plain directory (a symbolic link, a
    /// file), so the path would now lead somewhere else.
    case redirected(String)
    /// The root itself moved or was replaced.
    case rootMoved(String)
    case failed(String, String)

    var errorDescription: String? {
        switch self {
        case .redirected(let path): "路径 \(path) 已被重定向：它的上级目录被替换成了符号链接或文件"
        case .rootMoved(let root): "目录 \(root) 已被移动或替换"
        case let .failed(path, reason): "\(path)：\(reason)"
        }
    }
}

/// Filesystem primitives on `AnchoredPath`s. Directory descriptors are opened with
/// `O_NOFOLLOW | O_DIRECTORY`, and every entry is created, replaced or removed with the `*at`
/// calls relative to its parent's descriptor, so no step resolves a path string again.
enum AnchoredFileSystem {
    /// The opened parent of a location. Close with `close()`.
    struct Parent {
        let descriptor: Int32
        let name: String
        /// Directories this open created, outermost first (absolute paths).
        let created: [String]
        let location: AnchoredPath
        func close() { Darwin.close(descriptor) }
    }

    /// Opens the root and verifies it is still at its recorded real path.
    static func openRoot(_ root: String, identity: AnchoredPath.DirectoryIdentity? = nil) throws -> Int32 {
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { throw AnchoredFileError.rootMoved(root) }
            throw AnchoredFileError.failed(root, String(cString: strerror(errno)))
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0, String(cString: buffer) == root else {
            Darwin.close(descriptor)
            throw AnchoredFileError.rootMoved(root)
        }
        if let identity {
            var info = stat()
            guard fstat(descriptor, &info) == 0, AnchoredPath.DirectoryIdentity(info) == identity else {
                Darwin.close(descriptor)
                throw AnchoredFileError.rootMoved(root)
            }
        }
        return descriptor
    }

    /// Walks to the parent directory of `location`. Returns nil when a directory on the way is
    /// missing and `create` is false (the path is absent). Throws `redirected` when a component
    /// exists but is not a plain directory — unless `replaceNonDirectories` (used only inside a
    /// working copy, which mirrors the project), which replaces it with a directory.
    static func openParent(_ location: AnchoredPath, create: Bool, replaceNonDirectories: Bool = false) throws -> Parent? {
        var current = try openRoot(location.root, identity: location.rootIdentity)
        var rootInfo = stat()
        guard fstat(current, &rootInfo) == 0 else {
            Darwin.close(current)
            throw AnchoredFileError.failed(location.path, "无法读取根目录身份")
        }
        let rootIdentity = AnchoredPath.DirectoryIdentity(rootInfo)
        var parentIdentities: [String: AnchoredPath.DirectoryIdentity] = [:]
        var components = location.components
        let name = components.removeLast()
        var created: [String] = []
        var walked = location.root
        var relativeParent = ""
        for component in components {
            walked += "/" + component
            relativeParent += (relativeParent.isEmpty ? "" : "/") + component
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = errno
                var info = stat()
                let exists = fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0
                if !exists && error == ENOENT {
                    guard create else { Darwin.close(current); return nil }
                } else if exists && (info.st_mode & S_IFMT) != S_IFDIR {
                    guard replaceNonDirectories, unlinkat(current, component, 0) == 0 else {
                        Darwin.close(current)
                        throw AnchoredFileError.redirected(location.path)
                    }
                } else {
                    Darwin.close(current)
                    throw AnchoredFileError.failed(walked, String(cString: strerror(error)))
                }
                guard mkdirat(current, component, 0o755) == 0 || errno == EEXIST else {
                    let reason = String(cString: strerror(errno))
                    Darwin.close(current)
                    throw AnchoredFileError.failed(walked, reason)
                }
                created.append(walked)
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else {
                    Darwin.close(current)
                    throw AnchoredFileError.redirected(location.path)
                }
            }
            var info = stat()
            guard fstat(next, &info) == 0 else {
                Darwin.close(next); Darwin.close(current)
                throw AnchoredFileError.failed(location.path, "无法读取父目录身份")
            }
            let observed = AnchoredPath.DirectoryIdentity(info)
            if let expected = location.parentIdentities?[relativeParent], observed != expected {
                Darwin.close(next); Darwin.close(current)
                throw AnchoredFileError.redirected(location.path)
            }
            parentIdentities[relativeParent] = observed
            Darwin.close(current)
            current = next
        }
        return Parent(descriptor: current, name: name, created: created,
                      location: AnchoredPath(root: location.root, relative: location.relative,
                                             rootIdentity: rootIdentity, parentIdentities: parentIdentities))
    }

    /// Create missing parents, verify all historical identities, then capture the new ones.
    /// Callers persist the returned anchor before modifying the file, including crash recovery.
    static func prepareParents(_ location: AnchoredPath) throws -> AnchoredPath {
        guard let parent = try openParent(location, create: true) else {
            throw AnchoredFileError.failed(location.path, "无法准备父目录")
        }
        defer { parent.close() }
        return parent.location
    }

    /// `lstat` of the location itself; nil when it is absent (including a missing parent).
    static func status(_ location: AnchoredPath) throws -> stat? {
        guard let parent = try openParent(location, create: false) else { return nil }
        defer { parent.close() }
        var info = stat()
        guard fstatat(parent.descriptor, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw AnchoredFileError.failed(location.path, String(cString: strerror(errno)))
        }
        return info
    }

    /// Opens the regular file at `location` for reading (never through a link).
    static func openFile(_ location: AnchoredPath) throws -> Int32? {
        guard let parent = try openParent(location, create: false) else { return nil }
        defer { parent.close() }
        let descriptor = openat(parent.descriptor, parent.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AnchoredFileError.failed(location.path, String(cString: strerror(errno)))
        }
        return descriptor
    }

    static func readLink(_ location: AnchoredPath) throws -> String? {
        guard let parent = try openParent(location, create: false) else { return nil }
        defer { parent.close() }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        let count = readlinkat(parent.descriptor, parent.name, &buffer, Int(MAXPATHLEN))
        guard count >= 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Writes `data` to `location` atomically (staged next to it, renamed over it). The mode is
    /// `mode`, else the replaced file's, else 0644. Returns the directories it created.
    @discardableResult
    static func write(_ data: Data, to location: AnchoredPath, mode: mode_t? = nil, replaceNonDirectories: Bool = false) throws -> [String] {
        try replace(location, replaceNonDirectories: replaceNonDirectories, defaultMode: mode) { directory, staged in
            let descriptor = openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return errno }
            defer { Darwin.close(descriptor) }
            let failed = data.withUnsafeBytes { raw -> Int32? in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 { return errno }
                    offset += written
                }
                return nil
            }
            return failed ?? 0
        }
    }

    /// Puts a copy of the regular file open at `source` at `location` (a clone where the
    /// volume allows), atomically.
    @discardableResult
    static func copyFile(from source: Int32, to location: AnchoredPath, mode: mode_t?, replaceNonDirectories: Bool = false) throws -> [String] {
        try replace(location, replaceNonDirectories: replaceNonDirectories, defaultMode: mode) { directory, staged in
            if fclonefileat(source, directory, staged, 0) == 0 { return 0 }
            let descriptor = openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return errno }
            defer { Darwin.close(descriptor) }
            return fcopyfile(source, descriptor, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 ? 0 : errno
        }
    }

    /// Makes `location` a symbolic link to `destination`, atomically.
    @discardableResult
    static func makeSymlink(_ destination: String, at location: AnchoredPath, replaceNonDirectories: Bool = false) throws -> [String] {
        try replace(location, replaceNonDirectories: replaceNonDirectories, defaultMode: nil, isLink: true) { directory, staged in
            symlinkat(destination, directory, staged) == 0 ? 0 : errno
        }
    }

    /// Removes the file or link at `location`; a directory there is refused. Absent is fine.
    static func remove(_ location: AnchoredPath, replaceNonDirectories: Bool = false) throws {
        guard let parent = try openParent(location, create: false, replaceNonDirectories: replaceNonDirectories) else { return }
        defer { parent.close() }
        var info = stat()
        guard fstatat(parent.descriptor, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR { throw AnchoredFileError.failed(location.path, "目标是一个目录") }
        guard unlinkat(parent.descriptor, parent.name, 0) == 0 || errno == ENOENT else {
            throw AnchoredFileError.failed(location.path, String(cString: strerror(errno)))
        }
    }

    /// Removes the given directories (absolute, below `root`) deepest first, if empty.
    static func removeEmptyDirectories(_ paths: [String], root: String) {
        for path in paths.sorted(by: { $0.count > $1.count }) {
            guard let location = AnchoredPath(path: path, under: root),
                  let parent = try? openParent(location, create: false) else { continue }
            unlinkat(parent.descriptor, parent.name, AT_REMOVEDIR)  // fails harmlessly when not empty
            parent.close()
        }
    }

    private static func replace(_ location: AnchoredPath, replaceNonDirectories: Bool, defaultMode: mode_t?, isLink: Bool = false,
                                stage: (Int32, String) -> Int32) throws -> [String] {
        guard let parent = try openParent(location, create: true, replaceNonDirectories: replaceNonDirectories) else {
            throw AnchoredFileError.failed(location.path, "无法打开上级目录")
        }
        defer { parent.close() }
        var existing = stat()
        let exists = fstatat(parent.descriptor, parent.name, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if exists && (existing.st_mode & S_IFMT) == S_IFDIR {
            throw AnchoredFileError.failed(location.path, "目标是一个目录")
        }
        let staged = ".limare-stage-\(UUID().uuidString)"
        let result = stage(parent.descriptor, staged)
        guard result == 0 else {
            unlinkat(parent.descriptor, staged, 0)
            throw AnchoredFileError.failed(location.path, String(cString: strerror(result)))
        }
        if !isLink {
            let mode = defaultMode ?? (exists && (existing.st_mode & S_IFMT) == S_IFREG ? existing.st_mode & 0o7777 : 0o644)
            fchmodat(parent.descriptor, staged, mode, AT_SYMLINK_NOFOLLOW)
        }
        guard renameat(parent.descriptor, staged, parent.descriptor, parent.name) == 0 else {
            let reason = String(cString: strerror(errno))
            unlinkat(parent.descriptor, staged, 0)
            throw AnchoredFileError.failed(location.path, reason)
        }
        return parent.created
    }
}
