import Foundation

/// Fetches and caches the models.dev provider registry.
/// Used as the source of truth for model capabilities (modality, context window, output limit, thinking).
public enum ModelsDevAPI {


    // MARK: - Public API

    public enum RegistryOrigin: String, Sendable {
        case bundled
        case diskCache
        case network
        case test
    }

    public struct RegistrySnapshot: Sendable {
        public let registry: [String: ModelsDevProvider]
        public let origin: RegistryOrigin
        public let timestamp: Date
        public let isFresh: Bool
        public let generation: UInt64

        public init(
            registry: [String: ModelsDevProvider],
            origin: RegistryOrigin,
            timestamp: Date,
            isFresh: Bool,
            generation: UInt64
        ) {
            self.registry = registry
            self.origin = origin
            self.timestamp = timestamp
            self.isFresh = isFresh
            self.generation = generation
        }
    }

    public static let sourceURL = "https://models.dev/api.json"
    public static let cacheTTL: TimeInterval = 48 * 3600 // 48 hours
    public static let didRefreshNotification = Notification.Name("ModelsDevAPIDidRefreshNotification")

    /// Enrich a `ProviderModel` with metadata from `models.dev` registry.
    /// Strict Truth Hierarchy:
    /// Enrich a model's capabilities using models.dev registry data:
    /// 1. Provider-own models.dev match (Authoritative)
    /// 2. Cross-provider models.dev fallback
    /// 3. Unknown (Zero hardcoded facts, zero name-guessing heuristics)
    public static func enrichModel(
        baseURL: String,
        appendV1Suffix: Bool,
        identity: ProviderIdentity? = nil,
        protocolAdapter: ProviderAPIFormat? = nil,
        model: ProviderModel,
        snapshot: RegistrySnapshot?
    ) -> ProviderModel {
        let oldProv = model.baseCapabilityProvenance ?? ModelCapabilityProvenance()
        var cleanProv = ModelCapabilityProvenance()

        let isCatalogDerived = model.baseMetadataSource == .modelsDevAuthoritative
            || model.baseMetadataSource == .modelsDevFallback
            || model.baseMetadataSource == .builtIn
            || model.baseMetadataSource == .inferred

        var cleanDisplayName = model.baseDisplayName
        if isCatalogDerived {
            cleanDisplayName = model.id
        }

        var cleanBase = ProviderModel(
            id: model.id,
            displayName: cleanDisplayName,
            overrides: model.overrides,
            isCustom: model.isCustom,
            isHidden: model.isHidden
        )

        cleanBase.accountContextLimit = model.accountContextLimit

        // Only an existing model that was previously stamped with official facts
        // needs its synthetic overlay cleared during refresh, so upstream models.dev
        // candidates can be resolved and compared for conflicts.
        // A freshly discovered model from /models (where capabilitySourceURL == nil)
        // must retain its provider-declared fields in cleanBase so detectOfficialFactsConflict
        // can detect conflicts with the vendor official card.
        let isGeminiTTSCandidate = (identity == .gemini && model.id == ProviderOfficialCatalog.geminiTTSModelID)
        let isPriorOfficialFactsOverlay = (model.capabilitySourceURL == ProviderOfficialCatalog.geminiSourceURL)

        if !isPriorOfficialFactsOverlay {
            cleanBase.capabilitySourceURL = model.capabilitySourceURL
            cleanBase.capabilityCatalogVersion = model.capabilityCatalogVersion
            cleanBase.officialFactsConflict = model.officialFactsConflict

            if isGeminiTTSCandidate {
                // For the specific Gemini TTS model undergoing raw discovery from /models, preserve declared fields
                // so detectOfficialFactsConflict can compare them with official vendor card facts.
                if oldProv.modality == .providerDeclaration || model.baseModality != nil {
                    cleanBase.baseModality = model.baseModality
                    cleanProv.modality = .providerDeclaration
                }
                if oldProv.contextWindow == .providerDeclaration || model.baseContextWindow != nil {
                    cleanBase.baseContextWindow = model.baseContextWindow
                    cleanProv.contextWindow = .providerDeclaration
                }
                if oldProv.maxOutputTokens == .providerDeclaration || model.baseMaxOutputTokens != nil {
                    cleanBase.baseMaxOutputTokens = model.baseMaxOutputTokens
                    cleanProv.maxOutputTokens = .providerDeclaration
                }
                if oldProv.reasoning == .providerDeclaration || model.baseSupportsReasoning != nil {
                    cleanBase.baseSupportsReasoning = model.baseSupportsReasoning
                    cleanProv.reasoning = .providerDeclaration
                }
                if oldProv.reasoningEffort == .providerDeclaration || model.reasoningEffortValues != nil {
                    cleanBase.reasoningEffortValues = model.reasoningEffortValues
                    cleanBase.declaresNoEffortTiers = model.declaresNoEffortTiers
                    cleanBase.effortDeclarationIsAuthoritative = model.effortDeclarationIsAuthoritative
                    cleanProv.reasoningEffort = .providerDeclaration
                }

                if model.baseMetadataSource == .providerDeclaration || cleanProv.contextWindow == .providerDeclaration || cleanProv.modality == .providerDeclaration {
                    cleanBase.baseMetadataSource = .providerDeclaration
                } else if isCatalogDerived {
                    cleanBase.baseMetadataSource = nil
                } else {
                    cleanBase.baseMetadataSource = model.baseMetadataSource
                }
            } else {
                // For all other models and providers, strictly preserve only fields explicitly declared
                // by the provider with .providerDeclaration provenance. Never promote unknown origins to providerDeclaration.
                if oldProv.modality == .providerDeclaration {
                    cleanBase.baseModality = model.baseModality
                    cleanProv.modality = .providerDeclaration
                }
                if oldProv.contextWindow == .providerDeclaration {
                    cleanBase.baseContextWindow = model.baseContextWindow
                    cleanProv.contextWindow = .providerDeclaration
                }
                if oldProv.maxOutputTokens == .providerDeclaration {
                    cleanBase.baseMaxOutputTokens = model.baseMaxOutputTokens
                    cleanProv.maxOutputTokens = .providerDeclaration
                }
                if oldProv.reasoning == .providerDeclaration {
                    cleanBase.baseSupportsReasoning = model.baseSupportsReasoning
                    cleanProv.reasoning = .providerDeclaration
                }
                if oldProv.reasoningEffort == .providerDeclaration {
                    cleanBase.reasoningEffortValues = model.reasoningEffortValues
                    cleanBase.declaresNoEffortTiers = model.declaresNoEffortTiers
                    cleanBase.effortDeclarationIsAuthoritative = model.effortDeclarationIsAuthoritative
                    cleanProv.reasoningEffort = .providerDeclaration
                }

                if model.baseMetadataSource == .providerDeclaration {
                    cleanBase.baseMetadataSource = .providerDeclaration
                } else if isCatalogDerived {
                    cleanBase.baseMetadataSource = nil
                } else {
                    cleanBase.baseMetadataSource = model.baseMetadataSource
                }
            }
        } else {
            // Official facts model undergoing refresh:
            // Do not treat prior synthetic overlay as immutable provider declaration.
            // Allow Stage 1 authoritative models.dev candidate fields to populate cleanBase
            // so upstream conflicts can be detected and recorded.
            cleanBase.capabilitySourceURL = nil
            cleanBase.capabilityCatalogVersion = nil
            cleanBase.officialFactsConflict = nil
            cleanBase.baseMetadataSource = nil
        }

        // Single atomic read: registry data, origin, timestamp, isFresh, generation all come from the passed snapshot!
        guard let snapshot = snapshot else {
            cleanBase.baseCapabilityProvenance = cleanProv
            if cleanBase.baseMetadataSource == nil {
                cleanBase.baseMetadataSource = cleanBase.isCustom ? .custom : .unknown
            }
            ProviderOfficialCatalog.applyOfficialFacts(to: &cleanBase, identity: identity, protocolAdapter: protocolAdapter)
            return cleanBase
        }

        let registry = snapshot.registry

        // Stage 1: Authoritative endpoint resolution (field-level truth, no arbitrary picking)
        if let authoritativeCandidates = resolveAuthoritativeDevCandidates(
            for: model.id,
            baseURL: baseURL,
            appendV1Suffix: appendV1Suffix,
            identity: identity,
            protocolAdapter: protocolAdapter,
            in: registry
        ) {
            applyAuthoritativeFieldConsensus(
                candidates: authoritativeCandidates,
                to: &cleanBase,
                prov: &cleanProv,
                originalSource: model.baseMetadataSource
            )
            ProviderOfficialCatalog.applyOfficialFacts(to: &cleanBase, identity: identity, protocolAdapter: protocolAdapter)
            return cleanBase
        }

        // Stage 2: Cross-provider models.dev fallback via pre-built index
        let index = RegistryStorage.shared.crossProviderIndex(for: snapshot)
        if let fallback = index.lookup(modelId: model.id) {
            applyIndexedCrossProviderFallback(
                fallback,
                to: &cleanBase,
                prov: &cleanProv,
                originalSource: model.baseMetadataSource
            )
            ProviderOfficialCatalog.applyOfficialFacts(to: &cleanBase, identity: identity, protocolAdapter: protocolAdapter)
            return cleanBase
        }

        // Stage 3: Unknown (Zero hardcoded facts, zero name-guessing heuristics)
        cleanBase.baseCapabilityProvenance = cleanProv
        if cleanBase.baseMetadataSource == nil {
            cleanBase.baseMetadataSource = cleanBase.isCustom ? .custom : .unknown
        }
        ProviderOfficialCatalog.applyOfficialFacts(to: &cleanBase, identity: identity, protocolAdapter: protocolAdapter)
        return cleanBase
    }

    public static func enrichModel(
        baseURL: String,
        appendV1Suffix: Bool,
        identity: ProviderIdentity? = nil,
        protocolAdapter: ProviderAPIFormat? = nil,
        model: ProviderModel
    ) -> ProviderModel {
        enrichModel(baseURL: baseURL, appendV1Suffix: appendV1Suffix, identity: identity, protocolAdapter: protocolAdapter, model: model, snapshot: loadRegistrySnapshot())
    }

    public static func enrichModel(
        baseURL: String,
        appendV1Suffix: Bool,
        model: ProviderModel,
        snapshot: RegistrySnapshot?
    ) -> ProviderModel {
        enrichModel(baseURL: baseURL, appendV1Suffix: appendV1Suffix, identity: nil, protocolAdapter: nil, model: model, snapshot: snapshot)
    }

    public static func enrichModel(
        baseURL: String,
        appendV1Suffix: Bool,
        model: ProviderModel
    ) -> ProviderModel {
        enrichModel(baseURL: baseURL, appendV1Suffix: appendV1Suffix, identity: nil, protocolAdapter: nil, model: model, snapshot: loadRegistrySnapshot())
    }

    // Compatibility overloads for tests / existing callers
    public static func enrichModel(
        baseURL: String,
        model: ProviderModel,
        snapshot: RegistrySnapshot?
    ) -> ProviderModel {
        enrichModel(baseURL: baseURL, appendV1Suffix: true, identity: nil, protocolAdapter: nil, model: model, snapshot: snapshot)
    }

    public static func enrichModel(baseURL: String, model: ProviderModel) -> ProviderModel {
        enrichModel(baseURL: baseURL, appendV1Suffix: true, identity: nil, protocolAdapter: nil, model: model, snapshot: loadRegistrySnapshot())
    }

    // MARK: - Stage 1: Authoritative Endpoint Resolution

    private static func applyAuthoritativeFieldConsensus(
        candidates: [ModelsDevModel],
        to model: inout ProviderModel,
        prov: inout ModelCapabilityProvenance,
        originalSource: ModelMetadataSource?
    ) {
        var hasAnyAuthoritative = false

        func resolveField<T: Equatable>(_ values: [T]) -> T? {
            guard let first = values.first else { return nil }
            for v in values.dropFirst() {
                if v != first { return nil }
            }
            return first
        }

        // 1. Modality
        if prov.modality != .providerDeclaration {
            let declared = candidates.compactMap { $0.resolvedModality }
            if let agreed = resolveField(declared) {
                model.baseModality = agreed
                prov.modality = .modelsDevAuthoritative
                hasAnyAuthoritative = true
            } else {
                model.baseModality = nil
                prov.modality = .unknown
            }
        }

        // 2. Context Window
        if prov.contextWindow != .providerDeclaration {
            let declared = candidates.compactMap { $0.limit?.context }.filter { $0 > 0 }
            if let agreed = resolveField(declared) {
                model.baseContextWindow = agreed
                prov.contextWindow = .modelsDevAuthoritative
                hasAnyAuthoritative = true
            } else {
                model.baseContextWindow = nil
                prov.contextWindow = .unknown
            }
        }

        // 3. Max Output Tokens
        if prov.maxOutputTokens != .providerDeclaration {
            let declared = candidates.compactMap { $0.limit?.output }.filter { $0 > 0 }
            if let agreed = resolveField(declared) {
                model.baseMaxOutputTokens = agreed
                prov.maxOutputTokens = .modelsDevAuthoritative
                hasAnyAuthoritative = true
            } else {
                model.baseMaxOutputTokens = nil
                prov.maxOutputTokens = .unknown
            }
        }

        // 4. Reasoning
        if prov.reasoning != .providerDeclaration {
            let declared = candidates.compactMap { $0.reasoning }
            if let agreed = resolveField(declared) {
                model.baseSupportsReasoning = agreed
                prov.reasoning = .modelsDevAuthoritative
                hasAnyAuthoritative = true
            } else {
                model.baseSupportsReasoning = nil
                prov.reasoning = .unknown
            }
        }

        // 5. Reasoning Effort Values
        if prov.reasoningEffort != .providerDeclaration {
            let declared = candidates.compactMap { $0.effortValues }
            if !declared.isEmpty {
                let explicitNoEffort = candidates.contains { $0.declaresNoEffortTiers }
                if explicitNoEffort {
                    model.reasoningEffortValues = nil
                    prov.reasoningEffort = .unknown
                } else if let agreed = resolveField(declared) {
                    model.reasoningEffortValues = agreed
                    prov.reasoningEffort = .modelsDevAuthoritative
                    hasAnyAuthoritative = true
                } else {
                    model.reasoningEffortValues = nil
                    prov.reasoningEffort = .unknown
                }
            } else {
                model.reasoningEffortValues = nil
                prov.reasoningEffort = .unknown
            }
        }

        // 6. Declares No Effort Tiers
        if prov.reasoningEffort != .providerDeclaration {
        let withReasoningOpts = candidates.filter { $0.reasoningOptions != nil }
        if !withReasoningOpts.isEmpty {
            let flags = withReasoningOpts.map { $0.declaresNoEffortTiers }
            if let agreed = resolveField(flags), agreed {
                model.declaresNoEffortTiers = true
                hasAnyAuthoritative = true
            } else {
                model.declaresNoEffortTiers = nil
            }
        } else {
            model.declaresNoEffortTiers = nil
        }

        }

        // 7. Interleaved Reasoning Field
        let declaredInterleaved = candidates.compactMap { $0.interleaved?.field }
        if let agreed = resolveField(declaredInterleaved) {
            model.interleavedReasoningField = agreed
            hasAnyAuthoritative = true
        } else {
            model.interleavedReasoningField = nil
        }

        // 8. Effort Declaration Authoritative & Metadata Source
        // An endpoint is authoritative for effort declaration ONLY if it explicitly and consistently declares:
        // A. agreeing effortValues (prov.reasoningEffort == .modelsDevAuthoritative), OR
        // B. agreeing declaration of no effort tiers (model.declaresNoEffortTiers == true).
        // Having context/output/modality authoritative does NOT imply effort declaration truth.
        if prov.reasoningEffort == .providerDeclaration || prov.reasoningEffort == .modelsDevAuthoritative || model.declaresNoEffortTiers == true {
            model.effortDeclarationIsAuthoritative = true
        } else {
            model.effortDeclarationIsAuthoritative = nil
        }

        if hasAnyAuthoritative {
            model.baseMetadataSource = .modelsDevAuthoritative
        } else if model.baseMetadataSource == nil {
            model.baseMetadataSource = model.isCustom ? .custom : .unknown
        }

        // 9. Display Name
        if originalSource != .providerDeclaration {
            let declaredNames = candidates.compactMap { $0.name }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let agreed = resolveField(declaredNames) {
                model.baseDisplayName = agreed
            }
        }

        model.baseCapabilityProvenance = prov
    }

    /// Normalize a model ID for matching against models.dev catalog entries.
    /// (e.g. "z-ai/glm-5.2" -> "glm-5-2", "openai/gpt-4o-mini" -> "gpt-4o-mini").
    public static func normalizedModelKey(_ id: String) -> String {
        let bare = id.split(separator: "/").last.map(String.init) ?? id
        return bare.lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    public static func authoritativeRegistryKey(
        for identity: ProviderIdentity?,
        protocolAdapter: ProviderAPIFormat?
    ) -> String? {
        guard let identity, let protocolAdapter else { return nil }
        switch (identity, protocolAdapter) {
        case (.gemini, .geminiNative):
            return "google"
        case (.openAI, .responses), (.openAI, .chatCompletions):
            return "openai"
        case (.anthropic, .anthropicMessages):
            return "anthropic"
        case (.xAI, .responses), (.xAI, .chatCompletions):
            return "xai"
        default:
            return nil
        }
    }

    public static func resolveAuthoritativeDevCandidates(
        for modelId: String,
        baseURL: String,
        appendV1Suffix: Bool,
        identity: ProviderIdentity? = nil,
        protocolAdapter: ProviderAPIFormat? = nil,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevModel]? {
        // First-party identity matching:
        // Only for .gemini -> google, .openAI -> openai, .anthropic -> anthropic, .xAI -> xai
        // on their native/official protocols and exact model ID.
        if let regKey = authoritativeRegistryKey(for: identity, protocolAdapter: protocolAdapter),
           let provider = registry[regKey] {
            if let direct = provider.models[modelId] {
                return [direct]
            }
            return nil
        }

        let matchingProviders = findMatchingProviders(forBaseURL: baseURL, appendV1Suffix: appendV1Suffix, in: registry)
        guard !matchingProviders.isEmpty else { return nil }

        // 1. Exact model ID check across all matching providers (strict byte-for-byte equality)
        var exactCandidates: [ModelsDevModel] = []
        for provider in matchingProviders {
            if let direct = provider.models[modelId] {
                exactCandidates.append(direct)
            }
        }
        if !exactCandidates.isEmpty {
            return exactCandidates
        }

        // 2. Normalized alias check across all matching providers
        let wanted = normalizedModelKey(modelId)
        var aliasCandidates: [ModelsDevModel] = []
        for provider in matchingProviders {
            for id in provider.models.keys.sorted() {
                if normalizedModelKey(id) == wanted, let m = provider.models[id] {
                    aliasCandidates.append(m)
                }
            }
        }
        if !aliasCandidates.isEmpty {
            return aliasCandidates
        }

        return nil
    }

    public static func resolveAuthoritativeDevCandidates(
        for modelId: String,
        baseURL: String,
        appendV1Suffix: Bool,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevModel]? {
        resolveAuthoritativeDevCandidates(for: modelId, baseURL: baseURL, appendV1Suffix: appendV1Suffix, identity: nil, protocolAdapter: nil, in: registry)
    }

    public static func resolveAuthoritativeDevCandidates(
        for modelId: String,
        baseURL: String,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevModel]? {
        resolveAuthoritativeDevCandidates(for: modelId, baseURL: baseURL, appendV1Suffix: true, identity: nil, protocolAdapter: nil, in: registry)
    }

    // MARK: - Cross-Provider Resolution Index & Fallback Models

    public struct ResolvedCrossProviderFallback: Sendable {
        public let modality: ModelModality?
        public let contextWindow: Int?
        public let maxOutputTokens: Int?
        public let supportsReasoning: Bool?
        public let reasoningEffortValues: [String]?
        public let declaresNoEffortTiers: Bool?
        public let interleavedReasoningField: String?
        public let displayName: String?

        public init(
            modality: ModelModality? = nil,
            contextWindow: Int? = nil,
            maxOutputTokens: Int? = nil,
            supportsReasoning: Bool? = nil,
            reasoningEffortValues: [String]? = nil,
            declaresNoEffortTiers: Bool? = nil,
            interleavedReasoningField: String? = nil,
            displayName: String? = nil
        ) {
            self.modality = modality
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
            self.supportsReasoning = supportsReasoning
            self.reasoningEffortValues = reasoningEffortValues
            self.declaresNoEffortTiers = declaresNoEffortTiers
            self.interleavedReasoningField = interleavedReasoningField
            self.displayName = displayName
        }

        public var hasAnyFallback: Bool {
            modality != nil ||
            contextWindow != nil ||
            maxOutputTokens != nil ||
            supportsReasoning != nil ||
            reasoningEffortValues != nil ||
            declaresNoEffortTiers != nil ||
            interleavedReasoningField != nil
        }
    }

    public final class CrossProviderIndex: @unchecked Sendable {
        public let generation: UInt64
        private let fallbacks: [String: ResolvedCrossProviderFallback]

        public init(generation: UInt64, fallbacks: [String: ResolvedCrossProviderFallback]) {
            self.generation = generation
            self.fallbacks = fallbacks
        }

        public func lookup(modelId: String) -> ResolvedCrossProviderFallback? {
            let key = ModelsDevAPI.normalizedModelKey(modelId)
            return fallbacks[key]
        }

        public func lookup(normalizedKey: String) -> ResolvedCrossProviderFallback? {
            return fallbacks[normalizedKey]
        }
    }

    /// Within a single provider, resolves whether all declared non-nil alias values agree.
    /// If all declared values match, returns that unique value (1 vote).
    /// If there is an internal conflict between aliases, returns `nil` (the provider abstains on this field).
    public static func uniqueConsensusWithinProvider<T: Equatable>(from values: [T]) -> T? {
        guard let first = values.first else { return nil }
        for v in values.dropFirst() {
            if v != first { return nil }
        }
        return first
    }

    /// Generic consensus policy: evaluates declared field values across candidates.
    /// Independent Evidence Quorum: requires at least 2 independent provider declarations.
    /// Strict majority: candidate count must strictly exceed 50% of declaring candidates.
    /// Any tie or disagreement without strict majority returns `nil` (Unknown).
    /// Pure function: result depends only on the frequency multiset, completely independent of candidate/provider ordering.
    public static func resolveConsensus<T: Hashable>(from values: [T]) -> T? {
        guard values.count >= 2 else { return nil }
        var counts: [T: Int] = [:]
        for v in values {
            counts[v, default: 0] += 1
        }
        let total = values.count
        guard let (winner, winnerCount) = counts.max(by: { $0.value < $1.value }) else {
            return nil
        }
        // Strict majority requirement: winner must strictly exceed half of all declaring candidates
        guard winnerCount * 2 > total else {
            return nil
        }
        return winner
    }

    public static func buildCrossProviderIndex(
        for registry: [String: ModelsDevProvider],
        generation: UInt64
    ) -> CrossProviderIndex {
        var grouped: [String: [String: [ModelsDevModel]]] = [:]

        for (provKey, provider) in registry {
            let providerId = provider.id.isEmpty ? provKey : provider.id
            for (modelId, devModel) in provider.models {
                let normKey = normalizedModelKey(modelId)
                grouped[normKey, default: [:]][providerId, default: []].append(devModel)
            }
        }

        var fallbacks: [String: ResolvedCrossProviderFallback] = [:]
        fallbacks.reserveCapacity(grouped.count)

        for (normKey, providerMap) in grouped {
            guard providerMap.count >= 2 else {
                fallbacks[normKey] = ResolvedCrossProviderFallback(
                    modality: nil,
                    contextWindow: nil,
                    maxOutputTokens: nil,
                    supportsReasoning: nil,
                    reasoningEffortValues: nil,
                    declaresNoEffortTiers: nil,
                    interleavedReasoningField: nil,
                    displayName: nil
                )
                continue
            }

            var modalityVotes: [ModelModality] = []
            var contextVotes: [Int] = []
            var outputVotes: [Int] = []
            var reasoningVotes: [Bool] = []
            var effortVotes: [[String]] = []
            var noEffortFlags: [Bool] = []
            var interleavedVotes: [String] = []
            var displayNameVotes: [String] = []

            for (_, providerModels) in providerMap {
                // 1. Modality
                let declaredMods = providerModels.compactMap { $0.resolvedModality }
                if let v = uniqueConsensusWithinProvider(from: declaredMods) {
                    modalityVotes.append(v)
                }

                // 2. Context Window
                let declaredContexts = providerModels.compactMap { $0.limit?.context }.filter { $0 > 0 }
                if let v = uniqueConsensusWithinProvider(from: declaredContexts) {
                    contextVotes.append(v)
                }

                // 3. Max Output Tokens
                let declaredOutputs = providerModels.compactMap { $0.limit?.output }.filter { $0 > 0 }
                if let v = uniqueConsensusWithinProvider(from: declaredOutputs) {
                    outputVotes.append(v)
                }

                // 4. Reasoning
                let declaredReasoning = providerModels.compactMap { $0.reasoning }
                if let v = uniqueConsensusWithinProvider(from: declaredReasoning) {
                    reasoningVotes.append(v)
                }

                // 5. Reasoning Effort Values
                let declaredEfforts = providerModels.compactMap { $0.effortValues }
                if let v = uniqueConsensusWithinProvider(from: declaredEfforts) {
                    effortVotes.append(v)
                }

                // 6. Declares No Effort Tiers
                let withReasoningOpts = providerModels.filter { $0.reasoningOptions != nil }
                if !withReasoningOpts.isEmpty {
                    let flags = withReasoningOpts.map { $0.declaresNoEffortTiers }
                    if let v = uniqueConsensusWithinProvider(from: flags) {
                        noEffortFlags.append(v)
                    }
                }

                // 7. Interleaved Reasoning Field
                let declaredInterleaved = providerModels.compactMap { $0.interleaved?.field }
                if let v = uniqueConsensusWithinProvider(from: declaredInterleaved) {
                    interleavedVotes.append(v)
                }

                // 8. Display Name
                let declaredNames = providerModels.compactMap { $0.name }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let v = uniqueConsensusWithinProvider(from: declaredNames) {
                    displayNameVotes.append(v)
                }
            }

            let resModality = resolveConsensus(from: modalityVotes)
            let resContext = resolveConsensus(from: contextVotes)
            let resOutput = resolveConsensus(from: outputVotes)
            let resReasoning = resolveConsensus(from: reasoningVotes)
            let resEffort = resolveConsensus(from: effortVotes)
            let resNoEffort: Bool? = {
                if let consensus = resolveConsensus(from: noEffortFlags), consensus {
                    return true
                }
                return nil
            }()
            let resInterleaved = resolveConsensus(from: interleavedVotes)
            let resDisplayName = resolveConsensus(from: displayNameVotes)

            fallbacks[normKey] = ResolvedCrossProviderFallback(
                modality: resModality,
                contextWindow: resContext,
                maxOutputTokens: resOutput,
                supportsReasoning: resReasoning,
                reasoningEffortValues: resEffort,
                declaresNoEffortTiers: resNoEffort,
                interleavedReasoningField: resInterleaved,
                displayName: resDisplayName
            )
        }

        return CrossProviderIndex(generation: generation, fallbacks: fallbacks)
    }

    public static func collectCrossProviderDevModels(
        for modelId: String,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevModel] {
        let wanted = normalizedModelKey(modelId)

        var candidates: [ModelsDevModel] = []
        for key in registry.keys.sorted() {
            guard let prov = registry[key] else { continue }
            for id in prov.models.keys.sorted() {
                if normalizedModelKey(id) == wanted {
                    if let devModel = prov.models[id] {
                        candidates.append(devModel)
                    }
                }
            }
        }
        return candidates
    }

    private static func applyIndexedCrossProviderFallback(
        _ fallback: ResolvedCrossProviderFallback,
        to model: inout ProviderModel,
        prov: inout ModelCapabilityProvenance,
        originalSource: ModelMetadataSource?
    ) {
        var hasAnyFallback = false

        // 1. Modality
        if prov.modality != .providerDeclaration {
            if let mod = fallback.modality {
                model.baseModality = mod
                prov.modality = .modelsDevFallback
                hasAnyFallback = true
            } else {
                model.baseModality = nil
                prov.modality = .unknown
            }
        }

        // 2. Context Window
        if prov.contextWindow != .providerDeclaration {
            if let ctx = fallback.contextWindow, ctx > 0 {
                model.baseContextWindow = ctx
                prov.contextWindow = .modelsDevFallback
                hasAnyFallback = true
            } else {
                model.baseContextWindow = nil
                prov.contextWindow = .unknown
            }
        }

        // 3. Max Output Tokens
        if prov.maxOutputTokens != .providerDeclaration {
            if let out = fallback.maxOutputTokens, out > 0 {
                model.baseMaxOutputTokens = out
                prov.maxOutputTokens = .modelsDevFallback
                hasAnyFallback = true
            } else {
                model.baseMaxOutputTokens = nil
                prov.maxOutputTokens = .unknown
            }
        }

        // 4. Reasoning
        if prov.reasoning != .providerDeclaration {
            if let rea = fallback.supportsReasoning {
                model.baseSupportsReasoning = rea
                prov.reasoning = .modelsDevFallback
                hasAnyFallback = true
            } else {
                model.baseSupportsReasoning = nil
                prov.reasoning = .unknown
            }
        }

        // 5. Reasoning Effort Values
        if prov.reasoningEffort != .providerDeclaration {
            if let eff = fallback.reasoningEffortValues {
                model.reasoningEffortValues = eff
                prov.reasoningEffort = .modelsDevFallback
                hasAnyFallback = true
            } else {
                model.reasoningEffortValues = nil
                prov.reasoningEffort = .unknown
            }
        }

        // 6. Declares No Effort Tiers
        if let noEff = fallback.declaresNoEffortTiers {
            model.declaresNoEffortTiers = noEff
            hasAnyFallback = true
        } else {
            model.declaresNoEffortTiers = nil
        }

        // 7. Interleaved Reasoning Field
        if let inter = fallback.interleavedReasoningField {
            model.interleavedReasoningField = inter
            hasAnyFallback = true
        } else {
            model.interleavedReasoningField = nil
        }

        // 8. Cross-provider fallback is NEVER authoritative
        model.effortDeclarationIsAuthoritative = nil

        // 9. Display Name
        if originalSource != .providerDeclaration {
            if let name = fallback.displayName {
                model.baseDisplayName = name
            }
        }

        if hasAnyFallback {
            model.baseMetadataSource = .modelsDevFallback
        } else if model.baseMetadataSource == nil {
            model.baseMetadataSource = model.isCustom ? .custom : .unknown
        }

        model.baseCapabilityProvenance = prov
    }

    /// Structured canonical endpoint normalization.
    /// Normalizes percent-escape hex digits to uppercase (%2f -> %2F) without decoding reserved characters.
    public static func normalizePercentEncodingHex(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        var idx = string.startIndex
        while idx < string.endIndex {
            if string[idx] == "%" {
                let next1 = string.index(after: idx)
                if next1 < string.endIndex {
                    let next2 = string.index(after: next1)
                    if next2 < string.endIndex {
                        let c1 = string[next1]
                        let c2 = string[next2]
                        if c1.isHexDigit && c2.isHexDigit {
                            result.append("%")
                            result.append(Character(String(c1).uppercased()))
                            result.append(Character(String(c2).uppercased()))
                            idx = string.index(after: next2)
                            continue
                        }
                    }
                }
            }
            result.append(string[idx])
            idx = string.index(after: idx)
        }
        return result
    }

    /// Wire-equivalent endpoint canonicalization aligning with EndpointBuilder semantics:
    /// - Requires explicit http / https scheme (no guessing https for missing scheme).
    /// - Normalizes scheme (lowercased) and host (lowercased).
    /// - Normalizes default ports (https:443 -> default, http:80 -> default) while keeping non-default ports distinct.
    /// - Ignores HTTP fragment (fragment is not sent to server over wire).
    /// - Preserves raw percent-encoded path identity (percentEncodedPath, %2F != /).
    /// - Normalizes percent-escape hex casing (%2f -> %2F) without decoding reserved characters.
    /// - Preserves query identity conservatively (percentEncodedQuery).
    /// - Conditional /v1 suffix equivalence: ONLY when appendV1Suffix is true.
    public static func canonicalEndpointVariants(
        for urlString: String,
        appendV1Suffix: Bool = false
    ) -> Set<String> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return []
        }

        var base = URLComponents()
        base.scheme = scheme
        base.host = host

        // Default port normalization: strip default 443 for https, 80 for http
        if let port = components.port {
            if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) {
                base.port = nil
            } else {
                base.port = port
            }
        }
        base.percentEncodedUser = components.percentEncodedUser
        base.percentEncodedPassword = components.percentEncodedPassword

        // Normalize encoded path: strip trailing slash while strictly preserving character & percent casing
        var rawEncodedPath = normalizePercentEncodingHex(components.percentEncodedPath)
        while rawEncodedPath.count > 1 && rawEncodedPath.hasSuffix("/") {
            rawEncodedPath.removeLast()
        }
        if rawEncodedPath == "/" {
            rawEncodedPath = ""
        }

        // Conditional /v1 suffix equivalence: only when appendV1Suffix == true
        var pathVariants: [String] = [rawEncodedPath]
        if appendV1Suffix {
            if rawEncodedPath.hasSuffix("/v1") {
                let withoutV1 = String(rawEncodedPath.dropLast(3))
                pathVariants.append(withoutV1)
            } else {
                pathVariants.append(rawEncodedPath + "/v1")
            }
        }

        var results = Set<String>()
        for p in pathVariants {
            var c = base
            c.percentEncodedPath = p
            if let q = components.percentEncodedQuery {
                c.percentEncodedQuery = normalizePercentEncodingHex(q)
            }
            // Fragment is deliberately omitted (ignored)
            if let str = c.string {
                results.insert(str)
            }
        }
        return results
    }

    public static func findMatchingProviders(
        forBaseURL baseURL: String,
        appendV1Suffix: Bool,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevProvider] {
        let baseVariants = canonicalEndpointVariants(for: baseURL, appendV1Suffix: appendV1Suffix)
        guard !baseVariants.isEmpty else { return [] }

        var matched: [ModelsDevProvider] = []
        for key in registry.keys.sorted() {
            guard let provider = registry[key], let api = provider.api, !api.isEmpty else { continue }
            // Registry API is external declaration: never assume or guess append behavior
            let providerVariants = canonicalEndpointVariants(for: api, appendV1Suffix: false)
            if !baseVariants.isDisjoint(with: providerVariants) {
                matched.append(provider)
            }
        }
        return matched
    }

    public static func findMatchingProviders(
        forBaseURL baseURL: String,
        in registry: [String: ModelsDevProvider]
    ) -> [ModelsDevProvider] {
        findMatchingProviders(forBaseURL: baseURL, appendV1Suffix: true, in: registry)
    }


    // MARK: - Registry Loading & Thread-Safe Caching

    fileprivate final class RegistryStorage: @unchecked Sendable {
        static let shared = RegistryStorage()
        private let lock = NSLock()
        private var storage: [String: ModelsDevProvider]?
        private var timestamp: Date?
        private var origin: RegistryOrigin = .bundled
        private var generation: UInt64 = 0
        private var isRefreshing: Bool = false
        var customDiskCacheURL: URL?
        var customNetworkFetcher: (@Sendable (URL) async throws -> (Data, URLResponse))?

        func currentSnapshot() -> RegistrySnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let s = storage, let t = timestamp else { return nil }
            let fresh: Bool
            switch origin {
            case .test:
                fresh = true
            case .network:
                fresh = Date().timeIntervalSince(t) < ModelsDevAPI.cacheTTL
            case .diskCache:
                fresh = Date().timeIntervalSince(t) < ModelsDevAPI.cacheTTL
            case .bundled:
                fresh = false
            }
            return RegistrySnapshot(
                registry: s,
                origin: origin,
                timestamp: t,
                isFresh: fresh,
                generation: generation
            )
        }

        var currentGeneration: UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return generation
        }

        private var snapshotAcquisitions: Int = 0

        func recordSnapshotAcquisition() {
            lock.lock()
            defer { lock.unlock() }
            snapshotAcquisitions += 1
        }

        var snapshotAcquisitionCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return snapshotAcquisitions
        }

        func resetSnapshotAcquisitionCount() {
            lock.lock()
            defer { lock.unlock() }
            snapshotAcquisitions = 0
        }

        private func freshnessScore(origin: RegistryOrigin, timestamp: Date?) -> Int {
            guard let t = timestamp else { return 0 }
            let isFresh: Bool
            switch origin {
            case .test:
                isFresh = true
            case .network, .diskCache:
                isFresh = Date().timeIntervalSince(t) < ModelsDevAPI.cacheTTL
            case .bundled:
                isFresh = false
            }

            switch origin {
            case .test:
                return 50
            case .network:
                return isFresh ? 40 : 10
            case .diskCache:
                return isFresh ? 30 : 10
            case .bundled:
                return 20
            }
        }

        @discardableResult
        func commit(
            _ value: [String: ModelsDevProvider],
            timestamp: Date,
            origin: RegistryOrigin,
            expectedGeneration: UInt64? = nil
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            let currentScore = (storage != nil) ? freshnessScore(origin: self.origin, timestamp: self.timestamp) : 0
            let newScore = freshnessScore(origin: origin, timestamp: timestamp)

            // Invariant 1: Freshness downgrade is strictly prohibited
            if newScore < currentScore {
                return false
            }

            // Invariant 2: If expected generation is provided and scores are equal,
            // reject stale concurrent writes
            if let expectedGen = expectedGeneration, newScore == currentScore, generation != expectedGen {
                return false
            }

            storage = value
            self.timestamp = timestamp
            self.origin = origin
            generation &+= 1
            return true
        }

        private var cachedIndex: CrossProviderIndex?
        private var indexBuilds: Int = 0

        func crossProviderIndex(for snapshot: RegistrySnapshot) -> CrossProviderIndex {
            lock.lock()
            defer { lock.unlock() }

            if let cached = cachedIndex, cached.generation == snapshot.generation {
                return cached
            }

            let newIndex = ModelsDevAPI.buildCrossProviderIndex(for: snapshot.registry, generation: snapshot.generation)
            if newIndex.generation >= (cachedIndex?.generation ?? 0) {
                cachedIndex = newIndex
            }
            indexBuilds += 1
            return newIndex
        }

        var indexBuildCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return indexBuilds
        }

        func resetIndexBuildCount() {
            lock.lock()
            defer { lock.unlock() }
            indexBuilds = 0
        }

        func forceSet(_ value: [String: ModelsDevProvider]?, timestamp: Date = Date(), origin: RegistryOrigin = .bundled) {
            lock.lock()
            defer { lock.unlock() }
            storage = value
            self.timestamp = timestamp
            self.origin = origin
            generation &+= 1
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            storage = nil
            timestamp = nil
            origin = .bundled
            generation &+= 1
            isRefreshing = false
            cachedIndex = nil
        }

        private var refreshWaiters: [CheckedContinuation<Bool, Never>] = []

        func beginRefresh() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isRefreshing else { return false }
            isRefreshing = true
            return true
        }

        func waitForCurrentRefresh() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !isRefreshing {
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    refreshWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func endRefresh(success: Bool) {
            lock.lock()
            isRefreshing = false
            let waiters = refreshWaiters
            refreshWaiters.removeAll()
            lock.unlock()
            for w in waiters {
                w.resume(returning: success)
            }
        }
    }

    public static var cacheFileURL: URL {
        if let custom = RegistryStorage.shared.customDiskCacheURL {
            return custom
        }
        let caches = LimareStorage.caches
        return caches.appendingPathComponent(LimareStorage.bundleIdentifier)
            .appendingPathComponent("models-dev-cache")
            .appendingPathComponent("api.json")
    }

    private static func loadDiskCache() -> (Data, Date)? {
        let url = cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return (data, modified)
    }

    private static func saveDiskCache(_ data: Data) {
        let url = cacheFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func loadBundledRegistry() -> [String: ModelsDevProvider]? {
        // 1. Bundle resource
        if let url = Bundle.main.url(forResource: "models-dev-api", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let parsed = parseRegistry(data) {
            return parsed
        }

        // 2. Relative file fallback (for test runners and debug builds)
        let candidates = [
            "src/macos/Limare/Resources/models-dev-api.json",
            "../src/macos/Limare/Resources/models-dev-api.json",
            "../../src/macos/Limare/Resources/models-dev-api.json",
            "Resources/models-dev-api.json"
        ]
        for path in candidates {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let parsed = parseRegistry(data) {
                return parsed
            }
        }

        return nil
    }

    public static func loadRegistrySnapshot() -> RegistrySnapshot? {
        RegistryStorage.shared.recordSnapshotAcquisition()

        // 1. In-memory snapshot: if already fresh or if already bundled fallback, return immediately
        if let current = RegistryStorage.shared.currentSnapshot() {
            if current.isFresh {
                return current
            }
            if current.origin == .bundled {
                scheduleBackgroundRefresh()
                return current
            }
        }

        let baseGen = RegistryStorage.shared.currentGeneration

        // 2. Disk cache
        if let (diskData, diskDate) = loadDiskCache() {
            let isFresh = Date().timeIntervalSince(diskDate) < cacheTTL
            if isFresh, let parsed = parseRegistry(diskData) {
                let committed = RegistryStorage.shared.commit(
                    parsed,
                    timestamp: diskDate,
                    origin: .diskCache,
                    expectedGeneration: baseGen
                )
                if committed, let snapshot = RegistryStorage.shared.currentSnapshot(), snapshot.isFresh {
                    return snapshot
                }
            } else {
                // Disk cache is expired: do NOT treat as fresh, schedule background refresh
                scheduleBackgroundRefresh()
            }
        } else {
            // No disk cache: schedule background refresh
            scheduleBackgroundRefresh()
        }

        // 3. Bundled fallback
        if let bundled = loadBundledRegistry() {
            RegistryStorage.shared.commit(
                bundled,
                timestamp: Date.distantPast,
                origin: .bundled,
                expectedGeneration: baseGen
            )
        }

        return RegistryStorage.shared.currentSnapshot()
    }

    public static func loadRegistry() -> [String: ModelsDevProvider]? {
        loadRegistrySnapshot()?.registry
    }

    public static func currentSnapshot() -> RegistrySnapshot? {
        RegistryStorage.shared.currentSnapshot()
    }

    public static var currentRegistryOrigin: RegistryOrigin {
        RegistryStorage.shared.currentSnapshot()?.origin ?? .bundled
    }

    public static var currentGeneration: UInt64 {
        RegistryStorage.shared.currentGeneration
    }

    public static var snapshotAcquisitionCount: Int {
        RegistryStorage.shared.snapshotAcquisitionCount
    }

    public static func resetSnapshotAcquisitionCount() {
        RegistryStorage.shared.resetSnapshotAcquisitionCount()
    }

    public static var indexBuildCount: Int {
        RegistryStorage.shared.indexBuildCount
    }

    public static func resetIndexBuildCount() {
        RegistryStorage.shared.resetIndexBuildCount()
    }

    public static func crossProviderIndex(for snapshot: RegistrySnapshot) -> CrossProviderIndex {
        RegistryStorage.shared.crossProviderIndex(for: snapshot)
    }

    @discardableResult
    public static func startFreshnessLifecycle() -> RegistrySnapshot? {
        let snapshot = loadRegistrySnapshot()
        if snapshot?.isFresh != true {
            scheduleBackgroundRefresh()
        }
        return snapshot
    }

    public static func scheduleBackgroundRefresh() {
        guard RegistryStorage.shared.beginRefresh() else { return }
        Task.detached(priority: .utility) {
            _ = await refreshRegistryInternal()
        }
    }

    @discardableResult
    public static func refreshRegistry() async -> Bool {
        if RegistryStorage.shared.beginRefresh() {
            return await refreshRegistryInternal()
        } else {
            return await RegistryStorage.shared.waitForCurrentRefresh()
        }
    }

    private static func refreshRegistryInternal() async -> Bool {
        var success = false
        defer { RegistryStorage.shared.endRefresh(success: success) }
        do {
            guard let url = URL(string: sourceURL) else { return false }
            let data: Data
            let response: URLResponse

            if let customFetcher = RegistryStorage.shared.customNetworkFetcher {
                (data, response) = try await customFetcher(url)
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                (data, response) = try await URLSession.shared.data(for: request)
            }

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return false
            }

            guard let parsed = parseRegistry(data) else {
                return false
            }

            let committed = RegistryStorage.shared.commit(parsed, timestamp: Date(), origin: .network)
            if committed {
                saveDiskCache(data)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: didRefreshNotification, object: nil)
                }
                success = true
                return true
            } else {
                return false
            }
        } catch {
            return false
        }
    }

    public static func setTestRegistry(_ registry: [String: Any], origin: RegistryOrigin = .test, timestamp: Date = Date()) {
        if let data = try? JSONSerialization.data(withJSONObject: registry),
           let parsed = parseRegistry(data) {
            RegistryStorage.shared.forceSet(parsed, timestamp: timestamp, origin: origin)
            NotificationCenter.default.post(name: didRefreshNotification, object: nil)
        }
    }

    public static func setCustomDiskCacheURL(_ url: URL?) {
        RegistryStorage.shared.customDiskCacheURL = url
    }

    public static func setCustomNetworkFetcher(_ fetcher: (@Sendable (URL) async throws -> (Data, URLResponse))?) {
        RegistryStorage.shared.customNetworkFetcher = fetcher
    }

    public static func clearRegistryCache() {
        RegistryStorage.shared.clear()
    }

    private static func parseRegistry(_ data: Data) -> [String: ModelsDevProvider]? {
        try? JSONDecoder().decode([String: ModelsDevProvider].self, from: data)
    }
}

// MARK: - ModelsDev JSON Data Models

public struct ModelsDevProvider: Decodable, Sendable {
    public let id: String
    public let name: String?
    public let api: String?
    public let models: [String: ModelsDevModel]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        api = try container.decodeIfPresent(String.self, forKey: .api)
        models = try container.decodeIfPresent([String: ModelsDevModel].self, forKey: .models) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, api, models
    }
}

public struct ModelsDevModel: Decodable, Sendable {
    public let id: String
    public let name: String?
    public let reasoning: Bool?
    public let limit: ModelsDevLimit?
    public let modalities: ModelsDevModalities?
    public let reasoningOptions: [ModelsDevReasoningOption]?
    public let interleaved: ModelsDevInterleaved?

    private enum CodingKeys: String, CodingKey {
        case id, name, reasoning, limit, modalities
        case reasoningOptions = "reasoning_options"
        case interleaved
    }

    public var resolvedModality: ModelModality? {
        guard let m = modalities else { return nil }
        var mod: ModelModality = []
        if let inp = m.input {
            if inp.contains("text") { mod.insert(.textInput) }
            if inp.contains("image") { mod.insert(.imageInput) }
            if inp.contains("pdf") { mod.insert(.pdfInput) }
            if inp.contains("audio") { mod.insert(.audioInput) }
            if inp.contains("video") { mod.insert(.videoInput) }
        }
        if let out = m.output {
            if out.contains("text") { mod.insert(.textOutput) }
            if out.contains("image") { mod.insert(.imageOutput) }
            if out.contains("audio") { mod.insert(.audioOutput) }
            if out.contains("video") { mod.insert(.videoOutput) }
        }
        return mod.isEmpty ? nil : mod
    }

    public var effortValues: [String]? {
        guard let opts = reasoningOptions else { return nil }
        for opt in opts {
            if opt.type?.lowercased() == "effort", let vals = opt.values, !vals.isEmpty {
                return vals.map { $0.lowercased() }
            }
        }
        return nil
    }

    public var declaresNoEffortTiers: Bool {
        guard reasoningOptions != nil else { return false }
        return effortValues == nil
    }
}

public struct ModelsDevLimit: Decodable, Sendable {
    public let context: Int?
    public let output: Int?
}

public struct ModelsDevModalities: Decodable, Sendable {
    public let input: [String]?
    public let output: [String]?
}

public struct ModelsDevReasoningOption: Decodable, Sendable {
    public let type: String?
    public let values: [String]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        if let raw = try container.decodeIfPresent([String?].self, forKey: .values) {
            values = raw.compactMap { $0 }
        } else {
            values = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, values
    }

    public init(type: String?, values: [String]?) {
        self.type = type
        self.values = values
    }
}

public struct ModelsDevInterleaved: Decodable, Sendable {
    public let field: String?

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            field = try? container.decodeIfPresent(String.self, forKey: .field)
        } else {
            field = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case field
    }

    public init(field: String?) {
        self.field = field
    }
}

public typealias RegistrySnapshot = ModelsDevAPI.RegistrySnapshot
public typealias RegistryOrigin = ModelsDevAPI.RegistryOrigin
