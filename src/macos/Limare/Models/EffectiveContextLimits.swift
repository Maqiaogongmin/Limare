import Foundation

/// Unified Context Budget and Token Limit Truth Resolver.
///
/// Establishes a single, authoritative, end-to-end consistent source of context limits
/// across Chat Completions, Responses, ContextLifecycle, and Model Group routing.
struct EffectiveContextLimits: Sendable, Equatable {
    /// opencode's OUTPUT_TOKEN_MAX: room for a long file write plus the reasoning before it,
    /// which thinking models spend from the same budget. Still clamped by the model's limit.
    static let appDefaultOutputLimit: Int = 32_000
    static let globalMaxTokensCeiling: Int = 128_000

    /// Resolved context window in tokens (nil if unknown/unspecified).
    let effectiveContextWindow: Int?
    /// Resolved output limit for wire payload emission (clamped to model capability ceiling).
    let effectiveMaxOutputTokens: Int
    /// Output token reserve for budget calculation (identical to effectiveMaxOutputTokens).
    let outputReserve: Int
    /// Tool definition and schema overhead reserve in tokens.
    let toolReserve: Int
    /// Proactive safety buffer tokens (10% of window, minimum 1,024, or 0 if window unknown).
    let safetyReserve: Int
    /// Effective maximum tokens available for conversation input messages (nil if window unknown).
    let effectiveInputBudget: Int?

    init(
        effectiveContextWindow: Int?,
        effectiveMaxOutputTokens: Int,
        outputReserve: Int,
        toolReserve: Int,
        safetyReserve: Int,
        effectiveInputBudget: Int?
    ) {
        self.effectiveContextWindow = effectiveContextWindow
        self.effectiveMaxOutputTokens = effectiveMaxOutputTokens
        self.outputReserve = outputReserve
        self.toolReserve = toolReserve
        self.safetyReserve = safetyReserve
        self.effectiveInputBudget = effectiveInputBudget
    }

    /// Resolves effective context window taking into account model capability and optional group limit.
    ///
    /// Rules:
    /// - Direct model: uses model's own effective contextWindow (including user overrides)
    /// - Model Group: if group contextLimitTokens is set (> 0), limits the context window
    /// - Group limit cannot exceed the model's native / user-overridden context window
    /// - Unknown context window (nil) is preserved as nil (never fabricated)
    static func resolveEffectiveContextWindow(
        modelContextWindow: Int?,
        groupContextLimit: Int?
    ) -> Int? {
        guard let modelWindow = modelContextWindow else {
            return nil
        }
        if let groupLimit = groupContextLimit, groupLimit > 0 {
            return min(modelWindow, groupLimit)
        }
        return modelWindow
    }

    /// Resolves max output token ceiling for wire emission and budget reserves.
    ///
    /// Rules:
    /// - requestedOutput = explicitRequestLimit ?? appDefaultOutputLimit (32_000)
    /// - effectiveModelCapability = ProviderModel.maxOutputTokens (user overrides are authoritative capability metadata)
    /// - ceiling = min(effectiveModelCapability ?? globalMaxTokensCeiling, globalMaxTokensCeiling)
    /// - effectiveOutput = min(requestedOutput, ceiling)
    /// - When context window is constrained (e.g. Group context limit): output reserve is bounded to ensure
    ///   the effective input budget is never starved to 0 by default requests or excessive reserves.
    /// - clamped between 1 and globalMaxTokensCeiling (128_000)
    static func resolveEffectiveMaxOutputTokens(
        explicitRequestLimit: Int?,
        modelEffectiveMaxOutput: Int?,
        effectiveContextWindow: Int? = nil,
        toolReserve: Int = 0,
        safetyReserve: Int = 0
    ) -> Int {
        let requested = explicitRequestLimit ?? appDefaultOutputLimit
        let modelCap = min(modelEffectiveMaxOutput ?? globalMaxTokensCeiling, globalMaxTokensCeiling)
        var effective = min(requested, modelCap)

        // Protect against context window starvation when context window is constrained
        if let window = effectiveContextWindow, window > 0 {
            let availableForOutputAndInput = max(0, window - safetyReserve - toolReserve)
            if availableForOutputAndInput > 0 {
                let minInputReserve = min(1_024, max(1, availableForOutputAndInput / 5))
                if effective > availableForOutputAndInput - minInputReserve {
                    if explicitRequestLimit == nil {
                        // Default request: give at most half of available window to output
                        effective = max(1, availableForOutputAndInput / 2)
                    } else {
                        // Explicit request: cap so at least minInputReserve remains
                        effective = max(1, availableForOutputAndInput - minInputReserve)
                    }
                }
            } else {
                effective = max(1, min(effective, window))
            }
        }

        return max(1, min(effective, globalMaxTokensCeiling))
    }

    /// What a default request cut off at its output limit is requested again with (Claude Code's
    /// max-output escalation): the model's own declared limit, as far as the context window has
    /// room after the input. Nil when the model declares no limit, since a guess could be refused.
    static func escalatedOutputLimit(modelMaxOutput: Int?, outputRoom: Int?) -> Int? {
        guard let modelMaxOutput, modelMaxOutput > 0 else { return nil }
        let limit = min(modelMaxOutput, globalMaxTokensCeiling, outputRoom ?? globalMaxTokensCeiling)
        return limit > 0 ? limit : nil
    }

    /// The output tokens the context window has room for after a request's input: what the
    /// budget leaves for output plus what the estimate leaves unused (nil when the window is unknown).
    static func outputRoom(for budget: ContextBudget) -> Int? {
        guard let window = budget.contextWindow else { return nil }
        let room = window - budget.estimatedTokens - budget.toolReserve - budget.safetyReserve
        return max(budget.outputReserve, room)
    }

    /// Estimates token consumption for active tool definitions.
    static func calculateToolReserve(tools: [ChatToolDefinition]) -> Int {
        let toolBytes = (try? JSONEncoder().encode(tools).count) ?? 0
        let tokens = max(0, (toolBytes + 2) / 3)
        return tokens + 256
    }

    /// Calculates safety reserve buffer based on effective context window.
    static func calculateSafetyReserve(effectiveContextWindow: Int?) -> Int {
        guard let window = effectiveContextWindow, window > 0 else { return 0 }
        let tenPercent = window / 10
        let minSafety = min(1_024, max(1, window / 10))
        return max(minSafety, min(tenPercent, window / 4))
    }

    /// Calculates effective input budget available for prompt + messages.
    static func calculateEffectiveInputBudget(
        effectiveContextWindow: Int?,
        outputReserve: Int,
        toolReserve: Int,
        safetyReserve: Int
    ) -> Int? {
        guard let window = effectiveContextWindow else { return nil }
        return max(0, window - outputReserve - toolReserve - safetyReserve)
    }

    /// Single authoritative resolver creating an EffectiveContextLimits snapshot for a candidate.
    static func resolve(
        model: ProviderModel?,
        groupContextLimitTokens: Int? = nil,
        explicitMaxOutputTokens: Int? = nil,
        tools: [ChatToolDefinition] = []
    ) -> EffectiveContextLimits {
        let window = resolveEffectiveContextWindow(
            modelContextWindow: model?.contextWindow,
            groupContextLimit: groupContextLimitTokens
        )
        let toolReserve = calculateToolReserve(tools: tools)
        let safetyReserve = calculateSafetyReserve(effectiveContextWindow: window)
        let effectiveOutput = resolveEffectiveMaxOutputTokens(
            explicitRequestLimit: explicitMaxOutputTokens,
            modelEffectiveMaxOutput: model?.maxOutputTokens,
            effectiveContextWindow: window,
            toolReserve: toolReserve,
            safetyReserve: safetyReserve
        )
        let outputReserve = effectiveOutput
        let inputBudget = calculateEffectiveInputBudget(
            effectiveContextWindow: window,
            outputReserve: outputReserve,
            toolReserve: toolReserve,
            safetyReserve: safetyReserve
        )
        return EffectiveContextLimits(
            effectiveContextWindow: window,
            effectiveMaxOutputTokens: effectiveOutput,
            outputReserve: outputReserve,
            toolReserve: toolReserve,
            safetyReserve: safetyReserve,
            effectiveInputBudget: inputBudget
        )
    }
}
