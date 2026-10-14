import Foundation

/// Execution route governing Computer Use runtime engine selection.
public enum ComputerUseExecutionRoute: String, Sendable, Codable {
    case v2Dogfood = "v2_dogfood"
    case v2Production = "v2_production"
}

/// Validation errors for v0.2 action inputs.
public enum ComputerUseV2ActionValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedAction(String)
    case missingRequiredParameter(String)
    case invalidParameterValue(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction(let act):
            return "Unsupported Computer Use action kind '\(act)'."
        case .missingRequiredParameter(let param):
            return "Missing required parameter '\(param)'."
        case .invalidParameterValue(let msg):
            return "Invalid parameter value: \(msg)"
        }
    }
}

/// Limare-owned model-facing action vocabulary for Computer Use v0.2.
/// Follows mature Hermes-style wrapper principle: model vocabulary ≠ raw driver vocabulary.
public enum ComputerUseV2ActionKind: String, Codable, Sendable, CaseIterable {
    case capture = "capture"
    case observe = "observe"
    case launchApp = "launch_app"
    case listApps = "list_apps"
    case listWindows = "list_windows"
    case click = "click"
    case doubleClick = "double_click"
    case rightClick = "right_click"
    case type = "type"
    case typeText = "type_text"
    case key = "key"
    case hotkey = "hotkey"
    case setValue = "set_value"
    case scroll = "scroll"
    case drag = "drag"
    case wait = "wait"

    public var isReadOnly: Bool {
        switch self {
        case .capture, .observe, .listApps, .listWindows:
            return true
        default:
            return false
        }
    }
}

/// Strongly-typed, parsed and validated model-facing action proposal for Computer Use v0.2.
public struct ComputerUseV2ActionInput: Sendable, Equatable {
    public let action: ComputerUseV2ActionKind
    public let targetApp: String?
    public let pid: Int?
    public let windowID: Int?
    public let element: String?
    public let text: String?
    public let key: String?
    public let keys: [String]?
    public let value: String?
    public let direction: String?
    public let amount: Int?
    public let fromElement: String?
    public let toElement: String?
    public let durationMs: Int?
    public let deliveryMode: String?

    public init(
        action: ComputerUseV2ActionKind,
        targetApp: String? = nil,
        pid: Int? = nil,
        windowID: Int? = nil,
        element: String? = nil,
        text: String? = nil,
        key: String? = nil,
        keys: [String]? = nil,
        value: String? = nil,
        direction: String? = nil,
        amount: Int? = nil,
        fromElement: String? = nil,
        toElement: String? = nil,
        durationMs: Int? = nil,
        deliveryMode: String? = nil
    ) {
        self.action = action
        self.targetApp = targetApp
        self.pid = pid
        self.windowID = windowID
        self.element = element
        self.text = text
        self.key = key
        self.keys = keys
        self.value = value
        self.direction = direction
        self.amount = amount
        self.fromElement = fromElement
        self.toElement = toElement
        self.durationMs = durationMs
        self.deliveryMode = deliveryMode
    }

    /// Parses and strictly validates input arguments from a JSON string.
    public static func parse(from jsonString: String) throws -> ComputerUseV2ActionInput {
        guard let data = jsonString.data(using: .utf8) else {
            throw ComputerUseV2ActionValidationError.invalidParameterValue("Input is not valid UTF-8.")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            throw ComputerUseV2ActionValidationError.invalidParameterValue("Input is not a valid JSON dictionary.")
        }
        return try parse(from: dict)
    }

    /// Parses and strictly validates input arguments from a dictionary.
    public static func parse(from dict: [String: Any]) throws -> ComputerUseV2ActionInput {
        guard let rawAction = dict["action"] as? String else {
            throw ComputerUseV2ActionValidationError.missingRequiredParameter("action")
        }
        guard let kind = ComputerUseV2ActionKind(rawValue: rawAction.lowercased()) else {
            throw ComputerUseV2ActionValidationError.unsupportedAction(rawAction)
        }

        let targetApp = dict["target_app"] as? String ?? dict["bundle_id"] as? String
        let pid = dict["pid"] as? Int ?? (dict["pid"] as? NSNumber)?.intValue
        let windowID = dict["window_id"] as? Int ?? (dict["window_id"] as? NSNumber)?.intValue
        let element = dict["element"] as? String ?? dict["element_ref"] as? String
        let text = dict["text"] as? String
        let key = dict["key"] as? String
        let keys = dict["keys"] as? [String]
        let value = dict["value"] as? String
        let direction = dict["direction"] as? String
        let amount = dict["amount"] as? Int ?? (dict["amount"] as? NSNumber)?.intValue
        let fromElement = dict["from_element"] as? String
        let toElement = dict["to_element"] as? String
        let durationMs = dict["duration_ms"] as? Int ?? (dict["duration_ms"] as? NSNumber)?.intValue
        let deliveryMode = dict["delivery_mode"] as? String ?? dict["mode"] as? String

        return ComputerUseV2ActionInput(
            action: kind,
            targetApp: targetApp,
            pid: pid,
            windowID: windowID,
            element: element,
            text: text,
            key: key,
            keys: keys,
            value: value,
            direction: direction,
            amount: amount,
            fromElement: fromElement,
            toElement: toElement,
            durationMs: durationMs,
            deliveryMode: deliveryMode
        )
    }
}

/// Status of an executed v0.2 action.
public enum ComputerUseV2ActionResultStatus: String, Codable, Sendable {
    case dispatched
    case denied
    case blocked
    case cancelled
    case timedOut
    case failed
    case unsupported
    case targetChanged
    case staleObservation
}

/// Normalized result of a Computer Use v0.2 action dispatch.
public struct ComputerUseV2ActionResult: Sendable {
    public let status: ComputerUseV2ActionResultStatus
    public let actionKind: ComputerUseV2ActionKind
    public let targetAppBundleID: String?
    public let detail: String
    public let admissionState: ToolApprovalState
    public let receipt: ComputerUseDriverActionResult?
    public let osEventStarted: Bool
    public let transientInputReleased: Bool
    public let releaseFailure: String?

    public init(
        status: ComputerUseV2ActionResultStatus,
        actionKind: ComputerUseV2ActionKind,
        targetAppBundleID: String? = nil,
        admissionState: ToolApprovalState? = nil,
        detail: String,
        receipt: ComputerUseDriverActionResult? = nil,
        osEventStarted: Bool = false,
        transientInputReleased: Bool = true,
        releaseFailure: String? = nil
    ) {
        self.status = status
        self.actionKind = actionKind
        self.targetAppBundleID = targetAppBundleID
        self.admissionState = admissionState ?? ((status == .denied || status == .blocked) ? .denied : .notRequired)
        self.detail = detail
        self.receipt = receipt
        self.osEventStarted = osEventStarted
        self.transientInputReleased = transientInputReleased
        self.releaseFailure = releaseFailure
    }

    public var isSuccess: Bool {
        status == .dispatched
    }

    public var jsonContent: String {
        var object = (detail.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? ["detail": detail]
        object["mechanicalStatus"] = status.rawValue
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? detail
    }
}

/// Property schema descriptor for Limare-owned computer_use v0.2 tool definition.
public struct ComputerUseV2ToolProperty: Sendable, Equatable {
    public let type: String
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

/// Canonical tool definition exposing exactly ONE Limare-owned computer_use tool to the model.
public struct ComputerUseV2ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let properties: [String: ComputerUseV2ToolProperty]
    public let required: [String]

    public static let shared = ComputerUseV2ToolDefinition(
        name: "computer_use",
        description: "Operate macOS apps through their accessibility tree, in the background by default. launch_app opens an app and returns its window; capture observes a window. Every result includes the window's current elements with references (e1, e2, ...); use the references from the most recent result in the next action. Each app asks the user for permission once per conversation. Password managers, Keychain, System Settings and password fields are off limits: ask the user to do those steps. list_windows needs a pid or target_app. If an app is launched but has no window yet (launchedAwaitingWindow), use capture(target_app) instead of launching again.",
        properties: [
            "action": .init(type: "string", description: "The action kind: launch_app, list_apps, list_windows, capture, click, double_click, right_click, type, key, set_value, scroll, drag, wait."),
            "target_app": .init(type: "string", description: "Target application bundle identifier (e.g. 'com.apple.calculator') or application name."),
            "pid": .init(type: "number", description: "Process ID for list_windows or targeting."),
            "window_id": .init(type: "number", description: "Window ID for targeting."),
            "element": .init(type: "string", description: "Opaque element reference identifier (e.g. 'e1', 'e2') from current window observation."),
            "text": .init(type: "string", description: "Text content to type into the target element or window."),
            "key": .init(type: "string", description: "Key name to press (e.g. 'return', 'tab', 'escape', 'space')."),
            "keys": .init(type: "array", description: "Key combinations or modifier keys to press (e.g. ['cmd', 'c'])."),
            "value": .init(type: "string", description: "Value to set directly on the target element."),
            "direction": .init(type: "string", description: "Scroll direction: up, down, left, right."),
            "amount": .init(type: "number", description: "Scroll notches or amount (default 3)."),
            "from_element": .init(type: "string", description: "Source element reference for drag (or use element)."),
            "to_element": .init(type: "string", description: "Destination element reference for drag."),
            "duration_ms": .init(type: "number", description: "Duration in milliseconds for wait (default 1000)."),
            "delivery_mode": .init(type: "string", description: "'background' (default) acts without stealing focus; 'foreground' brings the window to the front first."),
        ],
        required: ["action"]
    )
}

