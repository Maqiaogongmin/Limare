import Foundation

/// Data-driven resolver for OpenAI-compatible thinking and reasoning parameters.
enum ThinkingRuleResolver {

    // MARK: - Built-in registry

    /// Vendor rules in priority order.
    static func builtInRules(for ctx: ThinkingResolveContext) -> [ThinkingRule] {
        var rules: [ThinkingRule] = []

        // Mistral — total prohibition: request rejects `reasoning` and AssistantMessage rejects `reasoning_content`.
        if ctx.isMistral {
            rules.append(ThinkingRule(
                kind: .officialVendor,
                scope: .allModels,
                wireFormat: .omitEverything,
                reasoningEcho: ReasoningEchoPolicy(fieldName: "reasoning_content", timing: .never),
                label: "mistral-official"
            ))
        }

        // OpenRouter — nested `reasoning:{effort}`, omit when off.
        if ctx.isOpenRouter {
            rules.append(ThinkingRule(
                kind: .officialVendor,
                scope: .allModels,
                wireFormat: .reasoningEffortNested(offValue: nil),
                label: "openrouter"
            ))
        }

        // OpenAI native o-series / GPT-5.x / GPT-4.x — root reasoning_effort.
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("o1*"),
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-native"
        ))
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("o3*"),
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-native"
        ))
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("o4*"),
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-native"
        ))
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("gpt-5*"),
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-native"
        ))
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("gpt-4*"),
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-native"
        ))

        // Qwen / DashScope — dual-send vs root-only.
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("*qwen*"),
            wireFormat: ctx.isDashScope ? .qwenDual : .qwenRootOnly,
            label: ctx.isDashScope ? "qwen-dashscope" : "qwen-root-only"
        ))

        // Unified gateways (Volcengine Ark / Azure / Venice).
        if ctx.usesUnifiedReasoningEffort {
            rules.append(ThinkingRule(
                kind: .officialVendor,
                scope: .allModels,
                wireFormat: .reasoningEffort(offValue: ctx.offEffort),
                label: "unified-gateway(ark|azure|venice)"
            ))
        }

        // DeepSeek V4 vendor-native sibling shape.
        rules.append(ThinkingRule(
            kind: .officialVendor,
            scope: .modelPattern("*deepseek-v4*"),
            wireFormat: .deepSeekSibling,
            reasoningEcho: ReasoningEchoPolicy(fieldName: "reasoning_content", timing: .afterToolUseOnly),
            label: "deepseek-v4-official"
        ))

        // Fallback for providerType: generic root reasoning_effort with .allModels scope.
        rules.append(ThinkingRule(
            kind: .providerTypeDefault,
            scope: .allModels,
            wireFormat: .reasoningEffort(offValue: ctx.offEffort),
            label: "openai-compatible-default"
        ))

        return rules
    }

    // MARK: - Resolution

    /// Resolve and apply thinking parameters into the request body in-place.
    @discardableResult
    static func apply(to body: inout [String: Any], ctx: ThinkingResolveContext) -> ThinkingResolveTrace {
        let before = Set(body.keys)

        // Stage A: first-match-wins
        let rules = ctx.userRules + builtInRules(for: ctx)
        guard let winner = rules.first(where: { $0.scope.matches(ctx.modelId) }) else {
            return ThinkingResolveTrace(
                matchedRuleLabel: "none",
                matchedRuleKind: .providerTypeDefault,
                formatSource: "no-match",
                wireFormat: nil,
                emittedKeys: [],
                clampedFrom: nil,
                clampedTo: nil
            )
        }

        // Stage B: emission
        var formatSource = "rule"
        var format = winner.wireFormat
        if format == nil {
            format = .reasoningEffort(offValue: ctx.offEffort)
            formatSource = "providerTypeDefault"
        }

        var clampedFrom: String?
        var clampedTo: String?
        var gateEvents: [ThinkingGateEvent] = []

        if let format {
            let clamp = emit(format: format, ctx: ctx, into: &body, gateEvents: &gateEvents)
            clampedFrom = clamp.from
            clampedTo = clamp.to
        }

        let emitted = Array(Set(body.keys).subtracting(before))
        return ThinkingResolveTrace(
            matchedRuleLabel: winner.label,
            matchedRuleKind: winner.kind,
            formatSource: formatSource,
            wireFormat: format,
            emittedKeys: emitted,
            clampedFrom: clampedFrom,
            clampedTo: clampedTo,
            gateEvents: gateEvents
        )
    }

    // MARK: - Emission

    private static func emit(
        format: ThinkingWireFormat,
        ctx: ThinkingResolveContext,
        into body: inout [String: Any],
        gateEvents: inout [ThinkingGateEvent]
    ) -> (from: String?, to: String?) {
        let lid = ctx.modelId.lowercased()
        let strictEffortEnum = lid.contains("mimo") || lid.contains("agnes")

        let declaredTiers = ctx.declaredEffortValues.map { Set($0.map { $0.lowercased() }) }
        let offTierNotDeclared: Bool = {
            guard ctx.effortDeclarationIsAuthoritative else { return false }
            guard let tiers = declaredTiers, !tiers.isEmpty else { return false }
            return tiers.isDisjoint(with: ["none", "off", "disabled"])
        }()
        let offEffort = (strictEffortEnum || offTierNotDeclared) ? nil : ctx.offEffort

        if ctx.offEffort != nil, !ctx.level.isEnabled {
            if strictEffortEnum {
                gateEvents.append(ThinkingGateEvent(
                    id: "strict-effort-enum", evidence: .modelFamily, verdict: "suppressOffTier"
                ))
            }
            if offTierNotDeclared {
                gateEvents.append(ThinkingGateEvent(
                    id: "off-tier-not-declared", evidence: .catalogAuthoritative, verdict: "suppressOffTier"
                ))
            }
        }

        switch format {
        case .omitEverything:
            return (nil, nil)

        case .reasoningEffortNested:
            guard ctx.level.isEnabled else { return (nil, nil) }
            let effort = clampEffort(wireEffort(for: ctx.level), to: ctx.declaredEffortValues)
            body["reasoning"] = ["effort": effort]
            return (effort, effort)

        case .reasoningEffort:
            let isOpenAINative = lid.hasPrefix("o1") || lid.hasPrefix("o3") || lid.hasPrefix("o4")
                || lid.hasPrefix("gpt-5") || lid.hasPrefix("gpt-4")
            if isOpenAINative {
                guard ctx.supportsReasoning == true else {
                    gateEvents.append(ThinkingGateEvent(
                        id: "openai-native-unconfirmed-reasoning", evidence: .modelCapability, verdict: "emitNothing"
                    ))
                    return (nil, nil)
                }
                if ctx.level.isEnabled {
                    let effort = clampEffort(wireEffort(for: ctx.level), to: ctx.declaredEffortValues)
                    body["reasoning_effort"] = effort
                    return (effort, effort)
                } else if let offEffort {
                    body["reasoning_effort"] = offEffort
                    return (offEffort, offEffort)
                }
                return (nil, nil)
            }

            // Generic path
            let declaresEffort = !(ctx.declaredEffortValues?.isEmpty ?? true)
            if !ctx.usesUnifiedReasoningEffort, !declaresEffort,
               ["deepseek", "glm", "kimi", "minimax"].contains(where: { lid.contains($0) }) {
                gateEvents.append(ThinkingGateEvent(
                    id: "self-reasoning-family", evidence: .modelFamily, verdict: "emitNothing"
                ))
                return (nil, nil)
            }

            if ctx.isXAI, !ctx.usesUnifiedReasoningEffort,
               ctx.declaresNoEffortTiers, !declaresEffort {
                gateEvents.append(ThinkingGateEvent(
                    id: "xai-no-effort-tiers", evidence: .endpointIdentity, verdict: "emitNothing"
                ))
                return (nil, nil)
            }

            guard ctx.supportsReasoning != false else {
                gateEvents.append(ThinkingGateEvent(
                    id: "non-reasoning-model", evidence: .modelCapability, verdict: "emitNothing"
                ))
                return (nil, nil)
            }

            if !ctx.level.isEnabled {
                if let offEffort, ctx.declaredEffortValues?.contains(offEffort) ?? true {
                    body["reasoning_effort"] = offEffort
                    return (offEffort, offEffort)
                }
                if ctx.offEffort != nil, offEffort != nil {
                    gateEvents.append(ThinkingGateEvent(
                        id: "off-tier-not-in-declared-set", evidence: .catalogHeuristic, verdict: "suppressOffTier"
                    ))
                }
                return (nil, nil)
            }

            let requested = wireEffort(for: ctx.level)
            let clamped = clampEffort(requested, to: ctx.declaredEffortValues)
            body["reasoning_effort"] = clamped
            return (requested, clamped)

        case .deepSeekSibling:
            if ctx.level.isEnabled {
                let requested = wireEffort(for: ctx.level)
                let clamped = clampEffort(requested, to: ctx.declaredEffortValues)
                body["thinking"] = ["type": "enabled"]
                body["reasoning_effort"] = clamped
                return (requested, clamped)
            }
            body["thinking"] = ["type": "disabled"]
            return (nil, nil)

        case .qwenDual:
            let enabled = ctx.level.isEnabled
            let budget = qwenThinkingBudget(for: ctx)
            body["enable_thinking"] = enabled
            if budget > 0 { body["thinking_budget"] = budget }
            var extra: [String: Any] = ["enable_thinking": enabled]
            if budget > 0 {
                extra["thinking_budget"] = budget
            } else {
                extra["thinking_budget"] = NSNull()
            }
            body["extra_body"] = extra
            return (nil, nil)

        case .qwenRootOnly:
            body["enable_thinking"] = ctx.level.isEnabled
            return (nil, nil)

        case .booleanToggle(let path):
            setValue(true, at: path, in: &body, when: ctx.level.isEnabled, otherwiseWrite: false)
            return (nil, nil)

        case .extraBodyToggle(let path):
            setValue(true, at: path, in: &body, when: ctx.level.isEnabled, otherwiseWrite: false)
            return (nil, nil)

        case .customPath(let path, let values, let offValue):
            if ctx.level.isEnabled {
                guard let v = values[ctx.level] ?? values[.high] else { return (nil, nil) }
                setValue(v, at: path, in: &body, when: true, otherwiseWrite: nil)
                return (v, v)
            }
            guard let off = offValue else { return (nil, nil) }
            setValue(off, at: path, in: &body, when: true, otherwiseWrite: nil)
            return (off, off)
        }
    }

    // MARK: - Effort & Budget Helpers

    static func wireEffort(for level: ThinkingLevel) -> String {
        switch level {
        case .off: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max: "max"
        case .ultra: "unsupported-harness-intent"
        }
    }

    static func clampEffort(_ effort: String, to values: [String]?) -> String {
        guard let values, !values.isEmpty else { return effort }
        if values.contains(effort) { return effort }
        let ladder = ["minimal", "low", "medium", "high", "xhigh", "max"]
        guard let want = ladder.firstIndex(of: effort) else { return effort }
        let declared = values.compactMap { v in ladder.firstIndex(of: v).map { ($0, v) } }
            .sorted { $0.0 < $1.0 }
        guard !declared.isEmpty else { return effort }
        if let below = declared.last(where: { $0.0 <= want }) { return below.1 }
        return declared[0].1
    }

    static func explicitOffEffort(baseURL: String, modelID: String, level: ThinkingLevel) -> String? {
        guard !level.isEnabled else { return nil }
        let base = baseURL.lowercased()
        let lid = modelID.lowercased()
        if base.contains("volces") || base.contains("ark.")
            || lid.contains("seed-") || lid.contains("doubao") {
            return nil // No documented true-off action; minimal must stay a positive tier.
        }
        if base.isEmpty || base.contains("api.openai.com") {
            return "none"
        }
        return nil
    }

    static func qwenThinkingBudget(for ctx: ThinkingResolveContext) -> Int {
        var budget: Int = switch ctx.level {
        case .off: 0
        case .minimal: 1024
        case .low: 4096
        case .medium: 16384
        case .high: 32768
        case .xhigh, .max: 65536
        case .ultra: 0
        }
        guard budget > 0, ctx.maxTokens > 0 else { return budget }
        if ctx.maxTokens < 2 { return 0 }
        let margin = max(2048, ctx.maxTokens / 8)
        let ceiling = max(1, min(ctx.maxTokens - margin, ctx.maxTokens - 1))
        if budget >= ceiling { budget = ceiling }
        return budget
    }

    // MARK: - Dictionary Nested Insertion

    private static func setValue(
        _ value: Any,
        at path: String,
        in body: inout [String: Any],
        when condition: Bool,
        otherwiseWrite fallback: Any?
    ) {
        let toWrite: Any? = condition ? value : fallback
        guard let toWrite else { return }
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return }
        body = Self.inserting(toWrite, parts: parts, into: body)
    }

    private static func inserting(_ value: Any, parts: [String], into dict: [String: Any]) -> [String: Any] {
        var out = dict
        guard let head = parts.first else { return out }
        if parts.count == 1 {
            out[head] = value
            return out
        }
        let child = out[head] as? [String: Any] ?? [:]
        out[head] = Self.inserting(value, parts: Array(parts.dropFirst()), into: child)
        return out
    }
}
