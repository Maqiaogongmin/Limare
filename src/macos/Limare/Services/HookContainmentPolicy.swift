import Foundation
import Darwin

public enum HookContainmentError: Error, LocalizedError, Sendable, Equatable {
    case sandboxExecutableUnavailable(path: String)
    case profileGenerationFailed(reason: String)
    case invalidProtectedPath(path: String, reason: String)
    case processSpawnFailed(reason: String)
    case hardLinkDetected(path: String, linkCount: Int)
    case storageInspectionFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .sandboxExecutableUnavailable(let path):
            return "Hook execution blocked: sandbox-exec containment mechanism is unavailable at '\(path)'."
        case .profileGenerationFailed(let reason):
            return "Hook execution blocked: failed to generate sandbox containment profile (\(reason))."
        case .invalidProtectedPath(let path, let reason):
            return "Hook execution blocked: invalid protected storage path '\(path)' (\(reason))."
        case .processSpawnFailed(let reason):
            return "Hook execution blocked: failed to launch contained subprocess (\(reason))."
        case .hardLinkDetected(let path, let linkCount):
            return "Hook execution blocked: protected storage contains a hard-linked file '\(path)' (link count \(linkCount)) and cannot be safely isolated."
        case .storageInspectionFailed(let path, let reason):
            return "Hook execution blocked: cannot inspect protected storage at '\(path)' (\(reason))."
        }
    }
}

public struct HookContainmentPolicy: Sendable, Equatable {
    public static let defaultSandboxExecutablePath = "/usr/bin/sandbox-exec"

    public let protectedStorageURL: URL
    public let sandboxExecutablePath: String

    public init(
        protectedStorageURL: URL? = nil,
        sandboxExecutablePath: String = Self.defaultSandboxExecutablePath
    ) {
        if let protectedStorageURL {
            self.protectedStorageURL = protectedStorageURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.protectedStorageURL = appSupport.appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        }
        self.sandboxExecutablePath = sandboxExecutablePath
    }

    public static func defaultPolicy() -> HookContainmentPolicy {
        HookContainmentPolicy()
    }

    public var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: sandboxExecutablePath)
    }

    public static func validatePathForSBPL(_ path: String) throws -> String {
        if path.contains("\0") || path.contains("\n") || path.contains("\r") {
            throw HookContainmentError.invalidProtectedPath(path: path, reason: "Path contains illegal control characters or newlines")
        }
        return path
    }

    public static func resolveCanonicalPath(_ rawPath: String) -> String {
        let standardized = (rawPath as NSString).standardizingPath
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if Darwin.realpath(standardized, &resolvedBuffer) != nil {
            return String(cString: resolvedBuffer)
        }
        // If the path itself does not exist on disk yet, resolve the deepest existing ancestor
        var current = standardized
        var trailingComponents: [String] = []
        while !current.isEmpty && current != "/" {
            let parent = (current as NSString).deletingLastPathComponent
            let comp = (current as NSString).lastPathComponent
            trailingComponents.insert(comp, at: 0)
            current = parent
            if Darwin.realpath(current, &resolvedBuffer) != nil {
                let resolvedParent = String(cString: resolvedBuffer)
                var result = resolvedParent
                for c in trailingComponents {
                    result = (result as NSString).appendingPathComponent(c)
                }
                return result
            }
        }
        return standardized
    }

    public static func escapeSBPLString(_ input: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(input.count + 16)
        for char in input {
            switch char {
            case "\\":
                escaped.append("\\\\")
            case "\"":
                escaped.append("\\\"")
            default:
                escaped.append(char)
            }
        }
        return escaped
    }

    public func protectedPathsForProfile() throws -> [String] {
        let rawStandardizedPath = protectedStorageURL.standardizedFileURL.path
        let canonicalPath = Self.resolveCanonicalPath(rawStandardizedPath)

        let validatedCanonical = try Self.validatePathForSBPL(canonicalPath)
        let validatedStandard = try Self.validatePathForSBPL(rawStandardizedPath)

        var paths = [validatedCanonical]
        if validatedStandard != validatedCanonical {
            paths.append(validatedStandard)
        }
        return paths
    }

    public func generateSeatbeltProfile() throws -> String {
        let protectedPaths = try protectedPathsForProfile()
        guard !protectedPaths.isEmpty else {
            throw HookContainmentError.profileGenerationFailed(reason: "No protected storage paths specified")
        }

        var sbpl = "(version 1)\n(allow default)\n"
        for path in protectedPaths {
            let escaped = Self.escapeSBPLString(path)
            sbpl.append("(deny file-write* (subpath \"\(escaped)\"))\n")
        }
        // Block interprocess delegation vectors (e.g. osascript / AppleEvents)
        sbpl.append("(deny appleevent-send)\n")

        // Deny creating hard links globally: path-based canonical write denial can
        // otherwise be bypassed through a hard-link alias outside the protected path.
        sbpl.append("(deny file-link)\n")

        return sbpl
    }

    /// Preflight check verifying that no regular file inside protected durable storage
    /// has a hard link count greater than 1 (which would indicate a pre-existing hard-link alias).
    public func validateNoHardLinkedFiles() throws {
        let root = protectedStorageURL.path
        var rootLink = stat()
        if lstat(root, &rootLink) != 0 {
            let code = errno
            // A fresh install can have no durable storage yet. Every other
            // lookup failure leaves the protected state unknown.
            if code == ENOENT { return }
            throw HookContainmentError.storageInspectionFailed(path: root, reason: String(cString: strerror(code)))
        }

        var rootInfo = stat()
        if fstatat(AT_FDCWD, root, &rootInfo, 0) != 0 {
            let code = errno
            throw HookContainmentError.storageInspectionFailed(path: root, reason: String(cString: strerror(code)))
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw HookContainmentError.storageInspectionFailed(path: root, reason: "protected root is not a directory")
        }

        try inspectDirectory(root)
    }

    private func inspectDirectory(_ path: String) throws {
        guard let directory = opendir(path) else {
            let code = errno
            throw HookContainmentError.storageInspectionFailed(path: path, reason: String(cString: strerror(code)))
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let code = errno
                if code != 0 {
                    throw HookContainmentError.storageInspectionFailed(path: path, reason: String(cString: strerror(code)))
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            let child = (path as NSString).appendingPathComponent(name)
            var info = stat()
            if lstat(child, &info) != 0 {
                let code = errno
                throw HookContainmentError.storageInspectionFailed(path: child, reason: String(cString: strerror(code)))
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                try inspectDirectory(child)
            case S_IFREG where info.st_nlink > 1:
                throw HookContainmentError.hardLinkDetected(path: child, linkCount: Int(info.st_nlink))
            default:
                break
            }
        }
    }
}
