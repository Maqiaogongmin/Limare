import Foundation
import CryptoKit

enum HookEventName: String, Codable, Sendable, CaseIterable {
    // Supported in Limare 3S1
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure" // Limare compatibility extension
    case stop = "Stop"
    case sessionEnd = "SessionEnd"

    // Known but unsupported in current Limare
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case notification = "Notification"
    case taskCompleted = "TaskCompleted"
    case permissionRequest = "PermissionRequest"
    case interrupt = "Interrupt"

    var isSupported: Bool {
        switch self {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure, .stop, .sessionEnd:
            return true
        default:
            return false
        }
    }

    var isLimareExtension: Bool {
        self == .postToolUseFailure
    }
}

struct HookHandlerType: Codable, Sendable, Equatable, Hashable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let command = HookHandlerType(rawValue: "command")
    static let mcpTool = HookHandlerType(rawValue: "mcp_tool")
    static let prompt = HookHandlerType(rawValue: "prompt")
    static let agent = HookHandlerType(rawValue: "agent")

    var isSupported: Bool {
        rawValue == "command"
    }
}

struct HookHandlerConfig: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var type: HookHandlerType
    var command: String?
    var timeout: Int?
    var statusMessage: String?
    var additionalContextLimit: Int?
    var enabled: Bool?
    var isAsync: Bool?

    init(
        id: String = "",
        type: HookHandlerType = .command,
        command: String? = nil,
        timeout: Int? = nil,
        statusMessage: String? = nil,
        additionalContextLimit: Int? = nil,
        enabled: Bool? = true,
        isAsync: Bool? = nil
    ) {
        self.type = type
        self.command = command
        self.timeout = timeout
        self.statusMessage = statusMessage
        self.additionalContextLimit = additionalContextLimit
        self.enabled = enabled
        self.isAsync = isAsync
        if id.isEmpty {
            self.id = "\(type.rawValue):\(command ?? ""):\(timeout ?? 0):\(statusMessage ?? ""):\(additionalContextLimit ?? 0):\(enabled ?? true):\(isAsync ?? false)"
        } else {
            self.id = id
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case command
        case timeout
        case statusMessage
        case additionalContextLimit
        case enabled
        case isAsync = "async"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? "command"
        self.type = HookHandlerType(rawValue: rawType)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.timeout = try container.decodeIfPresent(Int.self, forKey: .timeout)
        self.statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        self.additionalContextLimit = try container.decodeIfPresent(Int.self, forKey: .additionalContextLimit)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        self.isAsync = try container.decodeIfPresent(Bool.self, forKey: .isAsync)
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        if !decodedID.isEmpty {
            self.id = decodedID
        } else {
            self.id = "\(type.rawValue):\(command ?? ""):\(timeout ?? 0):\(statusMessage ?? ""):\(additionalContextLimit ?? 0):\(enabled ?? true):\(isAsync ?? false)"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type.rawValue, forKey: .type)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encodeIfPresent(timeout, forKey: .timeout)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encodeIfPresent(additionalContextLimit, forKey: .additionalContextLimit)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encodeIfPresent(isAsync, forKey: .isAsync)
    }

    /// True only when the stored command contains non-whitespace input.
    /// This is admission truth; the original command is never rewritten for execution.
    var hasRunnableCommand: Bool {
        guard let command else { return false }
        return !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var effectiveTimeout: Int {
        if let timeout {
            return min(max(timeout, 1), 600)
        }
        return 600
    }

    var effectiveSessionEndTimeout: Int {
        if let timeout {
            return min(max(timeout, 1), 10)
        }
        return 3
    }
}

struct HookMatcherGroup: Codable, Sendable, Identifiable, Equatable {
    var id: String {
        let hooksID = hooks.map(\.id).joined(separator: "|")
        return "\(matcher ?? "*"):\(hooksID)"
    }

    var matcher: String?
    var hooks: [HookHandlerConfig]

    init(matcher: String? = nil, hooks: [HookHandlerConfig] = []) {
        self.matcher = matcher
        self.hooks = hooks
    }
}

struct HookSourceConfig: Codable, Sendable, Equatable {
    var hooks: [String: [HookMatcherGroup]]

    init(hooks: [String: [HookMatcherGroup]] = [:]) {
        self.hooks = Self.canonicalizeHooks(hooks)
    }

    enum CodingKeys: String, CodingKey {
        case hooks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawHooks = try container.decodeIfPresent([String: [HookMatcherGroup]].self, forKey: .hooks) ?? [:]
        self.hooks = Self.canonicalizeHooks(rawHooks)
    }

    static func canonicalizeHooks(_ original: [String: [HookMatcherGroup]]) -> [String: [HookMatcherGroup]] {
        var result: [String: [HookMatcherGroup]] = [:]
        for (eventKey, groups) in original {
            var newGroups: [HookMatcherGroup] = []
            for (groupIndex, group) in groups.enumerated() {
                var newHooks: [HookHandlerConfig] = []
                for (handlerIndex, hook) in group.hooks.enumerated() {
                    var updated = hook
                    let rawSignature = "\(eventKey)|\(group.matcher ?? "*")|\(groupIndex)|\(handlerIndex)|\(hook.type.rawValue)|\(hook.command ?? "")"
                    let digest = SHA256.hash(data: Data(rawSignature.utf8))
                    updated.id = digest.compactMap { String(format: "%02x", $0) }.joined()
                    newHooks.append(updated)
                }
                var newGroup = group
                newGroup.hooks = newHooks
                newGroups.append(newGroup)
            }
            result[eventKey] = newGroups
        }
        return result
    }
}

enum HookSourceKind: String, Codable, Sendable {
    case manualImport
    case codexUser
    case codexProject
    case codexPlugin

    var displayName: String {
        switch self {
        case .manualImport: "Imported Package"
        case .codexUser: "Codex User Config"
        case .codexProject: "Codex Project Config"
        case .codexPlugin: "Codex Plugin"
        }
    }
}

struct HookSource: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var configURL: URL
    var packageRootURL: URL
    var sourceKind: HookSourceKind
    var description: String?
    var isEnabled: Bool
    var disabledHandlerIDs: Set<String>
    var definitionHash: String
    var lastLoadedAt: Date?
    var loadError: String?
    var config: HookSourceConfig

    init(
        id: UUID = UUID(),
        name: String,
        configURL: URL,
        packageRootURL: URL,
        sourceKind: HookSourceKind,
        description: String? = nil,
        isEnabled: Bool = true,
        disabledHandlerIDs: Set<String> = [],
        definitionHash: String = "",
        lastLoadedAt: Date? = nil,
        loadError: String? = nil,
        config: HookSourceConfig = HookSourceConfig()
    ) {
        self.id = id
        self.name = name
        self.configURL = configURL
        self.packageRootURL = packageRootURL
        self.sourceKind = sourceKind
        self.description = description
        self.isEnabled = isEnabled
        self.disabledHandlerIDs = disabledHandlerIDs
        self.definitionHash = definitionHash
        self.lastLoadedAt = lastLoadedAt
        self.loadError = loadError
        self.config = config
    }

    func isHandlerConfigDisabled(hook: HookHandlerConfig) -> Bool {
        hook.enabled == false
    }

    func isHandlerUserDisabled(id: String) -> Bool {
        disabledHandlerIDs.contains(id)
    }

    func isHandlerEnabled(id: String) -> Bool {
        isEnabled && !disabledHandlerIDs.contains(id)
    }

    func isHandlerEnabled(hook: HookHandlerConfig) -> Bool {
        isEnabled && (hook.enabled ?? true) && !disabledHandlerIDs.contains(hook.id)
    }

    func isHandlerRunnable(hook: HookHandlerConfig) -> Bool {
        isEnabled && (hook.enabled ?? true) && !disabledHandlerIDs.contains(hook.id) && hook.type.isSupported && hook.hasRunnableCommand && (hook.isAsync != true)
    }
}

struct HookExecutionSummary: Sendable, Identifiable {
    let id = UUID()
    let sourceID: UUID
    let sourceName: String
    let eventName: String
    let handlerID: String
    let command: String
    let exitCode: Int32
    let durationMilliseconds: Double
    let stdoutSize: Int
    let stderrSize: Int
    let additionalContext: String?
    let permissionDecision: String? // allow / deny
    let permissionDecisionReason: String?
    let continueTurn: Bool?
    let stopReason: String?
    let isTimeout: Bool
    let isCancelled: Bool
    let error: String?
    let definitionHash: String

    init(
        sourceID: UUID,
        sourceName: String,
        eventName: String,
        handlerID: String,
        command: String,
        exitCode: Int32,
        durationMilliseconds: Double,
        stdoutSize: Int,
        stderrSize: Int,
        additionalContext: String? = nil,
        permissionDecision: String? = nil,
        permissionDecisionReason: String? = nil,
        continueTurn: Bool? = nil,
        stopReason: String? = nil,
        isTimeout: Bool = false,
        isCancelled: Bool = false,
        error: String? = nil,
        definitionHash: String = ""
    ) {
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.eventName = eventName
        self.handlerID = handlerID
        self.command = command
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
        self.stdoutSize = stdoutSize
        self.stderrSize = stderrSize
        self.additionalContext = additionalContext
        self.permissionDecision = permissionDecision
        self.permissionDecisionReason = permissionDecisionReason
        self.continueTurn = continueTurn
        self.stopReason = stopReason
        self.isTimeout = isTimeout
        self.isCancelled = isCancelled
        self.error = error
        self.definitionHash = definitionHash
    }

    func asExtensionContribution() -> ExtensionContribution? {
        guard let ctx = additionalContext,
              !ctx.isEmpty,
              !definitionHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let version = ExtensionSourceVersion(value: definitionHash)
        return ExtensionContribution(
            identity: ExtensionContributionIdentity(
                kind: .hook,
                sourceID: sourceID.uuidString,
                sourceVersion: version,
                localID: "\(eventName):\(handlerID):\(id.uuidString)"
            ),
            origin: .hookInvocation(
                sourceID: sourceID,
                definitionHash: definitionHash,
                eventName: eventName,
                handlerID: handlerID,
                executionID: id
            ),
            prerequisites: .hookExecuted(
                trusted: true,
                applicable: true,
                executedWithOutput: true
            ),
            payload: .contextFragment(ctx),
            claim: .runtimeDerived
        )
    }
}

struct HookAggregatedResult: Sendable {
    var shouldDeny: Bool
    var denyReason: String?
    var shouldBlockTurn: Bool
    var blockTurnReason: String?
    var additionalContext: String?
    var executions: [HookExecutionSummary]

    init(
        shouldDeny: Bool = false,
        denyReason: String? = nil,
        shouldBlockTurn: Bool = false,
        blockTurnReason: String? = nil,
        additionalContext: String? = nil,
        executions: [HookExecutionSummary] = []
    ) {
        self.shouldDeny = shouldDeny
        self.denyReason = denyReason
        self.shouldBlockTurn = shouldBlockTurn
        self.blockTurnReason = blockTurnReason
        self.additionalContext = additionalContext
        self.executions = executions
    }
}
