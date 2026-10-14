import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case openAICompatible

    public var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI-compatible"
        }
    }
}

public enum ModelMetadataSource: String, Codable, Hashable, Sendable {
    case userOverride = "User Override"
    case providerDeclaration = "Provider Declaration"
    case modelsDevAuthoritative = "models.dev (Authoritative)"
    case builtIn = "Built-in Catalog"
    case modelsDevFallback = "models.dev (Fallback)"
    case inferred = "Inferred"
    case custom = "Custom"
    case unknown = "Unknown"
}

public struct ModelCapabilityProvenance: Codable, Hashable, Sendable {
    public var modality: ModelMetadataSource
    public var contextWindow: ModelMetadataSource
    public var maxOutputTokens: ModelMetadataSource
    public var reasoning: ModelMetadataSource
    public var reasoningEffort: ModelMetadataSource

    public init(
        modality: ModelMetadataSource = .unknown,
        contextWindow: ModelMetadataSource = .unknown,
        maxOutputTokens: ModelMetadataSource = .unknown,
        reasoning: ModelMetadataSource = .unknown,
        reasoningEffort: ModelMetadataSource = .unknown
    ) {
        self.modality = modality
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.reasoningEffort = reasoningEffort
    }
}

public enum ModelMetadataCompleteness: String, Sendable {
    case complete
    case partial
    case unknown
}

public struct ProviderModel: Identifiable, Codable, Hashable, Sendable {
    /// The API-reported Model ID (e.g. "deepseek-chat", "gpt-4o"). Never modified by overrides or catalog normalization.
    public let id: String
    /// The base display name reported by the API or Catalog.
    public var baseDisplayName: String
    /// Base modality detected or enriched from models.dev.
    public var baseModality: ModelModality?
    /// Base context window size in tokens (from models.dev or provider).
    public var baseContextWindow: Int?
    /// Base maximum output tokens supported.
    public var baseMaxOutputTokens: Int?
    /// Conservative account execution bound, distinct from the declared model maximum.
    public var accountContextLimit: Int? = nil
    public var capabilitySourceURL: String? = nil
    public var capabilityCatalogVersion: String? = nil
    /// Whether the model natively supports reasoning/thinking.
    public var baseSupportsReasoning: Bool?
    /// Accepted effort tiers on the wire (e.g. ["low", "medium", "high"]).
    public var reasoningEffortValues: [String]?
    /// Field name for interleaved reasoning content in streaming (e.g. "reasoning_content").
    public var interleavedReasoningField: String?
    /// True when catalog declares reasoning: true but no effort tiers (e.g. xAI).
    public var declaresNoEffortTiers: Bool?
    /// True when effort values came from authoritative provider match rather than cross-provider fallback.
    public var effortDeclarationIsAuthoritative: Bool?
    /// Overall provenance source of the underlying capability metadata.
    public var baseMetadataSource: ModelMetadataSource?
    /// Field-level provenance sources of the underlying base capability metadata.
    public var baseCapabilityProvenance: ModelCapabilityProvenance?

    /// User-set customizations that overlay on top of base values.
    public var overrides: ModelOverrides
    /// True when manually added by the user rather than discovered via `/models`.
    public var isCustom: Bool
    /// True when hidden from general model pickers.
    public var isHidden: Bool
    public var discovery = ModelDiscoveryState()
    /// Recorded conflict between upstream provider declaration / catalog and official card facts.
    public var officialFactsConflict: String? = nil

    // MARK: - Effective Computed Views

    /// Effective display name (user override wins if present, otherwise base name).
    public var displayName: String {
        get {
            overrides.displayName?.trimmingCharacters(in: .whitespaces).isEmpty == false
                ? overrides.displayName!
                : baseDisplayName
        }
        set {
            baseDisplayName = newValue
        }
    }

    /// Effective modality (calculates base modality combined with per-field overrides).
    public var modality: ModelModality? {
        ModelCapabilityTruthResolver.effectiveModality(baseModality: baseModality, overrides: overrides.modalityOverrides)
    }

    /// Effective context window in tokens (user override wins if present).
    public var contextWindow: Int? {
        if let explicit = overrides.contextWindow { return explicit }
        if let maximum = baseContextWindow, let accountContextLimit { return min(maximum, accountContextLimit) }
        return baseContextWindow
    }

    /// Effective max output tokens (user override wins if present).
    public var maxOutputTokens: Int? {
        overrides.maxOutputTokens ?? baseMaxOutputTokens
    }

    /// Effective reasoning flag (user override wins if present).
    public var supportsReasoning: Bool? {
        overrides.supportsReasoning ?? baseSupportsReasoning
    }

    /// Effective field-aware capability provenance taking user overrides into account.
    public var capabilityProvenance: ModelCapabilityProvenance {
        let baseMod = baseCapabilityProvenance?.modality ?? baseMetadataSource ?? (isCustom ? .custom : .unknown)
        let baseCtx = baseCapabilityProvenance?.contextWindow ?? baseMetadataSource ?? (isCustom ? .custom : .unknown)
        let baseMax = baseCapabilityProvenance?.maxOutputTokens ?? baseMetadataSource ?? (isCustom ? .custom : .unknown)
        let baseRea = baseCapabilityProvenance?.reasoning ?? baseMetadataSource ?? (isCustom ? .custom : .unknown)
        let baseEff = baseCapabilityProvenance?.reasoningEffort ?? baseMetadataSource ?? (isCustom ? .custom : .unknown)

        let hasModOverrides = overrides.modalityOverrides != nil && !overrides.modalityOverrides!.isEmpty
        return ModelCapabilityProvenance(
            modality: hasModOverrides ? .userOverride : (baseModality != nil ? baseMod : .unknown),
            contextWindow: overrides.contextWindow != nil ? .userOverride : (baseContextWindow != nil ? baseCtx : .unknown),
            maxOutputTokens: overrides.maxOutputTokens != nil ? .userOverride : (baseMaxOutputTokens != nil ? baseMax : .unknown),
            reasoning: overrides.supportsReasoning != nil ? .userOverride : (baseSupportsReasoning != nil ? baseRea : .unknown),
            reasoningEffort: overrides.maxThinkingLevel != nil ? .userOverride : (reasoningEffortValues != nil ? baseEff : .unknown)
        )
    }

    /// Effective overall metadata source (user override wins if present).
    public var metadataSource: ModelMetadataSource {
        if !overrides.isEmpty {
            return .userOverride
        }
        if let base = baseMetadataSource {
            return base
        }
        if isCustom {
            return .custom
        }
        return .unknown
    }

    /// Classification of how complete this model's capabilities metadata is.
    public var completeness: ModelMetadataCompleteness {
        let hasContext = (contextWindow ?? 0) > 0
        let hasOutput = (maxOutputTokens ?? 0) > 0
        let hasReasoning = supportsReasoning != nil
        let hasModality = modality != nil

        if hasContext && hasOutput && hasReasoning && hasModality {
            return .complete
        }
        if hasContext || hasOutput || hasReasoning || hasModality {
            return .partial
        }
        return .unknown
    }

    public init(
        id: String,
        displayName: String,
        baseModality: ModelModality? = nil,
        baseContextWindow: Int? = nil,
        baseMaxOutputTokens: Int? = nil,
        baseSupportsReasoning: Bool? = nil,
        reasoningEffortValues: [String]? = nil,
        interleavedReasoningField: String? = nil,
        declaresNoEffortTiers: Bool? = nil,
        effortDeclarationIsAuthoritative: Bool? = nil,
        baseMetadataSource: ModelMetadataSource? = nil,
        baseCapabilityProvenance: ModelCapabilityProvenance? = nil,
        overrides: ModelOverrides = ModelOverrides(),
        isCustom: Bool = false,
        isHidden: Bool = false,
        officialFactsConflict: String? = nil
    ) {
        self.id = id
        self.baseDisplayName = displayName
        self.baseModality = baseModality
        self.baseContextWindow = baseContextWindow
        self.baseMaxOutputTokens = baseMaxOutputTokens
        self.baseSupportsReasoning = baseSupportsReasoning
        self.reasoningEffortValues = reasoningEffortValues
        self.interleavedReasoningField = interleavedReasoningField
        self.declaresNoEffortTiers = declaresNoEffortTiers
        self.effortDeclarationIsAuthoritative = effortDeclarationIsAuthoritative
        self.baseMetadataSource = baseMetadataSource
        // Facts passed here without a source or provenance are the caller's declaration. Catalog and
        // registry models set their source, and stored models decode theirs, so neither changes;
        // without this, saving a provider would drop the facts as being of unknown origin.
        if baseCapabilityProvenance == nil, baseMetadataSource == nil,
           baseModality != nil || baseContextWindow != nil || baseMaxOutputTokens != nil
            || baseSupportsReasoning != nil || reasoningEffortValues != nil {
            self.baseCapabilityProvenance = ModelCapabilityProvenance(
                modality: baseModality != nil ? .providerDeclaration : .unknown,
                contextWindow: baseContextWindow != nil ? .providerDeclaration : .unknown,
                maxOutputTokens: baseMaxOutputTokens != nil ? .providerDeclaration : .unknown,
                reasoning: baseSupportsReasoning != nil ? .providerDeclaration : .unknown,
                reasoningEffort: reasoningEffortValues != nil ? .providerDeclaration : .unknown
            )
        } else {
            self.baseCapabilityProvenance = baseCapabilityProvenance
        }
        self.overrides = overrides
        self.isCustom = isCustom
        self.isHidden = isHidden
        self.officialFactsConflict = officialFactsConflict
    }

    // MARK: - Codable (Backward Compatible)

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseDisplayName
        case baseModality
        case baseContextWindow
        case baseMaxOutputTokens
        case accountContextLimit, capabilitySourceURL, capabilityCatalogVersion
        case baseSupportsReasoning
        case reasoningEffortValues
        case interleavedReasoningField
        case declaresNoEffortTiers
        case effortDeclarationIsAuthoritative
        case baseMetadataSource
        case baseCapabilityProvenance
        case overrides
        case isCustom
        case isHidden, discovery
        case officialFactsConflict
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)

        // Backwards compatibility: decode either baseDisplayName or legacy displayName
        if let bName = try container.decodeIfPresent(String.self, forKey: .baseDisplayName) {
            baseDisplayName = bName
        } else if let dName = try container.decodeIfPresent(String.self, forKey: .displayName) {
            baseDisplayName = dName
        } else {
            baseDisplayName = id
        }

        baseModality = try container.decodeIfPresent(ModelModality.self, forKey: .baseModality)
        baseContextWindow = try container.decodeIfPresent(Int.self, forKey: .baseContextWindow)
        baseMaxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .baseMaxOutputTokens)
        baseSupportsReasoning = try container.decodeIfPresent(Bool.self, forKey: .baseSupportsReasoning)
        accountContextLimit = try container.decodeIfPresent(Int.self, forKey: .accountContextLimit)
        capabilitySourceURL = try container.decodeIfPresent(String.self, forKey: .capabilitySourceURL)
        capabilityCatalogVersion = try container.decodeIfPresent(String.self, forKey: .capabilityCatalogVersion)
        reasoningEffortValues = try container.decodeIfPresent([String].self, forKey: .reasoningEffortValues)
        interleavedReasoningField = try container.decodeIfPresent(String.self, forKey: .interleavedReasoningField)
        declaresNoEffortTiers = try container.decodeIfPresent(Bool.self, forKey: .declaresNoEffortTiers)
        effortDeclarationIsAuthoritative = try container.decodeIfPresent(Bool.self, forKey: .effortDeclarationIsAuthoritative)
        baseMetadataSource = try container.decodeIfPresent(ModelMetadataSource.self, forKey: .baseMetadataSource)
        baseCapabilityProvenance = try container.decodeIfPresent(ModelCapabilityProvenance.self, forKey: .baseCapabilityProvenance)

        overrides = try container.decodeIfPresent(ModelOverrides.self, forKey: .overrides) ?? ModelOverrides()
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        discovery = try container.decodeIfPresent(ModelDiscoveryState.self, forKey: .discovery) ?? ModelDiscoveryState()
        officialFactsConflict = try container.decodeIfPresent(String.self, forKey: .officialFactsConflict)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(baseDisplayName, forKey: .baseDisplayName)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(baseModality, forKey: .baseModality)
        try container.encodeIfPresent(baseContextWindow, forKey: .baseContextWindow)
        try container.encodeIfPresent(baseMaxOutputTokens, forKey: .baseMaxOutputTokens)
        try container.encodeIfPresent(baseSupportsReasoning, forKey: .baseSupportsReasoning)
        try container.encodeIfPresent(accountContextLimit, forKey: .accountContextLimit)
        try container.encodeIfPresent(capabilitySourceURL, forKey: .capabilitySourceURL)
        try container.encodeIfPresent(capabilityCatalogVersion, forKey: .capabilityCatalogVersion)
        try container.encodeIfPresent(reasoningEffortValues, forKey: .reasoningEffortValues)
        try container.encodeIfPresent(interleavedReasoningField, forKey: .interleavedReasoningField)
        try container.encodeIfPresent(declaresNoEffortTiers, forKey: .declaresNoEffortTiers)
        try container.encodeIfPresent(effortDeclarationIsAuthoritative, forKey: .effortDeclarationIsAuthoritative)
        try container.encodeIfPresent(baseMetadataSource, forKey: .baseMetadataSource)
        try container.encodeIfPresent(baseCapabilityProvenance, forKey: .baseCapabilityProvenance)
        try container.encodeIfPresent(officialFactsConflict, forKey: .officialFactsConflict)
        if !overrides.isEmpty {
            try container.encode(overrides, forKey: .overrides)
        }
        if isCustom {
            try container.encode(isCustom, forKey: .isCustom)
        }
        if isHidden {
            try container.encode(isHidden, forKey: .isHidden)
        }
        if discovery != ModelDiscoveryState() { try container.encode(discovery, forKey: .discovery) }
    }
}

public enum ProviderAuthenticationMode: String, Codable, CaseIterable, Sendable {
    case bearer
    case azureAPIKey
    case oauth
    case none

    public var displayName: String {
        switch self {
        case .bearer:
            "Bearer API Key"
        case .azureAPIKey:
            "Azure OpenAI (api-key)"
        case .oauth:
            "ChatGPT OAuth"
        case .none:
            "None"
        }
    }
}

public enum ProviderAPIFormat: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    case responses
    case anthropicMessages
    case geminiNative

    public var displayName: String {
        switch self {
        case .chatCompletions:
            "Chat Completions"
        case .responses:
            "Responses API"
        case .anthropicMessages:
            "Anthropic Messages"
        case .geminiNative:
            "Gemini Native"
        }
    }
}

public struct ProviderConfiguration: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var unknownLegacyKindRaw: String? = nil
    public var baseURL: String
    public var modelsURL: String? = nil
    public var appendV1Suffix: Bool
    public var providerIdentity: ProviderIdentity
    public var unknownProviderIdentityRaw: String?
    public var unknownProtocolRaw: String?
    public var authenticationSelection: ProviderAuthenticationSelection
    public var protocolAdapter: ProviderAPIFormat
    public var authenticationMode: ProviderAuthenticationMode {
        get { switch authenticationSelection.credentialKind {
            case .apiKey: .bearer; case .azureAPIKey: .azureAPIKey
            case .oauthAccessToken: .oauth; case .none: .none
        } }
        set { authenticationSelection = .legacy(newValue) }
    }
    public var apiFormat: ProviderAPIFormat {
        get { protocolAdapter }
        set { protocolAdapter = newValue }
    }
    public var customUserAgent: String?
    public var extraHeaders: [String: String]
    public var models: [ProviderModel]
    public var selectedModelID: String
    public var hasStoredSecret: Bool
    public var disabledNativeVision: Bool
    public var lastDiscovery: ProviderDiscoveryObservation?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind = .openAICompatible,
        baseURL: String,
        appendV1Suffix: Bool = true,
        authenticationMode: ProviderAuthenticationMode = .bearer,
        apiFormat: ProviderAPIFormat = .chatCompletions,
        customUserAgent: String? = nil,
        extraHeaders: [String: String] = [:],
        models: [ProviderModel] = [],
        selectedModelID: String = "",
        hasStoredSecret: Bool = false,
        disabledNativeVision: Bool = false,
        providerIdentity: ProviderIdentity = .custom,
        authenticationSelection: ProviderAuthenticationSelection? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.appendV1Suffix = appendV1Suffix
        self.providerIdentity = providerIdentity
        self.unknownProviderIdentityRaw = nil
        self.unknownProtocolRaw = nil
        self.authenticationSelection = authenticationSelection ?? .legacy(authenticationMode)
        self.protocolAdapter = apiFormat
        self.customUserAgent = customUserAgent
        self.extraHeaders = extraHeaders
        self.models = models
        self.selectedModelID = selectedModelID
        self.hasStoredSecret = hasStoredSecret
        self.disabledNativeVision = disabledNativeVision
    }

    public enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, modelsURL, appendV1Suffix, authenticationMode, apiFormat, customUserAgent, extraHeaders, models, selectedModelID, hasStoredSecret, disabledNativeVision, lastDiscovery
        case providerIdentity, protocolAdapter, authenticationSelection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let kindRaw = try container.decodeIfPresent(String.self, forKey: .kind) ?? "openAICompatible"
        kind = ProviderKind(rawValue: kindRaw) ?? .openAICompatible
        unknownLegacyKindRaw = ProviderKind(rawValue: kindRaw) == nil ? kindRaw : nil
        baseURL = try container.decode(String.self, forKey: .baseURL)
        modelsURL = try container.decodeIfPresent(String.self, forKey: .modelsURL)
        appendV1Suffix = try container.decode(Bool.self, forKey: .appendV1Suffix)
        let identityRaw = try container.decodeIfPresent(String.self, forKey: .providerIdentity) ?? "custom"
        providerIdentity = ProviderIdentity(rawValue: identityRaw) ?? .unsupported
        unknownProviderIdentityRaw = providerIdentity == .unsupported ? identityRaw : nil
        let protocolRaw = try container.decodeIfPresent(String.self, forKey: .protocolAdapter)
            ?? container.decodeIfPresent(String.self, forKey: .apiFormat) ?? "chatCompletions"
        protocolAdapter = ProviderAPIFormat(rawValue: protocolRaw) ?? .chatCompletions
        unknownProtocolRaw = ProviderAPIFormat(rawValue: protocolRaw) == nil ? protocolRaw : nil
        if let canonical = try container.decodeIfPresent(ProviderAuthenticationSelection.self, forKey: .authenticationSelection) {
            authenticationSelection = canonical
        } else {
            let legacyRaw = try container.decodeIfPresent(String.self, forKey: .authenticationMode) ?? "bearer"
            authenticationSelection = .legacy(ProviderAuthenticationMode(rawValue: legacyRaw) ?? .none)
            if ProviderAuthenticationMode(rawValue: legacyRaw) == nil { authenticationSelection.unknownAcquisitionRaw = legacyRaw }
        }
        customUserAgent = try container.decodeIfPresent(String.self, forKey: .customUserAgent)
        extraHeaders = try container.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:]
        models = try container.decode([ProviderModel].self, forKey: .models)
        selectedModelID = try container.decode(String.self, forKey: .selectedModelID)
        hasStoredSecret = try container.decodeIfPresent(Bool.self, forKey: .hasStoredSecret) ?? true
        disabledNativeVision = try container.decodeIfPresent(Bool.self, forKey: .disabledNativeVision) ?? false
        lastDiscovery = try container.decodeIfPresent(ProviderDiscoveryObservation.self, forKey: .lastDiscovery)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(unknownLegacyKindRaw ?? kind.rawValue, forKey: .kind)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(modelsURL, forKey: .modelsURL)
        try c.encode(appendV1Suffix, forKey: .appendV1Suffix)
        try c.encode(unknownProviderIdentityRaw ?? providerIdentity.rawValue, forKey: .providerIdentity)
        try c.encode(unknownProtocolRaw ?? protocolAdapter.rawValue, forKey: .protocolAdapter)
        try c.encode(authenticationSelection, forKey: .authenticationSelection)
        try c.encodeIfPresent(customUserAgent, forKey: .customUserAgent)
        try c.encode(extraHeaders, forKey: .extraHeaders)
        try c.encode(models, forKey: .models)
        try c.encode(selectedModelID, forKey: .selectedModelID)
        try c.encode(hasStoredSecret, forKey: .hasStoredSecret)
        try c.encode(disabledNativeVision, forKey: .disabledNativeVision)
        try c.encodeIfPresent(lastDiscovery, forKey: .lastDiscovery)
    }

    public static func empty() -> ProviderConfiguration {
        ProviderConfiguration(
            id: UUID(),
            name: "",
            kind: .openAICompatible,
            baseURL: "",
            appendV1Suffix: true,
            authenticationMode: .bearer,
            apiFormat: .chatCompletions,
            customUserAgent: nil,
            extraHeaders: [:],
            models: [],
            selectedModelID: "",
            hasStoredSecret: false,
            disabledNativeVision: false
        )
    }
}

public struct ProviderConfigurationFile: Codable, Sendable {
    public var providers: [ProviderConfiguration]
    public var selectedProviderID: UUID?
    public var openAIHostIdentity: String? = nil

    public init(providers: [ProviderConfiguration], selectedProviderID: UUID? = nil) {
        self.providers = providers
        self.selectedProviderID = selectedProviderID
    }
}
