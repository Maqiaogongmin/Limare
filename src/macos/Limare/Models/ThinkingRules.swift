import Foundation

/// Policy for echoing reasoning content back in conversational history.
struct ReasoningEchoPolicy: Codable, Hashable, Sendable {
    enum Timing: String, Codable, Hashable, Sendable {
        case never
        case afterToolUseOnly
        case always
    }

    var fieldName: String
    var timing: Timing

    init(fieldName: String = "reasoning_content", timing: Timing = .never) {
        self.fieldName = fieldName
        self.timing = timing
    }
}

/// How a given endpoint expects the thinking/reasoning control to appear on the wire.
enum ThinkingWireFormat: Equatable, Hashable, Sendable {
    /// Send nothing at all. Not "send off" — send NO thinking key whatsoever (e.g. Mistral).
    case omitEverything

    /// Root-level `reasoning_effort: "<tier>"` (OpenAI Chat Completions shape).
    case reasoningEffort(offValue: String?)

    /// Nested `reasoning: {effort: "<tier>"}` (OpenRouter / Responses shape).
    case reasoningEffortNested(offValue: String?)

    /// DeepSeek V4 sibling format: `{"thinking":{"type":"enabled"}, "reasoning_effort":"<tier>"}`
    /// and `{"thinking":{"type":"disabled"}}` when off.
    case deepSeekSibling

    /// Qwen / DashScope dual format: `enable_thinking` + `thinking_budget` at root and in `extra_body`.
    case qwenDual

    /// Qwen root-only format: `enable_thinking` only at root without budget or extra_body.
    case qwenRootOnly

    /// Plain root boolean switch with no tiers, e.g. `{"thinking": true/false}`.
    case booleanToggle(path: String)

    /// Nested boolean under extra_body, e.g. `extra_body.thinking.enabled`.
    case extraBodyToggle(path: String)

    /// Escape hatch custom path format.
    case customPath(path: String, values: [ThinkingLevel: String], offValue: String?)
}

/// One entry in a provider's thinking-rules list.
struct ThinkingRule: Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case custom
        case officialVendor
        case providerTypeDefault
    }

    enum Scope: Equatable, Hashable, Sendable {
        case allModels
        case modelPattern(String)

        func matches(_ modelId: String) -> Bool {
            switch self {
            case .allModels:
                return true
            case .modelPattern(let pattern):
                return Self.glob(
                    pattern.lowercased().replacingOccurrences(of: ".", with: "-"),
                    matches: modelId.lowercased().replacingOccurrences(of: ".", with: "-")
                )
            }
        }

        static func glob(_ pattern: String, matches input: String) -> Bool {
            let parts = pattern.components(separatedBy: "*")
            if parts.count == 1 { return input == pattern }

            var cursor = input.startIndex
            for (i, part) in parts.enumerated() {
                if part.isEmpty { continue }
                if i == 0 {
                    guard input.hasPrefix(part) else { return false }
                    cursor = input.index(cursor, offsetBy: part.count)
                    continue
                }
                if i == parts.count - 1 && !pattern.hasSuffix("*") {
                    guard input.hasSuffix(part),
                          input.distance(from: cursor, to: input.endIndex) >= part.count else { return false }
                    continue
                }
                guard let found = input.range(of: part, range: cursor..<input.endIndex) else { return false }
                cursor = found.upperBound
            }
            return true
        }
    }

    var kind: Kind
    var scope: Scope
    var wireFormat: ThinkingWireFormat?
    var reasoningEcho: ReasoningEchoPolicy?
    var label: String
    var id: String

    init(
        kind: Kind,
        scope: Scope,
        wireFormat: ThinkingWireFormat?,
        reasoningEcho: ReasoningEchoPolicy? = nil,
        label: String,
        id: String? = nil
    ) {
        self.kind = kind
        self.scope = scope
        self.wireFormat = wireFormat
        self.reasoningEcho = reasoningEcho
        self.label = label
        self.id = id ?? "\(label)/\(scope)"
    }
}

/// Context for evaluating thinking rules.
struct ThinkingResolveContext: Sendable {
    var modelId: String
    var supportsReasoning: Bool?
    var declaredEffortValues: [String]?
    var declaresNoEffortTiers: Bool
    var effortDeclarationIsAuthoritative: Bool
    var isXAI: Bool
    var level: ThinkingLevel
    var maxTokens: Int
    var isOpenRouter: Bool
    var usesUnifiedReasoningEffort: Bool
    var isMistral: Bool
    var isDashScope: Bool
    var offEffort: String?
    var userRules: [ThinkingRule]

    init(
        modelId: String,
        supportsReasoning: Bool? = nil,
        declaredEffortValues: [String]? = nil,
        declaresNoEffortTiers: Bool = false,
        effortDeclarationIsAuthoritative: Bool = false,
        isXAI: Bool = false,
        level: ThinkingLevel,
        maxTokens: Int = 128_000,
        isOpenRouter: Bool = false,
        usesUnifiedReasoningEffort: Bool = false,
        isMistral: Bool = false,
        isDashScope: Bool = false,
        offEffort: String? = nil,
        userRules: [ThinkingRule] = []
    ) {
        self.modelId = modelId
        self.supportsReasoning = supportsReasoning
        self.declaredEffortValues = declaredEffortValues
        self.declaresNoEffortTiers = declaresNoEffortTiers
        self.effortDeclarationIsAuthoritative = effortDeclarationIsAuthoritative
        self.isXAI = isXAI
        self.level = level
        self.maxTokens = maxTokens
        self.isOpenRouter = isOpenRouter
        self.usesUnifiedReasoningEffort = usesUnifiedReasoningEffort
        self.isMistral = isMistral
        self.isDashScope = isDashScope
        self.offEffort = offEffort
        self.userRules = userRules
    }
}

enum ThinkingEvidence: String, Sendable {
    case modelFamily
    case catalogAuthoritative
    case catalogHeuristic
    case endpointIdentity
    case modelCapability
}

struct ThinkingGateEvent: Sendable, Equatable {
    let id: String
    let evidence: ThinkingEvidence
    let verdict: String

    init(id: String, evidence: ThinkingEvidence, verdict: String) {
        self.id = id
        self.evidence = evidence
        self.verdict = verdict
    }

    var logFragment: String { "\(id)/\(evidence.rawValue):\(verdict)" }
}

struct ThinkingResolveTrace: Sendable {
    var matchedRuleLabel: String
    var matchedRuleKind: ThinkingRule.Kind
    var formatSource: String
    var wireFormat: ThinkingWireFormat?
    var emittedKeys: [String]
    var clampedFrom: String?
    var clampedTo: String?
    var gateEvents: [ThinkingGateEvent]

    init(
        matchedRuleLabel: String,
        matchedRuleKind: ThinkingRule.Kind,
        formatSource: String,
        wireFormat: ThinkingWireFormat?,
        emittedKeys: [String],
        clampedFrom: String?,
        clampedTo: String?,
        gateEvents: [ThinkingGateEvent] = []
    ) {
        self.matchedRuleLabel = matchedRuleLabel
        self.matchedRuleKind = matchedRuleKind
        self.formatSource = formatSource
        self.wireFormat = wireFormat
        self.emittedKeys = emittedKeys
        self.clampedFrom = clampedFrom
        self.clampedTo = clampedTo
        self.gateEvents = gateEvents
    }

    var logLine: String {
        var parts = ["rule=\(matchedRuleLabel)", "kind=\(matchedRuleKind)", "src=\(formatSource)"]
        if let from = clampedFrom, let to = clampedTo, from != to {
            parts.append("clamp=\(from)->\(to)")
        }
        parts.append("keys=[\(emittedKeys.sorted().joined(separator: ","))]")
        if !gateEvents.isEmpty {
            parts.append("gates=[\(gateEvents.map(\.logFragment).joined(separator: " "))]")
        }
        return parts.joined(separator: " ")
    }
}
