import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

enum ComputerUseReadiness: String, Sendable, Equatable {
    case off
    case activating
    case ready
    case needsScreenRecording
    case needsAccessibility
    case unavailable
}

enum ComputerUseActivationStatus: String, Sendable, Equatable {
    case off
    case activating
    case on
    case blockedByPermission
    case unavailable
}

/// Settings-facing projection of the global Computer Use capability.
/// The user preference and the OS / runtime facts stay distinct: a missing TCC grant
/// never rewrites the preference to OFF. This is not an execution authority.
enum ComputerUseCapabilityStatus: String, Sendable, Equatable {
    case disabled
    case needsScreenRecording
    case needsAccessibility
    case runtimeUnavailable
    case ready
}

struct ComputerUseActivationRecord: Sendable, Equatable {
    let status: ComputerUseActivationStatus
    let readiness: ComputerUseReadiness
    let conversationID: UUID?
    let permissionModeAtActivation: PermissionMode?
    let activationInstant: Date?

    init(
        status: ComputerUseActivationStatus,
        readiness: ComputerUseReadiness? = nil,
        conversationID: UUID? = nil,
        permissionModeAtActivation: PermissionMode? = nil,
        activationInstant: Date? = nil
    ) {
        self.status = status
        self.readiness = readiness ?? {
            switch status {
            case .off: return .off
            case .activating: return .activating
            case .on: return .ready
            case .blockedByPermission: return .needsScreenRecording
            case .unavailable: return .unavailable
            }
        }()
        self.conversationID = conversationID
        self.permissionModeAtActivation = permissionModeAtActivation
        self.activationInstant = activationInstant
    }
}

/// Authoritative owner of Layer-1 Computer Use activation state.
/// Holds two distinct facts (computer-use-global-enablement-change-note):
/// - Global Capability Enablement: the persistent user preference set only from Settings.
/// - Execution session: the run-scoped binding of one conversation, its readiness and its
///   generation fence. Conversation boundaries, cancellation and mode changes end the session;
///   they never change the global preference.
@MainActor
@Observable
final class ComputerUseActivationStore {
    private(set) var isGloballyEnabled: Bool = false
    private(set) var capabilityStatus: ComputerUseCapabilityStatus = .disabled
    private(set) var readiness: ComputerUseReadiness = .off
    private(set) var activeConversationID: UUID? = nil
    private var desiredConversationID: UUID? = nil
    private(set) var permissionModeAtActivation: PermissionMode? = nil
    private(set) var activationInstant: Date? = nil
    private(set) var statusMessage: String? = nil

    var status: ComputerUseActivationStatus {
        switch readiness {
        case .off: return .off
        case .activating: return .activating
        case .ready: return .on
        case .needsScreenRecording, .needsAccessibility: return .blockedByPermission
        case .unavailable: return .unavailable
        }
    }

    @ObservationIgnored
    private let authorizer: ScreenRecordingPermissionAuthorizing
    @ObservationIgnored
    private var accessibilityAuthorizer: AccessibilityPermissionAuthorizing?
    @ObservationIgnored
    private var runtimeAvailabilityProvider: (@Sendable () -> (observationAvailable: Bool, actionAvailable: Bool))?
    @ObservationIgnored
    private let logs: DebugLogStore?
    @ObservationIgnored
    private let preferenceFileURL: URL?

    /// Whether a conversation has a run in progress. While the session's conversation has one,
    /// another conversation's run is refused the session instead of taking it over.
    @ObservationIgnored
    var conversationIsRunning: (@MainActor (UUID) -> Bool)?
    /// A conversation's title, for the refusal message.
    @ObservationIgnored
    var conversationTitle: (@MainActor (UUID) -> String?)?
    /// Runs refused the session: the conversation that held it and the mode to bind with once it is free.
    @ObservationIgnored
    private var refusedSessions: [UUID: (holder: UUID, mode: PermissionMode)] = [:]

    @ObservationIgnored
    private var monotonicGeneration: UInt64 = 0
    @ObservationIgnored
    private var sessionGenerations: [String: UInt64] = [:]
    @ObservationIgnored
    nonisolated(unsafe) private var activeObserver: (any NSObjectProtocol)? = nil

    init(
        authorizer: ScreenRecordingPermissionAuthorizing = MacScreenRecordingPermissionAuthorizer(),
        accessibilityAuthorizer: AccessibilityPermissionAuthorizing? = nil,
        runtimeAvailabilityProvider: (@Sendable () -> (observationAvailable: Bool, actionAvailable: Bool))? = nil,
        logs: DebugLogStore? = nil,
        preferenceFileURL: URL? = nil
    ) {
        self.authorizer = authorizer
        self.accessibilityAuthorizer = accessibilityAuthorizer
        self.runtimeAvailabilityProvider = runtimeAvailabilityProvider
        self.logs = logs
        self.preferenceFileURL = preferenceFileURL
        self.isGloballyEnabled = Self.loadGlobalPreference(from: preferenceFileURL, logs: logs)
        self.capabilityStatus = isGloballyEnabled ? .runtimeUnavailable : .disabled
        setupAppActiveObserver()
    }

    static let preferenceFileName = "computer_use_preferences_v1.json"

    private struct GlobalPreference: Codable {
        let schemaVersion: Int
        let globallyEnabled: Bool
    }

    /// Missing file means a new install or an upgrade: OFF. Unreadable or unknown schema fails closed (OFF).
    private static func loadGlobalPreference(from url: URL?, logs: DebugLogStore?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            let preference = try JSONDecoder().decode(GlobalPreference.self, from: Data(contentsOf: url))
            guard preference.schemaVersion == 1 else {
                logs?.error("ComputerUse", "Computer Use preference schema \(preference.schemaVersion) is unsupported; treating as OFF.")
                return false
            }
            return preference.globallyEnabled
        } catch {
            logs?.error("ComputerUse", "Computer Use preference could not be read; treating as OFF: \(error.localizedDescription)")
            return false
        }
    }

    private func persistGlobalPreference() {
        guard let preferenceFileURL else { return }
        do {
            try FileManager.default.createDirectory(at: preferenceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(GlobalPreference(schemaVersion: 1, globallyEnabled: isGloballyEnabled))
            try data.write(to: preferenceFileURL, options: .atomic)
        } catch {
            logs?.error("ComputerUse", "Failed to persist Computer Use preference: \(error.localizedDescription)")
        }
    }

    deinit {
        #if canImport(AppKit)
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    private func setupAppActiveObserver() {
        #if canImport(AppKit)
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshReadiness()
            }
        }
        #endif
    }

    func setAccessibilityAuthorizer(_ authorizer: AccessibilityPermissionAuthorizing?) {
        self.accessibilityAuthorizer = authorizer
        refreshReadiness()
    }

    func setRuntimeAvailabilityProvider(_ provider: (@Sendable () -> (observationAvailable: Bool, actionAvailable: Bool))?) {
        self.runtimeAvailabilityProvider = provider
        refreshReadiness()
    }

    var isActivated: Bool {
        isGloballyEnabled && activeConversationID != nil && (readiness == .ready || readiness == .needsAccessibility)
    }

    var record: ComputerUseActivationRecord {
        ComputerUseActivationRecord(
            status: status,
            readiness: readiness,
            conversationID: activeConversationID,
            permissionModeAtActivation: permissionModeAtActivation,
            activationInstant: activationInstant
        )
    }

    // MARK: - Readiness Refresh (Section 7, CU-I49)

    func refreshReadiness() {
        capabilityStatus = evaluateCapabilityStatus()
        guard isGloballyEnabled else {
            readiness = .off
            return
        }
        let effectiveID = activeConversationID ?? desiredConversationID
        guard let conversationID = effectiveID else {
            readiness = .off
            return
        }

        if let runtimeAvailability = runtimeAvailabilityProvider {
            let (obsAvail, actAvail) = runtimeAvailability()
            guard obsAvail && actAvail else {
                onDeactivated?()
                readiness = .unavailable
                statusMessage = "Computer Use runtime is unavailable."
                return
            }
        }

        let screenStatus = authorizer.authorizationStatus()
        guard screenStatus == .authorized else {
            onDeactivated?()
            readiness = .needsScreenRecording
            activeConversationID = nil
            statusMessage = "Screen Recording permission is required for Computer Use."
            return
        }

        // Screen Recording authorized: Layer 1 is active for the conversation
        activeConversationID = conversationID

        if let accessibilityAuthorizer {
            let axStatus = accessibilityAuthorizer.authorizationStatus()
            guard axStatus == .authorized else {
                onDeactivated?()
                readiness = .needsAccessibility
                statusMessage = "Computer Use needs Accessibility permission to control apps on your Mac."
                return
            }
        }

        readiness = .ready
        statusMessage = nil
    }

    /// Live OS / runtime facts for the Settings projection. Never changes the preference.
    private func evaluateCapabilityStatus() -> ComputerUseCapabilityStatus {
        guard isGloballyEnabled else { return .disabled }
        if let runtimeAvailabilityProvider {
            let (obsAvail, actAvail) = runtimeAvailabilityProvider()
            guard obsAvail && actAvail else { return .runtimeUnavailable }
        }
        guard authorizer.authorizationStatus() == .authorized else { return .needsScreenRecording }
        if let accessibilityAuthorizer, accessibilityAuthorizer.authorizationStatus() != .authorized {
            return .needsAccessibility
        }
        return .ready
    }

    // MARK: - Global Capability Enablement

    /// Settings gesture: the only production path that changes the persistent preference.
    /// Enabling performs one explicit Screen Recording readiness check; a denial leaves the
    /// preference ON and is reported through `capabilityStatus`. Disabling fences any session.
    @discardableResult
    func setGloballyEnabled(_ enabled: Bool) async -> ComputerUseCapabilityStatus {
        guard enabled else {
            deactivate()
            return capabilityStatus
        }
        if !isGloballyEnabled {
            isGloballyEnabled = true
            persistGlobalPreference()
            logs?.info("ComputerUse", "Computer Use enabled globally from Settings.")
        }
        if authorizer.authorizationStatus() != .authorized {
            _ = await authorizer.requestAccess()
        }
        refreshReadiness()
        return capabilityStatus
    }

    // MARK: - Run-Scoped Execution Session

    /// Establishes the current Run's execution session for `conversationID` through the canonical
    /// owner. No TCC prompt. A different previously bound conversation is fenced first (its
    /// generation advances, so its in-flight observations and actions become stale).
    @discardableResult
    func bindExecutionSession(conversationID: UUID, currentPermissionMode: PermissionMode) -> Bool {
        guard isGloballyEnabled else {
            refreshReadiness()
            return false
        }
        let current = activeConversationID ?? desiredConversationID
        if let current, current != conversationID, conversationIsRunning?(current) == true {
            refusedSessions[conversationID] = (current, currentPermissionMode)
            logs?.info("ComputerUse", "Computer Use refused to conversation '\(conversationID.uuidString.prefix(8))': conversation '\(current.uuidString.prefix(8))' is using it.")
            return false
        }
        refusedSessions[conversationID] = nil
        if current != conversationID || permissionModeAtActivation != currentPermissionMode {
            if let current {
                advanceGeneration(conversationID: current)
            }
            activeConversationID = nil
            desiredConversationID = conversationID
            permissionModeAtActivation = currentPermissionMode
            activationInstant = Date()
            logs?.info("ComputerUse", "Computer Use execution session bound to conversation '\(conversationID.uuidString.prefix(8))'.")
        }
        refreshReadiness()
        return isActivated && activeConversationID == conversationID
    }

    /// Binds a refused run once the conversation that held the session no longer runs.
    @discardableResult
    func claimReleasedSession(conversationID: UUID) -> Bool {
        guard let refused = refusedSessions[conversationID] else { return false }
        let holder = activeConversationID ?? desiredConversationID
        if let holder, holder != conversationID, conversationIsRunning?(holder) == true { return false }
        return bindExecutionSession(conversationID: conversationID, currentPermissionMode: refused.mode)
    }

    /// Why a refused run cannot use Computer Use, while the other conversation still holds it.
    func refusalReason(conversationID: UUID) -> String? {
        guard refusedSessions[conversationID] != nil,
              let holder = activeConversationID ?? desiredConversationID, holder != conversationID else { return nil }
        let title = conversationTitle?(holder).map { "「\($0)」" } ?? "另一个会话"
        return "Computer Use 正由会话\(title)使用，同一时间只能有一个会话控制电脑。请等那个会话的任务结束后再试。"
    }

    // MARK: - Layer 1 Activation Lifecycle

    /// Programmatic enable-and-bind (test and harness seam; no production UI calls it).
    /// Turns the global preference ON, performs the live TCC check (prompting if necessary)
    /// and binds the execution session to `conversationID`.
    @discardableResult
    func activate(conversationID: UUID, currentPermissionMode: PermissionMode) async -> Bool {
        logs?.info("ComputerUse", "Activation requested for conversation '\(conversationID.uuidString.prefix(8))' with mode \(currentPermissionMode.displayName).")
        if !isGloballyEnabled {
            isGloballyEnabled = true
            persistGlobalPreference()
        }
        readiness = .activating
        statusMessage = nil
        desiredConversationID = conversationID
        permissionModeAtActivation = currentPermissionMode
        activationInstant = Date()

        let currentScreenStatus = authorizer.authorizationStatus()
        if currentScreenStatus != .authorized {
            let granted = await authorizer.requestAccess()
            if !granted {
                onDeactivated?()
            readiness = .needsScreenRecording
                activeConversationID = nil
                statusMessage = "Screen Recording permission is required for Computer Use."
                logs?.info("ComputerUse", "Computer Use activation blocked: Screen Recording permission missing/denied.")
                return false
            }
        }

        activeConversationID = conversationID
        advanceGeneration(conversationID: conversationID)
        refreshReadiness()

        if readiness == .ready {
            logs?.info("ComputerUse", "Computer Use activated and ready for conversation '\(conversationID.uuidString.prefix(8))'.")
            return true
        } else if readiness == .needsAccessibility {
            logs?.info("ComputerUse", "Computer Use activated for conversation '\(conversationID.uuidString.prefix(8))', but blocked waiting for Accessibility permission.")
            return true
        } else {
            logs?.info("ComputerUse", "Computer Use activation incomplete: readiness is \(readiness.rawValue).")
            return false
        }
    }

    /// User manually disables Computer Use.
    var onDeactivated: (() -> Void)?

    /// Global OFF: persists the preference and fences any current execution session.
    func deactivate() {
        onDeactivated?()
        logs?.info("ComputerUse", "Computer Use disabled globally by user.")
        if isGloballyEnabled {
            isGloballyEnabled = false
            persistGlobalPreference()
        }
        capabilityStatus = .disabled
        if let activeID = activeConversationID ?? desiredConversationID {
            advanceGeneration(conversationID: activeID)
        }
        readiness = .off
        activeConversationID = nil
        desiredConversationID = nil
        permissionModeAtActivation = nil
        statusMessage = nil
    }

    /// Conversation boundary (switch / reset / end / delete) destroys the execution session
    /// (Doc 68 §10.1). The global preference is unchanged; the next Run binds a fresh session.
    func resetForConversationBoundary(leaving conversationID: UUID) {
        guard (activeConversationID ?? desiredConversationID) == conversationID else { return }
        if let activeID = activeConversationID ?? desiredConversationID {
            advanceGeneration(conversationID: activeID)
        }
        logs?.info("ComputerUse", "Computer Use execution session cleared at conversation boundary.")
        readiness = .off
        activeConversationID = nil
        desiredConversationID = nil
        permissionModeAtActivation = nil
        statusMessage = nil
    }

    /// Stop / run cancellation ends the execution session (Doc 68 §10.1); global preference unchanged.
    func suspendForRunCancellation(conversationID: UUID) {
        guard (activeConversationID == conversationID || desiredConversationID == conversationID), (readiness == .ready || readiness == .needsAccessibility || readiness == .needsScreenRecording) else { return }
        advanceGeneration(conversationID: conversationID)
        logs?.info("ComputerUse", "Computer Use suspended due to run cancellation for conversation '\(conversationID.uuidString.prefix(8))'.")
        readiness = .off
        activeConversationID = nil
        desiredConversationID = nil
        permissionModeAtActivation = nil
        statusMessage = nil
    }

    /// Run finished callback: normal completion and generic failure keep the session;
    /// only cancellation ends it (Doc 68 §10.1, §10.2).
    func onRunFinished(conversationID: UUID, status finishStatus: ConversationRunStatus) {
        refusedSessions[conversationID] = nil
        if finishStatus == .cancelled {
            suspendForRunCancellation(conversationID: conversationID)
        }
    }

    /// PermissionMode change ends the execution session (Doc 68 §10.1, §33); the next Run
    /// binds a fresh session under the new mode. Global preference unchanged.
    func onPermissionModeChanged(newMode: PermissionMode) {
        let effectiveID = activeConversationID ?? desiredConversationID
        if let conversationID = effectiveID, permissionModeAtActivation != newMode {
            advanceGeneration(conversationID: conversationID)
            logs?.info("ComputerUse", "Computer Use suspended due to PermissionMode change from \(permissionModeAtActivation?.displayName ?? "none") to \(newMode.displayName).")
            readiness = .off
            activeConversationID = nil
            desiredConversationID = nil
            permissionModeAtActivation = nil
            statusMessage = "Computer Use session ended due to permission mode change; the next run starts a new session."
        }
    }

    // MARK: - Generation Authority (§21, CU-OQ-04)

    private func sessionKey(conversationID: UUID, runID: UUID) -> String {
        "\(conversationID.uuidString):\(runID.uuidString)"
    }

    func currentGeneration(conversationID: UUID, runID: UUID) -> UInt64 {
        let key = sessionKey(conversationID: conversationID, runID: runID)
        if let existing = sessionGenerations[key] {
            return existing
        }
        sessionGenerations[key] = monotonicGeneration
        return monotonicGeneration
    }

    @discardableResult
    func advanceGeneration(conversationID: UUID, runID: UUID? = nil) -> UInt64 {
        onDeactivated?()
        monotonicGeneration += 1
        if let runID {
            let key = sessionKey(conversationID: conversationID, runID: runID)
            sessionGenerations[key] = monotonicGeneration
        } else {
            let prefix = conversationID.uuidString
            for key in sessionGenerations.keys where key.hasPrefix(prefix) {
                sessionGenerations[key] = monotonicGeneration
            }
        }
        return monotonicGeneration
    }

    func resetGeneration(conversationID: UUID, runID: UUID) {
        onDeactivated?()
        monotonicGeneration += 1
        let key = sessionKey(conversationID: conversationID, runID: runID)
        sessionGenerations.removeValue(forKey: key)
    }
}
