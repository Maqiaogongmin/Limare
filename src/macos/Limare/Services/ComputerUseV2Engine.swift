import Foundation
import CoreGraphics
import ApplicationServices
#if canImport(AppKit)
import AppKit
#endif

/// Abstract protocol for Layer 1 activation verification.
public protocol ComputerUseActivationProviding: Sendable {
    func isActivated(conversationID: UUID) async -> Bool
    func currentGeneration(conversationID: UUID, runID: UUID) async -> Int
    /// Why Computer Use is unavailable to the conversation, when there is a reason to tell.
    func unavailableReason(conversationID: UUID) async -> String?
}

public extension ComputerUseActivationProviding {
    func unavailableReason(conversationID: UUID) async -> String? { nil }
}

/// Abstract protocol for Layer 2 application authorization.
public protocol ComputerUseAppAuthorizing: Sendable {
    func getAuthorizationStatus(conversationID: UUID, bundleID: String) async -> ComputerUseAppAuthorizationState
    func requestAppApproval(conversationID: UUID, bundleID: String, appLocalizedName: String) async -> ComputerUseAppAuthorizationState
    /// The text the model gets when an app was not granted because no one can grant it now (an
    /// unattended scheduled run); nil when a person declined or the request was cancelled.
    func unattendedRefusal(conversationID: UUID, appName: String) async -> String?
}

extension ComputerUseAppAuthorizing {
    public func unattendedRefusal(conversationID: UUID, appName: String) async -> String? { nil }
}

/// Limare-owned Control Plane & Execution Engine for Computer Use v0.2.
/// Coordinates activation, per-app approval, exact targeting, element references and the driver.
/// As in Anthropic's computer-use tools, approving an app for a conversation is the permission;
/// actions in it are not approved one by one.
public final class ComputerUseV2Engine: @unchecked Sendable {
    private let desktopAdmission = ComputerUseDesktopAdmissionOwner()
    public typealias LogHandler = @Sendable (String, String) -> Void
    public typealias EventHandler = @Sendable (UUID, UUID, String, String) -> Void

    public let driver: any ComputerUseDriver
    public let targetStore: ComputerUseTargetStore
    public let elementRegistry: ComputerUseElementRegistry
    public let activationProvider: any ComputerUseActivationProviding
    public let appAuthorizer: any ComputerUseAppAuthorizing
    public let onLog: LogHandler?
    public let onEvent: EventHandler?
    /// The role of the element with keyboard focus in an app (by pid). Keystrokes sent without an
    /// element go there, so a focused password field is caught before typing.
    public let focusedRole: @Sendable (Int) -> String?

    public init(
        driver: any ComputerUseDriver,
        targetStore: ComputerUseTargetStore = ComputerUseTargetStore(),
        elementRegistry: ComputerUseElementRegistry = ComputerUseElementRegistry(),
        activationProvider: any ComputerUseActivationProviding,
        appAuthorizer: any ComputerUseAppAuthorizing,
        onLog: LogHandler? = nil,
        onEvent: EventHandler? = nil,
        focusedRole: @escaping @Sendable (Int) -> String? = ComputerUseV2Engine.accessibilityFocusedRole
    ) {
        self.driver = driver
        self.targetStore = targetStore
        self.elementRegistry = elementRegistry
        self.activationProvider = activationProvider
        self.appAuthorizer = appAuthorizer
        self.onLog = onLog
        self.onEvent = onEvent
        self.focusedRole = focusedRole
    }

    /// Reads the focused element through Accessibility, which Computer Use already requires.
    public static func accessibilityFocusedRole(pid: Int) -> String? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        func attribute(_ name: String) -> String? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? String : nil
        }
        if attribute(kAXSubroleAttribute) == "AXSecureTextField" { return "AXSecureTextField" }
        return attribute(kAXRoleAttribute)
    }

    @discardableResult
    public func finishRun(conversationID: UUID, runID: UUID) async -> Bool {
        await elementRegistry.invalidateSession(conversationID: conversationID.uuidString, runID: runID.uuidString)
        do {
            try await driver.finishRunSession(runID: runID)
            recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.driver.sessionEnded", summary: "Named run session cleanup completed")
            return true
        } catch {
            recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.driver.sessionCleanupFailed", summary: error.localizedDescription)
            return false
        }
    }

    /// Credential and security apps and password fields: the model asks the user instead.
    static func offLimits(bundleID: String, role: String?) -> String? {
        guard ComputerUseRiskPolicy.credentialSecurityBundleIDs.contains(bundleID.lowercased()) || role == "AXSecureTextField" else { return nil }
        return "Limare does not operate password managers, Keychain, System Settings or password fields. Ask the user to do this step."
    }

    private func logInfo(_ message: String) {
        onLog?("ComputerUseV2", message)
    }

    private func logError(_ message: String) {
        onLog?("ComputerUseV2", message)
    }

    private func recordEvent(
        conversationID: UUID,
        runID: UUID,
        kind: String,
        summary: String
    ) {
        onEvent?(conversationID, runID, kind, summary)
    }

    /// Primary model-facing action dispatch entry for Computer Use v0.2.
    public func dispatchAction(
        input: ComputerUseV2ActionInput,
        conversationID: UUID,
        runID: UUID,
        isAuthoritative: @escaping @Sendable () async -> Bool
    ) async -> ComputerUseV2ActionResult {
        guard let actionID = desktopAdmission.beginAction(conversationID: conversationID, runID: runID) else {
            return .init(status: .failed, actionKind: input.action, detail: "Another computer_use action is still running; try again in a moment.")
        }
        defer { desktopAdmission.endAction(actionID) }
        let context = ComputerUseDriverExecutionContext(runID: runID, conversationID: conversationID, isAuthoritative: isAuthoritative)
        return await ComputerUseDriverExecutionContext.$current.withValue(context) {
            let result = await dispatchScoped(input: input, conversationID: conversationID, runID: runID, isAuthoritative: isAuthoritative)
            for diagnostic in await driver.drainSessionDiagnostics(runID: runID) {
                recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.driver.lifecycle", summary: diagnostic)
            }
            return result
        }
    }

    private func dispatchScoped(input: ComputerUseV2ActionInput, conversationID: UUID, runID: UUID,
        isAuthoritative: @escaping @Sendable () async -> Bool) async -> ComputerUseV2ActionResult {
        // Gate 0: Mutation authority preflight
        guard await isAuthoritative() else {
            return ComputerUseV2ActionResult(
                status: .cancelled,
                actionKind: input.action,
                targetAppBundleID: nil,
                detail: "Run lacks mutation authority at dispatch entry (CU-I36)."
            )
        }

        // Gate 1: Computer Use Activation
        let isActivated = await activationProvider.isActivated(conversationID: conversationID)
        guard isActivated else {
            logError("Gate 1 rejected: Computer Use is not active for conversation '\(conversationID)'.")
            return ComputerUseV2ActionResult(
                status: .denied,
                actionKind: input.action,
                targetAppBundleID: nil,
                detail: await activationProvider.unavailableReason(conversationID: conversationID)
                    ?? "Computer Use is not activated for this conversation."
            )
        }

        let currentGen = await activationProvider.currentGeneration(conversationID: conversationID, runID: runID)

        let convIDStr = conversationID.uuidString
        let runIDStr = runID.uuidString

        // Ensure mechanical driver backend is running and ready
        if !(await driver.readiness().isReady) {
            do {
                try await driver.start()
            } catch {
                logError("Failed to start mechanical driver backend: \(error.localizedDescription)")
                return ComputerUseV2ActionResult(
                    status: .failed,
                    actionKind: input.action,
                    targetAppBundleID: nil,
                    detail: "Failed to initialize driver backend: \(error.localizedDescription)"
                )
            }
        }

        do {
            let session = try await driver.prepareRunSession(runID: runID)
            recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.driver.sessionEnsured",
                summary: "label=\(session.publicSessionLabel) transport=\(session.transportGeneration) sessionGeneration=\(session.generation) ensure=\(session.ensure.rawValue)")
            if session.ensure == .revived || session.ensure == .created {
                await elementRegistry.invalidateSession(conversationID: convIDStr, runID: runIDStr)
            }
        } catch {
            return ComputerUseV2ActionResult(status: .failed, actionKind: input.action, targetAppBundleID: nil, detail: "Driver session unavailable: \(error.localizedDescription)")
        }

        // Handle target-free read-only utility actions
        switch input.action {
        case .listApps:
            do {
                let apps = try await driver.listApplications()
                let json = try JSONSerialization.data(withJSONObject: [
                    "status": "success",
                    "apps": apps.map { ["bundle_id": $0.bundleID, "name": $0.name, "pid": $0.pid as Any, "running": $0.isRunning, "discovery_consistency": $0.discoveryConsistency as Any, "driver_reported_pid": $0.driverReportedPID as Any, "driver_reported_running": $0.driverReportedRunning as Any] }
                ])
                let text = String(data: json, encoding: .utf8) ?? "{}"
                return ComputerUseV2ActionResult(status: .dispatched, actionKind: .listApps, targetAppBundleID: nil, detail: text)
            } catch {
                return ComputerUseV2ActionResult(status: .failed, actionKind: .listApps, targetAppBundleID: nil, detail: error.localizedDescription)
            }

        case .listWindows:
            do {
                let resolvedPID: Int
                if let pid = input.pid, pid > 0 { resolvedPID = pid }
                else if let bundle = input.targetApp {
                    let app = try await targetStore.resolveRunningApplication(driver: driver, bundleID: bundle)
                    resolvedPID = app.pid!
                } else {
                    throw ComputerUseDriverError.driverToolFailed(tool: "list_windows", reason: "invalidArguments: supply a positive pid OR target_app")
                }
                let windows = try await driver.listWindows(pid: resolvedPID)
                let json = try JSONSerialization.data(withJSONObject: [
                    "status": "success",
                    "windows": windows.map { ["window_id": $0.windowID, "pid": $0.pid, "title": $0.title as Any, "is_on_screen": $0.isOnScreen as Any, "layer": $0.layer as Any] }
                ])
                let text = String(data: json, encoding: .utf8) ?? "{}"
                return ComputerUseV2ActionResult(status: .dispatched, actionKind: .listWindows, targetAppBundleID: nil, detail: text)
            } catch {
                return ComputerUseV2ActionResult(status: .failed, actionKind: .listWindows, targetAppBundleID: nil, detail: error.localizedDescription)
            }

        case .wait:
            let duration = min(max(input.durationMs ?? 1000, 10), 10_000)
            try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000)
            return ComputerUseV2ActionResult(status: .dispatched, actionKind: .wait, targetAppBundleID: nil, detail: "Waited \(duration)ms.")

        default:
            break
        }

        // Action: launch_app
        if input.action == .launchApp {
            guard let requestedIdentity = input.targetApp, !requestedIdentity.isEmpty else {
                return .init(status: .failed, actionKind: .launchApp, detail: "invalidArguments: launch_app requires target_app")
            }

            let bundleID: String
            do { bundleID = try await targetStore.resolveApplicationBundleID(driver: driver, identity: requestedIdentity) }
            catch { return .init(status: .failed, actionKind: .launchApp, detail: error.localizedDescription) }

            // Off-limits apps are refused before anyone is asked to approve them.
            if let blocked = Self.offLimits(bundleID: bundleID, role: nil) {
                return .init(status: .blocked, actionKind: .launchApp, targetAppBundleID: bundleID, detail: blocked)
            }

            // Gate 2: Layer 2 App Authorization
            let appState = await appAuthorizer.getAuthorizationStatus(conversationID: conversationID, bundleID: bundleID)
            switch appState {
            case .allowedForConversation:
                break
            case .blockedForConversation:
                return ComputerUseV2ActionResult(
                    status: .denied,
                    actionKind: .launchApp,
                    targetAppBundleID: bundleID,
                    detail: "Application '\(bundleID)' is blocked for this conversation."
                )
            case .unknown:
                recordEvent(conversationID: conversationID, runID: runID,
                            kind: "computerUse.appApproval.requested",
                            summary: "Requested Layer-2 App authorization for '\(bundleID)'")
                let resolution = await appAuthorizer.requestAppApproval(
                    conversationID: conversationID,
                    bundleID: bundleID,
                    appLocalizedName: bundleID
                )
                guard await isAuthoritative() else {
                    return ComputerUseV2ActionResult(status: .cancelled, actionKind: .launchApp, targetAppBundleID: bundleID, detail: "Run lost mutation authority during Layer-2 approval.")
                }
                if resolution != .allowedForConversation {
                    let detail = await appAuthorizer.unattendedRefusal(conversationID: conversationID, appName: bundleID)
                        ?? "Layer-2 authorization denied for '\(bundleID)'."
                    return ComputerUseV2ActionResult(status: .denied, actionKind: .launchApp, targetAppBundleID: bundleID, detail: detail)
                }
            }

            do {
                let launchRes = try await driver.launchApplication(bundleID: bundleID, background: true)
                if ComputerUseTargetStore.usableWindows(launchRes.windows, pid: launchRes.pid).isEmpty {
                    return .init(status: .dispatched, actionKind: .launchApp, targetAppBundleID: bundleID,
                                 detail: "{\"status\":\"launchedAwaitingWindow\",\"pid\":\(launchRes.pid),\"guidance\":\"Application launched. Use list_windows or capture(target_app) for non-launching discovery.\"}")
                }
                let target = try await targetStore.bindUniqueWindow(windows: launchRes.windows.filter { input.windowID == nil || $0.windowID == input.windowID }, bundleID: bundleID,
                    pid: launchRes.pid, conversationID: convIDStr, runID: runIDStr)

                // Capture initial observation of the launched target window
                let obs = try await driver.observeWindow(target: target)
                let modelElements = await elementRegistry.registerObservation(
                    obs,
                    conversationID: convIDStr,
                    runID: runIDStr,
                    generation: currentGen
                )

                let detailObj: [String: Any] = [
                    "status": "launched",
                    "bundle_id": bundleID,
                    "pid": target.pid,
                    "window_id": target.windowID,
                    "title": target.title as Any,
                    "tree_markdown": ComputerUseElementRegistry.modelTreeMarkdown(obs, refs: modelElements) as Any,
                    "elements": modelElements.map { ["ref": $0.refID, "role": $0.role, "label": $0.label as Any] }
                ]
                let json = (try? JSONSerialization.data(withJSONObject: detailObj)) ?? Data()
                let detailText = String(data: json, encoding: .utf8) ?? "Launched \(bundleID)"

                return ComputerUseV2ActionResult(
                    status: .dispatched,
                    actionKind: .launchApp,
                    targetAppBundleID: bundleID,
                    detail: detailText
                )
            } catch {
                return ComputerUseV2ActionResult(status: .failed, actionKind: .launchApp, targetAppBundleID: bundleID, detail: error.localizedDescription)
            }
        }

        // Non-launching target resolution, with exact old-window invalidation.
        let target: WindowTarget
        do {
            let active = await targetStore.getTarget(conversationID: convIDStr, runID: runIDStr)
            if let active, (input.targetApp == nil || active.bundleID.caseInsensitiveCompare(input.targetApp!) == .orderedSame), (input.windowID == nil || input.windowID == active.windowID) {
                do {
                    _ = try await targetStore.verifyTargetAlive(driver: driver, target: active)
                    target = active
                } catch ComputerUseDriverError.targetDestroyed {
                    await targetStore.clearTarget(conversationID: convIDStr, runID: runIDStr)
                    await elementRegistry.invalidateSession(conversationID: convIDStr, runID: runIDStr)
                    recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.targetDestroyed", summary: "Cleared old window \(active.windowID) and refs")
                    guard let requested = input.targetApp else {
                        return .init(status: .targetChanged, actionKind: input.action, targetAppBundleID: active.bundleID,
                                     detail: "targetDestroyed / needsRediscovery: capture with target_app; old refs invalid.")
                    }
                    target = try await targetStore.resolveExistingTarget(driver: driver, conversationID: convIDStr,
                        runID: runIDStr, bundleID: requested, requiredPID: active.pid, windowID: input.windowID)
                    recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.targetRebound", summary: "Non-launching same-PID bind: \(target.pid)/\(target.windowID)")
                }
            } else if let requested = input.targetApp {
                await elementRegistry.invalidateSession(conversationID: convIDStr, runID: runIDStr)
                target = try await targetStore.resolveExistingTarget(driver: driver, conversationID: convIDStr,
                    runID: runIDStr, bundleID: requested, windowID: input.windowID)
            } else {
                return .init(status: .failed, actionKind: input.action, detail: "targetNotFound: supply target_app. Only explicit launch_app can launch.")
            }
        } catch {
            return .init(status: .failed, actionKind: input.action, targetAppBundleID: input.targetApp,
                         detail: "Failed to resolve target window: \(error.localizedDescription)")
        }

        // Off-limits apps are refused before anyone is asked to approve them.
        if let blocked = Self.offLimits(bundleID: target.bundleID, role: nil) {
            return .init(status: .blocked, actionKind: input.action, targetAppBundleID: target.bundleID, detail: blocked)
        }

        // Gate 2: App Authorization for target
        let appAuth = await appAuthorizer.getAuthorizationStatus(conversationID: conversationID, bundleID: target.bundleID)
        if appAuth == .blockedForConversation {
            return ComputerUseV2ActionResult(status: .denied, actionKind: input.action, targetAppBundleID: target.bundleID, detail: "App '\(target.bundleID)' is blocked.")
        } else if appAuth == .unknown {
            recordEvent(conversationID: conversationID, runID: runID, kind: "computerUse.appApproval.requested", summary: "Requested Layer-2 App authorization for '\(target.bundleID)'")
            let resolution = await appAuthorizer.requestAppApproval(conversationID: conversationID, bundleID: target.bundleID, appLocalizedName: target.bundleID)
            guard await isAuthoritative() else {
                return ComputerUseV2ActionResult(status: .cancelled, actionKind: input.action, targetAppBundleID: target.bundleID, detail: "Run lost mutation authority during Layer-2 approval.")
            }
            if resolution != .allowedForConversation {
                let detail = await appAuthorizer.unattendedRefusal(conversationID: conversationID, appName: target.bundleID)
                    ?? "Layer-2 authorization denied for '\(target.bundleID)'."
                return ComputerUseV2ActionResult(status: .denied, actionKind: input.action, targetAppBundleID: target.bundleID, detail: detail)
            }
        }

        // Action: capture / observe
        if input.action == .capture || input.action == .observe {
            do {
                let obs = try await driver.observeWindow(target: target)
                let modelElements = await elementRegistry.registerObservation(
                    obs,
                    conversationID: convIDStr,
                    runID: runIDStr,
                    generation: currentGen
                )
                let detailObj: [String: Any] = [
                    "status": "observed",
                    "target": ["bundle_id": target.bundleID, "pid": target.pid, "window_id": target.windowID],
                    "tree_markdown": ComputerUseElementRegistry.modelTreeMarkdown(obs, refs: modelElements) as Any,
                    "elements": modelElements.map { ["ref": $0.refID, "role": $0.role, "label": $0.label as Any] }
                ]
                let json = (try? JSONSerialization.data(withJSONObject: detailObj)) ?? Data()
                let detailText = String(data: json, encoding: .utf8) ?? "Observed window"
                return ComputerUseV2ActionResult(
                    status: .dispatched,
                    actionKind: input.action,
                    targetAppBundleID: target.bundleID,
                    detail: detailText
                )
            } catch {
                return ComputerUseV2ActionResult(status: .failed, actionKind: input.action, targetAppBundleID: target.bundleID, detail: error.localizedDescription)
            }
        }

        // Element-directed actions: resolve element ref
        var elementRef: ComputerUseElementRef? = nil
        if let elemID = input.element {
            do {
                elementRef = try await elementRegistry.resolve(refID: elemID, conversationID: convIDStr, runID: runIDStr)
            } catch {
                return ComputerUseV2ActionResult(
                    status: .staleObservation,
                    actionKind: input.action,
                    targetAppBundleID: target.bundleID,
                    detail: "Element reference '\(elemID)' is not in the latest observation of this window. Use a reference from the most recent result, or capture again."
                )
            }
        }

        // The app was approved for this conversation above; only password managers, Keychain,
        // System Settings and password fields stay off limits. Keystrokes without an element go to
        // the focused element, so that is the one checked for them.
        let keyboardInput: Set<ComputerUseV2ActionKind> = [.type, .typeText, .key, .hotkey]
        let checkedRole = elementRef?.role ?? (keyboardInput.contains(input.action) ? focusedRole(target.pid) : nil)
        if let blocked = Self.offLimits(bundleID: target.bundleID, role: checkedRole) {
            return .init(status: .blocked, actionKind: input.action, targetAppBundleID: target.bundleID, detail: blocked)
        }

        guard await isAuthoritative() else {
            return ComputerUseV2ActionResult(status: .cancelled, actionKind: input.action, targetAppBundleID: target.bundleID, detail: "Mutation authority lost prior to dispatch.")
        }

        do {
            let session = try await driver.prepareRunSession(runID: runID)
            if session.ensure != .active {
                await elementRegistry.invalidateSession(conversationID: convIDStr, runID: runIDStr)
                return ComputerUseV2ActionResult(status: .failed, actionKind: input.action, targetAppBundleID: target.bundleID,
                    detail: "staleDriverSession: fresh observation required before mutation")
            }
        } catch {
            return ComputerUseV2ActionResult(status: .failed, actionKind: input.action, targetAppBundleID: target.bundleID,
                detail: error.localizedDescription)
        }
        guard await isAuthoritative() else {
            return ComputerUseV2ActionResult(status: .cancelled, actionKind: input.action, targetAppBundleID: target.bundleID,
                detail: "Run authority revoked during session ensure")
        }

        // Governed Foreground Escalation: Explicit, tracked window activation (zero stealth focus shifts)
        if input.deliveryMode == "foreground" {
            logInfo("Governed foreground activation for target window \(target.windowID) (\(target.bundleID))")
            recordEvent(
                conversationID: conversationID,
                runID: runID,
                kind: "computerUse.foregroundEscalated",
                summary: "Explicitly activated target window \(target.windowID) (\(target.bundleID)) for foreground interaction."
            )
            _ = try? await driver.activateWindow(target: target)
        }

        // Mechanical Driver Dispatch
        do {
            let receipt: ComputerUseDriverActionResult
            switch input.action {
            case .click:
                guard let ref = elementRef else {
                    return ComputerUseV2ActionResult(status: .failed, actionKind: .click, targetAppBundleID: target.bundleID, detail: "click requires 'element' parameter.")
                }
                receipt = try await driver.click(element: ref, deliveryMode: input.deliveryMode)

            case .doubleClick:
                guard let ref = elementRef else {
                    return ComputerUseV2ActionResult(status: .failed, actionKind: .doubleClick, targetAppBundleID: target.bundleID, detail: "double_click requires 'element' parameter.")
                }
                receipt = try await driver.doubleClick(element: ref, deliveryMode: input.deliveryMode)

            case .rightClick:
                guard let ref = elementRef else {
                    return ComputerUseV2ActionResult(status: .failed, actionKind: .rightClick, targetAppBundleID: target.bundleID, detail: "right_click requires 'element' parameter.")
                }
                receipt = try await driver.rightClick(element: ref, deliveryMode: input.deliveryMode)

            case .type, .typeText:
                receipt = try await driver.typeText(text: input.text ?? "", element: elementRef, target: target, deliveryMode: input.deliveryMode)

            case .key:
                receipt = try await driver.pressKey(key: input.key ?? "", target: target, modifiers: input.keys, deliveryMode: input.deliveryMode)

            case .hotkey:
                receipt = try await driver.hotkey(keys: input.keys ?? [], target: target, deliveryMode: input.deliveryMode)

            case .setValue:
                guard let ref = elementRef else {
                    return ComputerUseV2ActionResult(status: .failed, actionKind: .setValue, targetAppBundleID: target.bundleID, detail: "set_value requires 'element' parameter.")
                }
                receipt = try await driver.setValue(value: input.value ?? "", element: ref)

            case .scroll:
                receipt = try await driver.scroll(direction: input.direction ?? "down", amount: input.amount, element: elementRef, target: target, deliveryMode: input.deliveryMode)

            case .drag:
                let from: ComputerUseElementRef? = if let elementRef { elementRef } else if let fromID = input.fromElement {
                    try? await elementRegistry.resolve(refID: fromID, conversationID: convIDStr, runID: runIDStr)
                } else { nil }
                guard let ref = from,
                      let toID = input.toElement,
                      let toRef = try? await elementRegistry.resolve(refID: toID, conversationID: convIDStr, runID: runIDStr) else {
                    return ComputerUseV2ActionResult(status: .failed, actionKind: .drag, targetAppBundleID: target.bundleID, detail: "drag requires valid 'element' and 'to_element'.")
                }
                receipt = try await driver.drag(from: ref, to: toRef, deliveryMode: input.deliveryMode)

            default:
                return ComputerUseV2ActionResult(status: .unsupported, actionKind: input.action, targetAppBundleID: target.bundleID, detail: "Unsupported action \(input.action.rawValue)")
            }

            // Like Playwright MCP, every action returns the window as it is now, with fresh
            // element references the next action can use directly.
            // The action may have changed the window, so earlier references no longer hold.
            var observation: [String: Any]? = nil
            await elementRegistry.invalidateSession(conversationID: convIDStr, runID: runIDStr)
            if let postObs = try? await driver.observeWindow(target: target) {
                let refs = await elementRegistry.registerObservation(postObs, conversationID: convIDStr, runID: runIDStr, generation: currentGen)
                observation = [
                    "tree_markdown": ComputerUseElementRegistry.modelTreeMarkdown(postObs, refs: refs) as Any,
                    "elements": refs.map { ["ref": $0.refID, "role": $0.role, "label": $0.label as Any] }
                ]
            }

            var responsePayload: [String: Any] = [
                "status": receipt.isSuccess ? "dispatched" : "failed",
                "action": input.action.rawValue,
                "route": receipt.route as Any,
                "mode": receipt.mode as Any,
                "effect": receipt.effect as Any,
                "detail": receipt.detail as Any,
                "observation": observation as Any
            ]
            if observation == nil {
                responsePayload["observation_note"] = "The window could not be read after this action; capture it before the next element action."
            }

            if !receipt.isSuccess && input.deliveryMode != "foreground" {
                responsePayload["hint"] = "If the window needs focus for this, retry with delivery_mode 'foreground' (it brings the window to the front)."
            }

            let jsonData = (try? JSONSerialization.data(withJSONObject: responsePayload)) ?? Data()
            let contentString = String(data: jsonData, encoding: .utf8) ?? "{}"

            return ComputerUseV2ActionResult(
                status: receipt.isSuccess ? .dispatched : .failed,
                actionKind: input.action,
                targetAppBundleID: target.bundleID,
                detail: contentString,
                receipt: receipt
            )
        } catch {
            var errorPayload: [String: Any] = [
                "status": "failed",
                "action": input.action.rawValue,
                "error": error.localizedDescription
            ]
            if input.deliveryMode != "foreground" {
                errorPayload["hint"] = "If the window needs focus for this, retry with delivery_mode 'foreground' (it brings the window to the front)."
            }
            let errData = (try? JSONSerialization.data(withJSONObject: errorPayload)) ?? Data()
            let errString = String(data: errData, encoding: .utf8) ?? error.localizedDescription
            return ComputerUseV2ActionResult(status: .failed, actionKind: input.action, targetAppBundleID: target.bundleID, detail: errString)
        }
    }
}

/// One desktop action at a time: the desktop is a single shared resource.
private final class ComputerUseDesktopAdmissionOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [UUID: (conversationID: UUID, runID: UUID)] = [:]

    func beginAction(conversationID: UUID, runID: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard actions.isEmpty else { return nil }
        let id = UUID()
        actions[id] = (conversationID, runID)
        return id
    }

    func endAction(_ id: UUID) { lock.lock(); actions.removeValue(forKey: id); lock.unlock() }
}
