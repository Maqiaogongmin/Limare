import Foundation

/// Request-level inference options passed down from UI / Group routing into Chat Client.
struct ChatInferenceOptions: Sendable, Equatable {
    var thinkingLevel: ThinkingLevel
    var maxOutputTokens: Int?
    var model: ProviderModel?
    var groupContextLimitTokens: Int?
    var providerID: UUID?
    var apiFormat: ProviderAPIFormat?
    var adapterDisabledNativeVision: Bool

    init(
        thinkingLevel: ThinkingLevel = .off,
        maxOutputTokens: Int? = nil,
        model: ProviderModel? = nil,
        groupContextLimitTokens: Int? = nil,
        providerID: UUID? = nil,
        apiFormat: ProviderAPIFormat? = nil,
        adapterDisabledNativeVision: Bool = false
    ) {
        self.thinkingLevel = thinkingLevel
        self.maxOutputTokens = maxOutputTokens
        self.model = model
        self.groupContextLimitTokens = groupContextLimitTokens
        self.providerID = providerID
        self.apiFormat = apiFormat
        self.adapterDisabledNativeVision = adapterDisabledNativeVision
    }

    init(
        thinkingLevel: ThinkingLevel = .off,
        maxOutputTokens: Int? = nil,
        provider: ProviderConfiguration? = nil,
        model: ProviderModel? = nil,
        groupContextLimitTokens: Int? = nil,
        adapterDisabledNativeVision: Bool = false
    ) {
        self.thinkingLevel = thinkingLevel
        self.maxOutputTokens = maxOutputTokens
        self.model = model
        self.groupContextLimitTokens = groupContextLimitTokens
        self.providerID = provider?.id
        self.apiFormat = provider?.apiFormat
        self.adapterDisabledNativeVision = adapterDisabledNativeVision
    }

    /// Single authoritative context limits view for this inference configuration.
    func effectiveLimits(
        for targetModel: ProviderModel? = nil,
        tools: [ChatToolDefinition] = []
    ) -> EffectiveContextLimits {
        let selectedModel = targetModel ?? model
        return EffectiveContextLimits.resolve(
            model: selectedModel,
            groupContextLimitTokens: groupContextLimitTokens,
            explicitMaxOutputTokens: maxOutputTokens,
            tools: tools
        )
    }

    /// Model metadata describes a capability ceiling, not the default for every response.
    /// Explicit request limit or default is bounded by model capability ceiling.
    func resolvedMaxOutputTokens(for targetModel: ProviderModel? = nil) -> Int {
        effectiveLimits(for: targetModel).effectiveMaxOutputTokens
    }

    /// Resolved context window in tokens taking model capability and group limit into account.
    func effectiveContextWindow(for targetModel: ProviderModel? = nil) -> Int? {
        effectiveLimits(for: targetModel).effectiveContextWindow
    }
}
