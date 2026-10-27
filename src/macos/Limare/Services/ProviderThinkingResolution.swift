import Foundation
#if canImport(OpenMinisProviders)
import OpenMinisProviders
#endif

struct ProviderThinkingResolution: Sendable, Equatable {
    let requested: ThinkingLevel
    let effective: ThinkingLevel
    let wireEffort: String?
    let supported: [ThinkingLevel]
    let unsupportedRawTiers: [String]
    let reason: String?

    /// A positive intent this model cannot carry. Group routing skips such candidates; a direct request runs at the model default.
    var thinkingUnsupported: Bool { requested != .off && effective == .off }

    static func supportedLevels(for model: ProviderModel?, provider: ProviderConfiguration? = nil, maxTokens: Int? = nil) -> [ThinkingLevel] {
        guard let model, model.supportsReasoning != false else { return [.off] }
        let declared = model.reasoningEffortValues ?? verifiedFamilyFallback(model)
        var levels = ConversationThinkingResolver.canonicalLevels(for: declared)
        if let raw = model.overrides.maxThinkingLevel {
            guard let ceiling = ThinkingLevel(rawValue: raw), ceiling != .ultra else { return [.off] }
            levels = levels.filter { $0 <= ceiling }
        }
        if provider?.protocolAdapter == .geminiNative { levels.removeAll { [.xhigh, .max].contains($0) } }
        levels.removeAll { $0 == .ultra }
        if let provider, projectsWire(provider.protocolAdapter) {
            // Each offered level must send its own complete thinking payload through the selected adapter.
            let cap = maxTokens ?? ChatInferenceOptions(model: model).resolvedMaxOutputTokens()
            var seen: Set<Data> = []
            levels = levels.filter { level in
                guard let control = wireControl(for: level, model: model, provider: provider, maxTokens: cap) else { return false }
                if level != .off && control == Data("{}".utf8) { return false }
                return seen.insert(control).inserted
            }
        }
        return levels
    }

    /// Native projections live in OpenMinisProviders; source-only test builds compile without it.
    private static func projectsWire(_ format: ProviderAPIFormat) -> Bool {
        switch format {
        case .chatCompletions, .responses: return true
        case .anthropicMessages, .geminiNative:
            #if canImport(OpenMinisProviders)
            return true
            #else
            return false
            #endif
        }
    }

    /// The exact thinking payload the request builders send for one level, as sorted-key JSON.
    static func wireControl(for level: ThinkingLevel, model: ProviderModel, provider: ProviderConfiguration, maxTokens: Int) -> Data? {
        let control: [String: Any]
        switch provider.protocolAdapter {
        case .chatCompletions:
            control = OpenAIChatRequestBuilder.thinkingControl(provider: provider, modelID: model.id, model: model,
                                                               level: level, maxTokens: maxTokens)
        case .responses:
            control = OpenAIResponsesRequestBuilder.thinkingControl(provider: provider, modelID: model.id, model: model, level: level)
        case .anthropicMessages, .geminiNative:
            #if canImport(OpenMinisProviders)
            let wire: NativeWireProtocol = provider.protocolAdapter == .anthropicMessages ? .anthropicMessages : .geminiNative
            return try? NativeWireCodec.thinkingControlJSON(protocol: wire, modelID: model.id, maxTokens: maxTokens,
                thinking: level.rawValue, supportsReasoning: model.supportsReasoning, effortValues: model.reasoningEffortValues,
                kimiCodeProfile: provider.providerIdentity == .kimiCode)
            #else
            return nil
            #endif
        }
        return try? JSONSerialization.data(withJSONObject: control, options: [.sortedKeys])
    }

    /// Versioned mother/catalog fallbacks only fill missing declarations, never an explicit sparse/unknown set.
    private static func verifiedFamilyFallback(_ model: ProviderModel) -> [String]? {
        guard model.supportsReasoning == true, model.declaresNoEffortTiers != true else { return nil }
        let id = model.id.lowercased()
        if id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") { return ["low", "medium", "high"] }
        if id.hasPrefix("gpt-5.5") { return ["low", "medium", "high", "xhigh"] }
        if id.hasPrefix("gpt-5.6") { return ["low", "medium", "high", "xhigh", "max"] }
        if id.contains("mimo") || id.contains("agnes") || id.contains("seed-") || id.contains("doubao") { return ["low", "medium", "high"] }
        if id.contains("deepseek-v4") { return ["high", "max"] }
        // Native budget/toggle controls are already covered by the mother's wire golden tests.
        if id.contains("qwen") { return ["low", "medium", "high"] }
        if id.hasPrefix("claude-opus-4-7") || id.hasPrefix("claude-opus-4-8") || id.hasPrefix("claude-opus-5") || id.hasPrefix("claude-fable-5") {
            return ["low", "medium", "high", "xhigh", "max"]
        }
        if id.hasPrefix("claude") { return ["low", "medium", "high", "xhigh", "max"] }
        return nil
    }

    static func resolve(requested: ThinkingLevel, model: ProviderModel?, provider: ProviderConfiguration? = nil, maxTokens: Int? = nil) throws -> Self {
        guard requested != .ultra else {
            throw ProviderConnectionError.invalidThinking(String(localized: "Ultra orchestration is unavailable. Select a supported reasoning tier."))
        }
        let available = supportedLevels(for: model, provider: provider, maxTokens: maxTokens)
        let known = Set(["none", "off", "disabled", "minimal", "low", "medium", "high", "xhigh", "max"])
        let unknown = model?.reasoningEffortValues?.filter { !known.contains($0.lowercased()) } ?? []
        if requested == .off {
            return Self(requested: requested, effective: .off, wireEffort: nil, supported: available, unsupportedRawTiers: unknown, reason: nil)
        }
        let positive = available.filter { $0 != .off }
        guard !positive.isEmpty else {
            // No reasoning control to send: the request runs at the model default, and the reason is recorded.
            return Self(requested: requested, effective: .off, wireEffort: nil, supported: available, unsupportedRawTiers: unknown,
                        reason: String(localized: "Requested \(requested.rawValue), but the model has no executable reasoning control; sent the model default."))
        }
        let effective = positive.contains(requested) ? requested : positive.last(where: { $0 <= requested }) ?? positive[0]
        return Self(requested: requested, effective: effective, wireEffort: effective.rawValue,
                    supported: available, unsupportedRawTiers: unknown,
                    reason: effective == requested ? nil : String(localized: "Requested \(requested.rawValue), model accepts \(effective.rawValue)."))
    }

    static func offLabel(model: ProviderModel?, provider: ProviderConfiguration) -> String {
        if provider.providerIdentity == .kimiCode && model?.declaresNoEffortTiers != true { return String(localized: "Off (K2.8 Preview)") }
        if model?.reasoningEffortValues?.contains(where: { ["none", "off", "disabled"].contains($0) }) == true { return "Off" }
        if provider.protocolAdapter == .geminiNative && model?.id.lowercased().contains("gemini-2.5-flash") == true { return "Off" }
        return String(localized: "Model Default")
    }
}
