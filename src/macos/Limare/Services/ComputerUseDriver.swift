import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Limare-owned mechanical execution driver abstraction for Computer Use v0.2.
///
/// In Stage 1, this protocol defines strictly mechanical lifecycle operations.
/// It contains ZERO raw driver tool invocation methods, zero policy authority,
/// zero approval UX, and zero task verdict logic.
public protocol ComputerUseDriver: Sendable {
    func prepareRunSession(runID: UUID) async throws -> ComputerUseDriverRunSession
    func finishRunSession(runID: UUID) async throws
    func drainSessionDiagnostics(runID: UUID) async -> [String]
    func finishConversationSessions(conversationID: UUID, createdBefore: Date) async
    func finishAllRunSessions() async

    /// Starts the mechanical driver backend process and performs protocol handshake.
    /// Idempotent if already in `.ready` state.
    func start() async throws

    /// Returns current mechanical readiness state.
    func readiness() async -> ComputerUseDriverReadiness

    /// Gracefully stops the mechanical driver backend process and closes all pipes.
    /// Idempotent.
    func shutdown() async

    /// Stage 2: Lists running desktop applications discovered by the driver backend.
    func listApplications() async throws -> [ApplicationInfo]

    /// Stage 2: Lists visible windows for a specific target process.
    func listWindows(pid: Int) async throws -> [WindowInfo]

    /// Stage 2: Launches an application by bundle identifier, optionally suppressing activation.
    func launchApplication(bundleID: String, background: Bool) async throws -> ApplicationLaunchResult

    /// Stage 3: Observes window state and captures normalized AX elements + window screenshot.
    func observeWindow(target: WindowTarget) async throws -> ComputerUseObservation

    /// Stage 5: Performs a mechanical click on a generation-bound element reference.
    func click(element: ComputerUseElementRef) async throws -> ComputerUseDriverActionResult
    func click(element: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Performs a double click on an element reference.
    func doubleClick(element: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Performs a right click on an element reference.
    func rightClick(element: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Injects typed text into a target element or window.
    func typeText(text: String, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Injects a key press into a target window.
    func pressKey(key: String, target: WindowTarget, modifiers: [String]?, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Injects a hotkey chord into a target window.
    func hotkey(keys: [String], target: WindowTarget, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Directly sets the native accessibility value of an element.
    func setValue(value: String, element: ComputerUseElementRef) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Scrolls inside a window or element.
    func scroll(direction: String, amount: Int?, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 7: Drags from one element to another within the target window.
    func drag(from: ComputerUseElementRef, to: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult

    /// Stage 8: Governed foreground activation of a target window.
    /// Strictly tracked and governed; never stealthily steals focus.
    func activateWindow(target: WindowTarget) async throws -> Bool
}

/// Immutable execution scope propagated by the authoritative engine, never by tool arguments.
/// Task-local scope is call-bound; there is no shared mutable current-run identity.
public struct ComputerUseDriverExecutionContext: Sendable {
    public let runID: UUID
    public var conversationID: UUID? = nil
    public let isAuthoritative: @Sendable () async -> Bool
    @TaskLocal public static var current: ComputerUseDriverExecutionContext?
}

public struct ComputerUseDriverRunSession: Equatable, Sendable {
    public enum Ensure: String, Sendable { case created, active, revived }
    public let runID: UUID
    public let publicSessionLabel: String
    public let transportGeneration: Int
    public let generation: Int
    public let ensure: Ensure
}

public extension ComputerUseDriver {
    func prepareRunSession(runID: UUID) async throws -> ComputerUseDriverRunSession {
        ComputerUseDriverRunSession(runID: runID, publicSessionLabel: "limare-" + runID.uuidString.lowercased(),
            transportGeneration: await readiness().currentGeneration ?? 0, generation: 1, ensure: .active)
    }
    func finishRunSession(runID: UUID) async throws {}
    func drainSessionDiagnostics(runID: UUID) async -> [String] { [] }
    func finishConversationSessions(conversationID: UUID, createdBefore: Date) async {}
    func finishAllRunSessions() async {}

    func activateWindow(target: WindowTarget) async throws -> Bool {
        #if canImport(AppKit)
        if let app = NSRunningApplication(processIdentifier: pid_t(target.pid)) {
            return app.activate(options: [])
        }
        #endif
        return true
    }

    func click(element: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult {
        try await click(element: element)
    }

    func doubleClick(element: ComputerUseElementRef, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "double_click", reason: "double_click not implemented")
    }

    func rightClick(element: ComputerUseElementRef, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "right_click", reason: "right_click not implemented")
    }

    func typeText(text: String, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "type_text", reason: "type_text not implemented")
    }

    func pressKey(key: String, target: WindowTarget, modifiers: [String]? = nil, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "press_key", reason: "press_key not implemented")
    }

    func hotkey(keys: [String], target: WindowTarget, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "hotkey", reason: "hotkey not implemented")
    }

    func setValue(value: String, element: ComputerUseElementRef) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "set_value", reason: "set_value not implemented")
    }

    func scroll(direction: String, amount: Int? = nil, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "scroll", reason: "scroll not implemented")
    }

    func drag(from: ComputerUseElementRef, to: ComputerUseElementRef, deliveryMode: String? = nil) async throws -> ComputerUseDriverActionResult {
        throw ComputerUseDriverError.driverToolFailed(tool: "drag", reason: "drag not implemented")
    }
}

/// Geometry bounds of a window in screen coordinates.
public struct WindowBounds: Equatable, Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Exact window targeting identity for Computer Use v0.2.
/// Limare targets windows by invariant (bundleID, pid, windowID) tuple,
/// never by frontmost OS window or ephemeral title matching alone.
public struct WindowTarget: Equatable, Hashable, Sendable, Codable {
    public let bundleID: String
    public let pid: Int
    public let windowID: Int
    public let title: String?

    public init(bundleID: String, pid: Int, windowID: Int, title: String? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.title = title
    }
}

/// Information about a discovered running application.
public struct ApplicationInfo: Equatable, Hashable, Sendable, Codable {
    public let bundleID: String
    public let pid: Int?
    public let name: String
    public let isRunning: Bool
    public let discoveryConsistency: String?
    public let driverReportedPID: Int?
    public let driverReportedRunning: Bool?

    public init(bundleID: String, pid: Int?, name: String, isRunning: Bool, discoveryConsistency: String? = nil, driverReportedPID: Int? = nil, driverReportedRunning: Bool? = nil) {
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
        self.isRunning = isRunning
        self.discoveryConsistency = discoveryConsistency
        self.driverReportedPID = driverReportedPID
        self.driverReportedRunning = driverReportedRunning
    }
}

/// Information about a discovered window.
public struct WindowInfo: Equatable, Hashable, Sendable, Codable {
    public let windowID: Int
    public let pid: Int
    public let title: String?
    public let bounds: WindowBounds
    public let isOnScreen: Bool?
    public let layer: Int?

    public init(windowID: Int, pid: Int, title: String?, bounds: WindowBounds, isOnScreen: Bool? = nil, layer: Int? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.bounds = bounds
        self.isOnScreen = isOnScreen
        self.layer = layer
    }
}

/// Result of launching an application via the mechanical backend.
public struct ApplicationLaunchResult: Equatable, Hashable, Sendable, Codable {
    public let bundleID: String
    public let pid: Int
    public let windows: [WindowInfo]

    public init(bundleID: String, pid: Int, windows: [WindowInfo]) {
        self.bundleID = bundleID
        self.pid = pid
        self.windows = windows
    }
}

/// Normalized accessibility element snapshot within an observed window.
public struct ComputerUseElement: Equatable, Hashable, Sendable, Codable {
    public let token: String
    public let index: Int
    public let role: String
    public let label: String?
    public let title: String?
    public let value: String?
    public let isEnabled: Bool
    public let actions: [String]
    public let screenFrame: WindowBounds
    public let normalizedFrame: WindowBounds

    public init(
        token: String,
        index: Int,
        role: String,
        label: String? = nil,
        title: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        actions: [String] = [],
        screenFrame: WindowBounds,
        normalizedFrame: WindowBounds
    ) {
        self.token = token
        self.index = index
        self.role = role
        self.label = label
        self.title = title
        self.value = value
        self.isEnabled = isEnabled
        self.actions = actions
        self.screenFrame = screenFrame
        self.normalizedFrame = normalizedFrame
    }
}

/// Normalized window observation for Computer Use v0.2.
/// Contains target identity, window geometry, normalized AX elements,
/// and raw window-only screenshot bytes (with optional materialized artifact ID).
public struct ComputerUseObservation: Equatable, Sendable {
    public let snapshotID: String
    public let target: WindowTarget
    public let windowBounds: WindowBounds
    public let elements: [ComputerUseElement]
    public let treeMarkdown: String?
    public let screenshotData: Data?
    public var screenshotArtifactID: UUID?
    public let timestamp: Date

    public init(
        snapshotID: String,
        target: WindowTarget,
        windowBounds: WindowBounds,
        elements: [ComputerUseElement],
        treeMarkdown: String? = nil,
        screenshotData: Data? = nil,
        screenshotArtifactID: UUID? = nil,
        timestamp: Date = Date()
    ) {
        self.snapshotID = snapshotID
        self.target = target
        self.windowBounds = windowBounds
        self.elements = elements
        self.treeMarkdown = treeMarkdown
        self.screenshotData = screenshotData
        self.screenshotArtifactID = screenshotArtifactID
        self.timestamp = timestamp
    }
}

/// Model-facing element reference bound to a specific observation snapshot and driver generation.
public struct ComputerUseElementRef: Equatable, Hashable, Sendable, Codable {
    public let refID: String                 // e.g. "e1", "e2"
    public let generation: Int               // Driver incarnation generation
    public let snapshotID: String            // Observation snapshot identifier
    public let backendToken: String          // Upstream driver token e.g. "s00000001:14"
    public let target: WindowTarget          // Associated window target
    public let role: String                  // Accessibility role
    public let label: String?                // Human-readable label
    public let normalizedFrame: WindowBounds // Window-relative geometry

    public init(
        refID: String,
        generation: Int,
        snapshotID: String,
        backendToken: String,
        target: WindowTarget,
        role: String,
        label: String?,
        normalizedFrame: WindowBounds
    ) {
        self.refID = refID
        self.generation = generation
        self.snapshotID = snapshotID
        self.backendToken = backendToken
        self.target = target
        self.role = role
        self.label = label
        self.normalizedFrame = normalizedFrame
    }
}

/// Normalized result receipt for a mechanical action executed by ComputerUseDriver.
public struct ComputerUseDriverActionResult: Equatable, Sendable, Codable {
    public let receiptID: UUID
    public let actionType: String
    public let elementRef: ComputerUseElementRef?
    public let timestamp: Date
    public let isSuccess: Bool
    public let route: String?
    public let mode: String?
    public let effect: String?
    public let detail: String?

    public init(
        receiptID: UUID = UUID(),
        actionType: String,
        elementRef: ComputerUseElementRef? = nil,
        timestamp: Date = Date(),
        isSuccess: Bool,
        route: String? = nil,
        mode: String? = nil,
        effect: String? = nil,
        detail: String? = nil
    ) {
        self.receiptID = receiptID
        self.actionType = actionType
        self.elementRef = elementRef
        self.timestamp = timestamp
        self.isSuccess = isSuccess
        self.route = route
        self.mode = mode
        self.effect = effect
        self.detail = detail
    }
}

/// Transport readiness only: process/handshake health. A run session is separately ensured lazily.
public enum ComputerUseDriverReadiness: Equatable, Sendable {
    case stopped
    case starting
    case ready(generation: Int)
    case stopping
    case failed(ComputerUseDriverError)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var currentGeneration: Int? {
        if case .ready(let gen) = self { return gen }
        return nil
    }
}

/// Strongly-typed errors for ComputerUseDriver lifecycle and transport failures.
public enum ComputerUseDriverError: LocalizedError, Equatable, Sendable {
    case driverExecutableMissing(path: String?)
    case driverNotExecutable(path: String)
    case spawnFailed(reason: String)
    case handshakeFailed(reason: String)
    case protocolMalformed(detail: String)
    case protocolFrameTooLarge(limit: Int)
    case requiredToolMissing(missingTools: [String])
    case connectionClosed(detail: String)
    case unexpectedExit(statusCode: Int32, stderrTail: String?)
    case cancelled
    case shutdownTimeout
    case targetAmbiguous(detail: String)
    case targetDestroyed(detail: String)
    case targetNotFound(detail: String)
    case driverToolFailed(tool: String, reason: String)
    case staleElementReference(detail: String)
    case elementNotFound(detail: String)

    public var errorDescription: String? {
        switch self {
        case .driverExecutableMissing(let path):
            return "cua-driver executable missing at: \(path ?? "Contents/Helpers/cua-driver")"
        case .driverNotExecutable(let path):
            return "cua-driver binary at '\(path)' is not executable"
        case .spawnFailed(let reason):
            return "Failed to spawn cua-driver process: \(reason)"
        case .handshakeFailed(let reason):
            return "cua-driver MCP handshake failed: \(reason)"
        case .protocolMalformed(let detail):
            return "Malformed MCP JSON-RPC protocol message: \(detail)"
        case .protocolFrameTooLarge(let limit):
            return "MCP protocol frame exceeded maximum buffer limit of \(limit) bytes"
        case .requiredToolMissing(let missing):
            return "Missing required foundational driver tools: \(missing.joined(separator: ", "))"
        case .connectionClosed(let detail):
            return "Driver transport connection closed: \(detail)"
        case .unexpectedExit(let code, let tail):
            let tailStr = tail.map { " Stderr tail: \($0)" } ?? ""
            return "cua-driver process exited unexpectedly with code \(code).\(tailStr)"
        case .cancelled:
            return "Driver operation was cancelled"
        case .shutdownTimeout:
            return "Driver process shutdown timed out; child process did not confirm exit"
        case .targetAmbiguous(let detail):
            return "Target window ambiguous: \(detail)"
        case .targetDestroyed(let detail):
            return "Target window or process has been destroyed: \(detail)"
        case .targetNotFound(let detail):
            return "Target application or window not found: \(detail)"
        case .driverToolFailed(let tool, let reason):
            return "Driver tool '\(tool)' failed: \(reason)"
        case .staleElementReference(let detail):
            return "Stale or invalid element reference: \(detail)"
        case .elementNotFound(let detail):
            return "Element reference not found: \(detail)"
        }
    }
}
