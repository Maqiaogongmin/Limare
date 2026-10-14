import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Limare-owned exact window targeting store for Computer Use v0.2.
///
/// Under v0.2 architecture:
/// 1. Target identity is defined strictly by the `WindowTarget(bundleID, pid, windowID)` invariant.
/// 2. Target identity is completely decoupled from OS frontmost application state.
/// 3. Zero stealth focus shifts or restoration are permitted.
/// 4. Ambiguity in window resolution fails closed (`.targetAmbiguous`).
/// 5. Process death or window destruction is immediately detected (`.targetDestroyed`).
public actor ComputerUseTargetStore {
    public struct SessionKey: Hashable, Sendable {
        public let conversationID: String
        public let runID: String

        public init(conversationID: String, runID: String) {
            self.conversationID = conversationID
            self.runID = runID
        }
    }

    private var targets: [SessionKey: WindowTarget] = [:]

    public init() {}

    /// Sets or updates the active window target for a session.
    public func setTarget(_ target: WindowTarget, conversationID: String, runID: String) {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        targets[key] = target
    }

    /// Retrieves the stored target for a session.
    public func getTarget(conversationID: String, runID: String) -> WindowTarget? {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        return targets[key]
    }

    /// Clears the stored target for a session.
    public func clearTarget(conversationID: String, runID: String) {
        let key = SessionKey(conversationID: conversationID, runID: runID)
        targets.removeValue(forKey: key)
    }

    /// Clears all stored targets.
    public func clearAll() {
        targets.removeAll()
    }

    /// Canonicalize an app name without running it. Bundle IDs remain valid even if
    /// the catalogue has not discovered the installation; protected IDs are classified later.
    public func resolveApplicationBundleID(driver: any ComputerUseDriver, identity: String) async throws -> String {
        if identity.contains(".") && !identity.contains(" ") { return identity }
        let apps = try await driver.listApplications()
        let matches = apps.filter { $0.name.caseInsensitiveCompare(identity) == .orderedSame }
        if matches.count == 1 { return matches[0].bundleID }
        #if canImport(AppKit)
        let resolved: String? = await MainActor.run {
            guard let path = NSWorkspace.shared.fullPath(forApplication: identity) else { return nil }
            return Bundle(path: path)?.bundleIdentifier
        }
        if let resolved { return resolved }
        #endif
        throw ComputerUseDriverError.targetNotFound(detail: "App name not uniquely resolvable; supply its bundle ID from list_apps.")
    }

    /// Non-launching identity resolution. Case normalization is generic across all apps.
    public func resolveRunningApplication(driver: any ComputerUseDriver, bundleID: String) async throws -> ApplicationInfo {
        let canonical = try await resolveApplicationBundleID(driver: driver, identity: bundleID)
        let matches = try await driver.listApplications().filter {
            $0.bundleID.caseInsensitiveCompare(canonical) == .orderedSame && $0.isRunning && ($0.pid ?? 0) > 0
        }
        guard !matches.isEmpty else {
            throw ComputerUseDriverError.targetNotFound(detail: "targetNotRunning: \(bundleID). Use explicit launch_app first.")
        }
        guard matches.count == 1 else {
            throw ComputerUseDriverError.targetAmbiguous(detail: "Multiple live processes for \(bundleID)")
        }
        return matches[0]
    }

    nonisolated public static func usableWindows(_ windows: [WindowInfo], pid: Int) -> [WindowInfo] {
        windows.filter { $0.pid == pid && $0.bounds.width > 10 && $0.bounds.height > 10 && $0.isOnScreen != false && ($0.layer == nil || $0.layer == 0) }
    }

    public func bindUniqueWindow(windows: [WindowInfo], bundleID: String, pid: Int,
                                 conversationID: String, runID: String) throws -> WindowTarget {
        let valid = Self.usableWindows(windows, pid: pid)
        guard !valid.isEmpty else {
            throw ComputerUseDriverError.targetNotFound(detail: "targetNotFound: \(bundleID) is running but has no window of its own on screen (an Open/Save panel belongs to another process). Get a window of the app open first (for a document app, `osascript -e 'tell application id \"\(bundleID)\" to make new document'` through shell_execute, or ask the user), then capture again.")
        }
        guard valid.count == 1 else {
            throw ComputerUseDriverError.targetAmbiguous(detail: "targetAmbiguous: \(valid.map(\.windowID))")
        }
        let window = valid[0]
        let target = WindowTarget(bundleID: bundleID, pid: pid, windowID: window.windowID, title: window.title)
        setTarget(target, conversationID: conversationID, runID: runID)
        return target
    }

    public func resolveExistingTarget(driver: any ComputerUseDriver, conversationID: String, runID: String,
                                      bundleID: String, requiredPID: Int? = nil, windowID: Int? = nil, preferredTitle: String? = nil) async throws -> WindowTarget {
        let app = try await resolveRunningApplication(driver: driver, bundleID: bundleID)
        guard let pid = app.pid, requiredPID == nil || requiredPID == pid else {
            throw ComputerUseDriverError.targetDestroyed(detail: "Process changed; explicit target rediscovery required.")
        }
        func candidates() async throws -> [WindowInfo] {
            try await driver.listWindows(pid: pid).filter { (windowID == nil || $0.windowID == windowID) && (preferredTitle == nil || ($0.title ?? "").localizedCaseInsensitiveContains(preferredTitle!)) }
        }
        var windows = try await candidates()
        // A just-launched app may need a moment to put its window on screen.
        for _ in 0..<6 where Self.usableWindows(windows, pid: pid).isEmpty {
            try await Task.sleep(for: .milliseconds(500))
            windows = try await candidates()
        }
        return try bindUniqueWindow(windows: windows, bundleID: app.bundleID,
                                   pid: pid, conversationID: conversationID, runID: runID)
    }

    /// Verifies that the stored target is still alive and has not been destroyed.
    /// Fails closed with `.targetDestroyed` if process is dead or window no longer exists.
    public func verifyTargetAlive(driver: any ComputerUseDriver, target: WindowTarget) async throws -> Bool {
        // 1. Process liveness check
        if kill(Int32(target.pid), 0) != 0 && errno == ESRCH {
            throw ComputerUseDriverError.targetDestroyed(detail: "Target process '\(target.bundleID)' (pid: \(target.pid)) is no longer running")
        }

        // 2. Window liveness check
        let windows = try await driver.listWindows(pid: target.pid)
        guard Self.usableWindows(windows, pid: target.pid).contains(where: { $0.windowID == target.windowID }) else {
            throw ComputerUseDriverError.targetDestroyed(detail: "Target window \(target.windowID) for '\(target.bundleID)' (pid: \(target.pid)) no longer exists")
        }

        return true
    }
}
