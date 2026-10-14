import Foundation

// MARK: - Browser Action Enum

public enum BrowserAction: String, CaseIterable, Sendable, Codable {
    case navigate
    case getPageInfo = "get_page_info"
    case getText = "get_text"
    case getReadable = "get_readable"
    case findElements = "find_elements"
    case click
    case type
    case scroll
    case screenshot
    case waitForDomStable = "wait_for_dom_stable"
}

// MARK: - Browser Scroll Direction

public enum BrowserScrollDirection: String, Sendable, Codable {
    case up
    case down
}

// MARK: - Browser Control Owner

public enum BrowserControlOwner: String, Sendable, Codable {
    case agent
    case user

    public var displayName: String {
        switch self {
        case .agent: return "Agent Control"
        case .user: return "You Control the Browser"
        }
    }
}

// MARK: - Browser Runtime State

public struct BrowserRuntimeState: Sendable, Equatable {
    public let currentURL: String
    public let pageTitle: String
    public let isLoading: Bool

    public init(
        currentURL: String = "",
        pageTitle: String = "",
        isLoading: Bool = false
    ) {
        self.currentURL = currentURL
        self.pageTitle = pageTitle
        self.isLoading = isLoading
    }
}

// MARK: - Browser Action Input

public struct BrowserActionInput: Sendable, Codable {
    public let action: BrowserAction
    public let url: String?
    public let selector: String?
    public let text: String?
    public let direction: BrowserScrollDirection?
    public let amount: Int?
    public let timeoutSeconds: Int?

    public init(
        action: BrowserAction,
        url: String? = nil,
        selector: String? = nil,
        text: String? = nil,
        direction: BrowserScrollDirection? = nil,
        amount: Int? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.action = action
        self.url = url
        self.selector = selector
        self.text = text
        self.direction = direction
        self.amount = amount
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case action
        case url
        case selector
        case text
        case direction
        case amount
        case timeoutSeconds = "timeout_seconds"
    }

    public static func parse(from jsonString: String) throws -> BrowserActionInput {
        guard let data = jsonString.data(using: .utf8) else {
            throw BrowserRuntimeError.invalidArguments("Tool input is not valid UTF-8.")
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserRuntimeError.invalidArguments("Tool input is not valid JSON.")
        }
        guard let actionStr = dict["action"] as? String else {
            throw BrowserRuntimeError.invalidArguments("Missing required parameter: 'action'.")
        }
        guard let action = BrowserAction(rawValue: actionStr) else {
            throw BrowserRuntimeError.invalidArguments("Unsupported browser action: '\(actionStr)'.")
        }

        let url = dict["url"] as? String
        let selector = dict["selector"] as? String
        let text = dict["text"] as? String
        let directionStr = dict["direction"] as? String
        let direction = directionStr.flatMap(BrowserScrollDirection.init(rawValue:))
        let amount = dict["amount"] as? Int
        let timeout = (dict["timeout_seconds"] as? Int) ?? (dict["timeout"] as? Int)

        // Validate required arguments per action
        switch action {
        case .navigate:
            guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else {
                throw BrowserRuntimeError.invalidArguments("navigate requires a non-empty 'url'.")
            }
        case .click:
            guard let s = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                throw BrowserRuntimeError.invalidArguments("click requires a non-empty 'selector'.")
            }
        case .type:
            guard let s = selector?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                throw BrowserRuntimeError.invalidArguments("type requires a non-empty 'selector'.")
            }
            guard text != nil else {
                throw BrowserRuntimeError.invalidArguments("type requires 'text'.")
            }
        case .scroll:
            if let dir = directionStr, BrowserScrollDirection(rawValue: dir) == nil {
                throw BrowserRuntimeError.invalidArguments("scroll direction must be 'up' or 'down'.")
            }
            if let amt = amount, !(1...5000).contains(amt) {
                throw BrowserRuntimeError.invalidArguments("scroll amount must be between 1 and 5000 px.")
            }
        case .waitForDomStable:
            if let t = timeout, !(1...20).contains(t) {
                throw BrowserRuntimeError.invalidArguments("wait_for_dom_stable timeout_seconds must be between 1 and 20.")
            }
        default:
            break
        }

        var normalizedURL = dict["url"] as? String
        if let u = normalizedURL?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            if !u.contains("://") {
                normalizedURL = "https://\(u)"
            }
        }

        return BrowserActionInput(
            action: action,
            url: normalizedURL,
            selector: selector,
            text: text,
            direction: direction,
            amount: amount,
            timeoutSeconds: timeout
        )
    }
}

// MARK: - Browser Element Info

public struct BrowserElementInfo: Sendable, Codable, Equatable {
    public let tag: String
    public let type: String?
    public let name: String?
    public let text: String?
    public let ariaLabel: String?
    public let placeholder: String?
    public let href: String?
    public let disabled: Bool
    public let sensitive: Bool?
    public let selector: String

    public init(
        tag: String,
        type: String? = nil,
        name: String? = nil,
        text: String? = nil,
        ariaLabel: String? = nil,
        placeholder: String? = nil,
        href: String? = nil,
        disabled: Bool = false,
        sensitive: Bool? = nil,
        selector: String
    ) {
        self.tag = tag
        self.type = type
        self.name = name
        self.text = text
        self.ariaLabel = ariaLabel
        self.placeholder = placeholder
        self.href = href
        self.disabled = disabled
        self.sensitive = sensitive
        self.selector = selector
    }

    enum CodingKeys: String, CodingKey {
        case tag
        case type
        case name
        case text
        case ariaLabel = "aria_label"
        case placeholder
        case href
        case disabled
        case sensitive
        case selector
    }
}

// MARK: - Browser Page Info

public struct BrowserPageInfo: Sendable, Codable, Equatable {
    public let url: String
    public let title: String
    public let readyState: String
    public let viewportWidth: Int
    public let viewportHeight: Int
    public let scrollX: Int
    public let scrollY: Int
    public let documentWidth: Int
    public let documentHeight: Int

    public init(
        url: String,
        title: String,
        readyState: String,
        viewportWidth: Int,
        viewportHeight: Int,
        scrollX: Int = 0,
        scrollY: Int = 0,
        documentWidth: Int = 0,
        documentHeight: Int = 0
    ) {
        self.url = url
        self.title = title
        self.readyState = readyState
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.documentWidth = documentWidth
        self.documentHeight = documentHeight
    }
}

// MARK: - Browser Action Result

public struct BrowserActionResult: Sendable {
    public let jsonContent: String
    public let isError: Bool
    public let attachments: [ChatAttachment]
    public let resultParts: [ToolResultPart]?
    let mechanicalTerminalFact: ToolMechanicalTerminalFact?

    public init(
        jsonContent: String,
        isError: Bool = false,
        attachments: [ChatAttachment] = [],
        resultParts: [ToolResultPart]? = nil
    ) {
        self.jsonContent = jsonContent
        self.isError = isError
        self.attachments = attachments
        self.resultParts = resultParts
        self.mechanicalTerminalFact = nil
    }

    public static func pausedForUserControl() -> BrowserActionResult {
        notDispatched(status: "paused", reason: "user_has_control", disposition: .pausedForUserControl)
    }

    public static func capacityExceeded() -> BrowserActionResult {
        let message = "All browser tabs are in use by running conversations. Retry later, or continue without the browser and tell the user."
        return BrowserActionResult(
            jsonContent: jsonString([
                "status": "busy",
                "reason": "capacity",
                "retryable": true,
                "guidance": message,
                "message": message
            ]),
            isError: true,
            attachments: [],
            resultParts: nil,
            mechanicalTerminalFact: .browserAction(dispatched: false, disposition: .busy, reason: "capacity")
        )
    }

    func prependingNotice(_ prefix: String) -> BrowserActionResult {
        let newContent = jsonContent.isEmpty ? prefix : "\(prefix)\n\n\(jsonContent)"
        return BrowserActionResult(
            jsonContent: newContent,
            isError: isError,
            attachments: attachments,
            resultParts: resultParts,
            mechanicalTerminalFact: mechanicalTerminalFact
        )
    }

    static func notDispatched(status: String = "busy", reason: String, disposition: BrowserMechanicalDisposition = .busy) -> BrowserActionResult {
        let guidance = "Retry later, or continue without the browser and tell the user it was not used."
        return BrowserActionResult(jsonContent: jsonString(["status": status, "reason": reason,
            "retryable": true, "guidance": guidance, "message": guidance]), isError: true,
            attachments: [], resultParts: nil,
            mechanicalTerminalFact: .browserAction(dispatched: false, disposition: disposition, reason: reason))
    }

    private init(jsonContent: String, isError: Bool, attachments: [ChatAttachment], resultParts: [ToolResultPart]?, mechanicalTerminalFact: ToolMechanicalTerminalFact?) {
        self.jsonContent = jsonContent; self.isError = isError; self.attachments = attachments
        self.resultParts = resultParts; self.mechanicalTerminalFact = mechanicalTerminalFact
    }

    func sessionEvidence(ownerConversationID: UUID?, generation: Int, reset: String?) -> BrowserActionResult {
        var payload = ((try? JSONSerialization.jsonObject(with: Data(jsonContent.utf8))) as? [String: Any]) ?? [:]
        payload["session"] = ["ownerConversationID": ownerConversationID?.uuidString as Any? ?? NSNull(),
            "generation": generation, "reset": reset as Any? ?? NSNull()]
        return BrowserActionResult(jsonContent: Self.jsonString(payload), isError: isError, attachments: attachments,
            resultParts: resultParts, mechanicalTerminalFact: mechanicalTerminalFact)
    }

    public static func error(_ message: String, code: String? = nil) -> BrowserActionResult {
        var payload: [String: Any] = [
            "status": "error",
            "message": String(message.prefix(1000))
        ]
        if let code {
            payload["code"] = code
        }
        return BrowserActionResult(jsonContent: jsonString(payload), isError: true)
    }

    public static func ok(
        _ dict: [String: Any],
        attachments: [ChatAttachment] = [],
        resultParts: [ToolResultPart]? = nil
    ) -> BrowserActionResult {
        var mutable = dict
        if mutable["status"] == nil {
            mutable["status"] = "ok"
        }
        return BrowserActionResult(
            jsonContent: jsonString(mutable),
            isError: false,
            attachments: attachments,
            resultParts: resultParts
        )
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"error\",\"message\":\"Failed to serialize result\"}"
        }
        return result
    }
}

// MARK: - Browser Errors

public enum BrowserRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidArguments(String)
    case invalidURL(String)
    case unsupportedScheme(String)
    case navigationTimeout(String)
    case navigationFailed(String)
    case selectorNotFound(String)
    case passwordFieldRequiresTakeover
    case userHasControl
    case downloadNotSupported
    case screenshotFailed(String)
    case actionCancelled

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): "Invalid arguments: \(msg)"
        case .invalidURL(let url): "Invalid URL: \(url)"
        case .unsupportedScheme(let scheme): "Unsupported URL scheme '\(scheme)'. Only http:// and https:// are permitted."
        case .navigationTimeout(let url): "Navigation to \(url) timed out after 30 seconds."
        case .navigationFailed(let msg): "Navigation failed: \(msg)"
        case .selectorNotFound(let sel): "Element not found for selector: \(sel)"
        case .passwordFieldRequiresTakeover: "Password fields require user takeover."
        case .userHasControl: "The user currently controls the browser."
        case .downloadNotSupported: "Downloads are not supported yet."
        case .screenshotFailed(let msg): "Screenshot capture failed: \(msg)"
        case .actionCancelled: "Browser action cancelled."
        }
    }

    public var code: String? {
        switch self {
        case .passwordFieldRequiresTakeover: return "password_field_requires_takeover"
        case .downloadNotSupported: return "download_not_supported"
        default: return nil
        }
    }
}
