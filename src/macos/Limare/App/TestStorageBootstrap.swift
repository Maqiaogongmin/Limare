import Foundation

/// Bounded test-only storage root bootstrap for macOS UI testing (AC-B11, AC-B12).
///
/// In ordinary launches, this returns `nil` so `AppState` defaults to the standard
/// Application Support directory.
///
/// When `UI_TEST_MODE` is enabled, a valid isolated temporary storage root MUST be provided
/// via `UI_TEST_STORAGE_ROOT`. If missing, invalid, or resolving into the production
/// Application Support directory, initialization FAILS CLOSED immediately before any live
/// stores can be initialized.
public enum TestStorageBootstrap {
    public static let uiTestModeKey = "UI_TEST_MODE"
    public static let uiTestStorageRootKey = "UI_TEST_STORAGE_ROOT"

    public enum ValidationDecision: Equatable, Sendable {
        case valid(URL)
        case notActive
        case rejected(String)
    }

    /// Evaluates launch environment and returns the validation decision without terminating the process.
    public static func validateStorageRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ValidationDecision {
        guard let testMode = environment[uiTestModeKey], isTruthful(testMode) else {
            return .notActive
        }

        guard let rawRoot = environment[uiTestStorageRootKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawRoot.isEmpty else {
            return .rejected("UI_TEST_MODE is active but UI_TEST_STORAGE_ROOT environment variable is missing or empty")
        }

        let targetURL = canonicalize(URL(fileURLWithPath: rawRoot))

        // 1. Must NOT point into or equal production Application Support
        if let liveAppSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let canonicalLive = canonicalize(liveAppSupport)
            if isDescendant(of: canonicalLive, target: targetURL) {
                return .rejected("UI_TEST_STORAGE_ROOT points into production Application Support: \(targetURL.path)")
            }
        }

        // 2. Explicitly reject safe roots themselves (STORE-B05)
        let forbiddenRoots: Set<String> = [
            "/tmp",
            "/private/tmp",
            "/var/folders",
            "/private/var/folders",
            URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path,
            canonicalize(URL(fileURLWithPath: NSTemporaryDirectory())).path
        ]
        let rawStandardized = URL(fileURLWithPath: rawRoot).standardizedFileURL.path
        if forbiddenRoots.contains(targetURL.path) || forbiddenRoots.contains(rawStandardized) {
            return .rejected("UI_TEST_STORAGE_ROOT cannot be an authorized safe temporary root itself: \(targetURL.path)")
        }

        // 3. Must be a strict descendant of an authorized safe temporary root (STORE-B06)
        let safeRoots: [URL] = [
            canonicalize(URL(fileURLWithPath: NSTemporaryDirectory())),
            canonicalize(URL(fileURLWithPath: "/tmp")),
            canonicalize(URL(fileURLWithPath: "/private/tmp")),
        ]

        var isContainedInSafeRoot = false
        for safeRoot in safeRoots {
            if isStrictDescendant(of: safeRoot, target: targetURL) {
                isContainedInSafeRoot = true
                break
            }
        }

        guard isContainedInSafeRoot else {
            return .rejected("UI_TEST_STORAGE_ROOT is not contained within an authorized safe temporary root: \(targetURL.path)")
        }

        return .valid(targetURL)
    }

    /// Evaluates launch environment and returns the validated test storage URL,
    /// or `nil` for standard production launches.
    /// Fails closed (terminates process) if `UI_TEST_MODE` is active but storage root is invalid.
    /// The launch environment, plus `--ui-test-storage-root <dir>` from the arguments for
    /// launchers that can pass arguments but not environment variables (background GUI
    /// drivers). The root goes through the same checks either way.
    public static func launchEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> [String: String] {
        var result = environment
        if let index = arguments.firstIndex(of: "--ui-test-storage-root"), index + 1 < arguments.count {
            result[uiTestModeKey] = "1"
            result[uiTestStorageRootKey] = arguments[index + 1]
        }
        return result
    }

    public static func resolveStorageRoot(
        environment: [String: String] = launchEnvironment()
    ) -> URL? {
        switch validateStorageRoot(environment: environment) {
        case .notActive:
            return nil
        case .rejected(let reason):
            failClosed(reason: reason)
        case .valid(let targetURL):
            // Safely creatable or already an accessible directory
            var isDir: ObjCBool = false
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDir) {
                guard isDir.boolValue else {
                    failClosed(reason: "UI_TEST_STORAGE_ROOT exists but is not a directory: \(targetURL.path)")
                }
            } else {
                do {
                    try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
                } catch {
                    failClosed(reason: "Failed to create UI_TEST_STORAGE_ROOT at \(targetURL.path): \(error.localizedDescription)")
                }
            }
            return targetURL
        }
    }

    /// Fully canonicalizes a URL by traversing up to the first existing ancestor to resolve symlinks.
    public static func canonicalize(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var trailingComponents: [String] = []
        let fileManager = FileManager.default

        while !fileManager.fileExists(atPath: existing.path) && existing.path != "/" {
            trailingComponents.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath()
        for component in trailingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// Checks if `target` is equal to `parent` or is a strict path component descendant.
    public static func isDescendant(of parent: URL, target: URL) -> Bool {
        let parentPath = parent.path
        let targetPath = target.path
        if parentPath == targetPath {
            return true
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return targetPath.hasPrefix(prefix)
    }

    /// Checks if `target` is a strict path component descendant of `parent` (not equal to `parent`).
    public static func isStrictDescendant(of parent: URL, target: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        if parentPath == targetPath {
            return false
        }
        let prefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return targetPath.hasPrefix(prefix)
    }

    private static func isTruthful(_ val: String) -> Bool {
        let normalized = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }

    @inline(never)
    private static func failClosed(reason: String) -> Never {
        fputs("FATAL: [TestStorageBootstrap] \(reason)\n", stderr)
        fflush(stderr)
        exit(1)
    }
}
