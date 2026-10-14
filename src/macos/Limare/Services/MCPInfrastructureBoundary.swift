import Foundation
import Darwin

/// Product authority policy shared by native file tools and child execution policy.
enum MCPInfrastructureBoundary {
    static var protectedRoots: [URL] {
        let root = LimareStorage.applicationSupport.appendingPathComponent(LimareStorage.bundleIdentifier)
        var roots = [root.appendingPathComponent("mcp-host"), root.appendingPathComponent("mcp_servers.json"),
                     root.appendingPathComponent("secrets"),
                     URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Keychains"),
                     URL(fileURLWithPath: "/Library/Keychains")]
        if Bundle.main.bundleURL.pathExtension == "app" { roots.append(Bundle.main.bundleURL) }
        return roots
    }

    struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }

    /// Regular files inside the reserved roots that also have another name somewhere.
    /// Seatbelt and path checks only see names, so such an alias defeats both.
    static func aliasedProtectedFiles(roots: [URL]) throws -> Set<FileIdentity> {
        var result: Set<FileIdentity> = []
        for root in roots {
            let canonical = TestStorageBootstrap.canonicalize(root)
            var paths = [canonical.path]
            if let enumerator = FileManager.default.enumerator(atPath: canonical.path) {
                while let relative = enumerator.nextObject() as? String {
                    paths.append((canonical.path as NSString).appendingPathComponent(relative))
                }
            }
            for path in paths {
                var info = stat()
                guard lstat(path, &info) == 0 else {
                    if errno == ENOENT { continue }
                    throw MCPHostControlError.protectedInfrastructure
                }
                if info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 {
                    result.insert(FileIdentity(device: info.st_dev, inode: info.st_ino))
                }
            }
        }
        return result
    }

    static func requireAgentFileAccess(to url: URL, roots: [URL]? = nil) throws {
        var checker = AccessChecker(roots: roots ?? protectedRoots)
        try checker.require(url)
    }

    /// One check context per tool operation, so enumerations do not rescan the reserved roots per file.
    struct AccessChecker {
        private let roots: [URL]
        private var aliases: Set<FileIdentity>?
        init(roots: [URL] = MCPInfrastructureBoundary.protectedRoots) {
            self.roots = roots.map(TestStorageBootstrap.canonicalize)
        }

        mutating func require(_ url: URL) throws {
            let canonical = TestStorageBootstrap.canonicalize(url)
            // APFS names are case- and normalization-insensitive; components that do not exist yet
            // keep the caller's spelling, so compare folded paths.
            for root in roots where isDescendant(of: root, target: canonical) {
                throw MCPHostControlError.protectedInfrastructure
            }
            var info = stat()
            guard stat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 else { return }
            // Unrelated hardlinks (package stores, backups) stay usable; only aliases of reserved files are refused.
            if aliases == nil { aliases = try aliasedProtectedFiles(roots: roots) }
            if aliases?.contains(FileIdentity(device: info.st_dev, inode: info.st_ino)) == true {
                throw MCPHostControlError.protectedInfrastructure
            }
        }
    }

    private static func folded(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.lowercased()
    }

    private static func isDescendant(of parent: URL, target: URL) -> Bool {
        let parentPath = folded(parent.path)
        let targetPath = folded(target.path)
        return targetPath == parentPath || targetPath.hasPrefix(parentPath.hasSuffix("/") ? parentPath : parentPath + "/")
    }
}
