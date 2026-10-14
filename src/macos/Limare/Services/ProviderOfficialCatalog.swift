import Foundation

/// Model declarations from the vendor's published third-party API contract, not account entitlements.
enum ProviderOfficialCatalog {
    static let kimiSourceURL = "https://www.kimi.com/code/docs/en/kimi-code/models.html"
    static let kimiVersion = "2026-10-08"

    static var kimiModels: [ProviderModel] {
        [
            model("k3", "K3", context: 1_048_576, video: true, efforts: ["low", "high", "max"], accountLimit: 262_144),
            model("k3-256k", "K3 · 256K", context: 262_144, video: false, efforts: ["low", "high", "max"]),
            model("kimi-for-coding", "K2.8 Preview", context: 1_048_576, video: true, efforts: ["low", "high", "max"]),
            model("kimi-for-coding-highspeed", "K2.7 Code HighSpeed", context: 262_144, video: true, efforts: [])
        ]
    }

    private static func model(_ id: String, _ name: String, context: Int, video: Bool,
                              efforts: [String], accountLimit: Int? = nil) -> ProviderModel {
        var modalities: ModelModality = [.textInput, .textOutput, .imageInput]
        if video { modalities.insert(.videoInput) }
        var value = ProviderModel(id: id, displayName: name, baseModality: modalities,
            baseContextWindow: context, baseSupportsReasoning: true, reasoningEffortValues: efforts,
            interleavedReasoningField: "reasoning_content", declaresNoEffortTiers: efforts.isEmpty,
            effortDeclarationIsAuthoritative: true, baseMetadataSource: .providerDeclaration)
        value.accountContextLimit = accountLimit
        value.capabilitySourceURL = kimiSourceURL
        value.capabilityCatalogVersion = kimiVersion
        return value
    }

    static func mergeKimi(existing: [ProviderModel]) -> [ProviderModel] {
        let current = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let official = kimiModels.map { declared -> ProviderModel in
            var result = declared
            if let old = current[declared.id] {
                result.overrides = old.overrides
                result.isHidden = old.isHidden
                result.discovery = old.discovery
            }
            return result
        }
        let ids = Set(official.map(\.id))
        return official + existing.filter { !ids.contains($0.id) && $0.isCustom }
    }

    // MARK: - Google Gemini Official Declarations

    static let geminiSourceURL = "https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash-tts"
    static let geminiCatalogVersion = "2026-10-10"
    static let geminiTTSModelID = "gemini-3.8-flash-tts"

    static var gemini38TTSModel: ProviderModel {
        var value = ProviderModel(
            id: geminiTTSModelID,
            displayName: "Gemini 3.8 Flash TTS",
            baseModality: [.textInput, .audioOutput],
            baseContextWindow: 8_192,
            baseMaxOutputTokens: 16_384,
            baseSupportsReasoning: false,
            reasoningEffortValues: [],
            declaresNoEffortTiers: true,
            effortDeclarationIsAuthoritative: true,
            baseMetadataSource: .providerDeclaration
        )
        value.baseCapabilityProvenance = ModelCapabilityProvenance(
            modality: .providerDeclaration,
            contextWindow: .providerDeclaration,
            maxOutputTokens: .providerDeclaration,
            reasoning: .providerDeclaration,
            reasoningEffort: .providerDeclaration
        )
        value.capabilitySourceURL = geminiSourceURL
        value.capabilityCatalogVersion = geminiCatalogVersion
        return value
    }

    /// Detects conflicts between upstream provider declaration / authoritative models.dev facts and official vendor card facts.
    public static func detectOfficialFactsConflict(
        model: ProviderModel,
        identity: ProviderIdentity?
    ) -> String? {
        let effectiveIdentity = identity ?? (model.capabilitySourceURL == geminiSourceURL ? .gemini : nil)
        guard effectiveIdentity == .gemini, model.id == geminiTTSModelID else { return nil }
        let official = gemini38TTSModel
        var conflicts: [String] = []

        // Authoritative sources: same-provider models.dev match, or direct provider declaration from /models API (not yet marked with our official URL)
        let isAuthoritativeUpstream = (model.baseCapabilityProvenance?.modality == .modelsDevAuthoritative) ||
            (model.baseCapabilityProvenance?.contextWindow == .modelsDevAuthoritative) ||
            (model.baseCapabilityProvenance?.reasoning == .modelsDevAuthoritative) ||
            (model.baseMetadataSource == .modelsDevAuthoritative) ||
            (model.baseMetadataSource == .providerDeclaration && model.capabilitySourceURL != official.capabilitySourceURL) ||
            (model.baseCapabilityProvenance?.contextWindow == .providerDeclaration && model.capabilitySourceURL != official.capabilitySourceURL) ||
            (model.baseCapabilityProvenance?.modality == .providerDeclaration && model.capabilitySourceURL != official.capabilitySourceURL) ||
            (model.baseCapabilityProvenance?.maxOutputTokens == .providerDeclaration && model.capabilitySourceURL != official.capabilitySourceURL) ||
            (model.baseCapabilityProvenance?.reasoning == .providerDeclaration && model.capabilitySourceURL != official.capabilitySourceURL)

        guard isAuthoritativeUpstream else { return nil }

        if let incomingModality = model.baseModality, incomingModality != official.baseModality {
            conflicts.append("Modality upstream (\(incomingModality)) conflicts with official facts (\(official.baseModality!))")
        }
        if let incomingContext = model.baseContextWindow, incomingContext > 0, incomingContext != official.baseContextWindow {
            conflicts.append("Context window upstream (\(incomingContext)) conflicts with official facts (\(official.baseContextWindow!))")
        }
        if let incomingMaxOutput = model.baseMaxOutputTokens, incomingMaxOutput > 0, incomingMaxOutput != official.baseMaxOutputTokens {
            conflicts.append("Max output tokens upstream (\(incomingMaxOutput)) conflicts with official facts (\(official.baseMaxOutputTokens!))")
        }
        if let incomingReasoning = model.baseSupportsReasoning, incomingReasoning != official.baseSupportsReasoning {
            conflicts.append("Reasoning support upstream (\(incomingReasoning)) conflicts with official facts (\(official.baseSupportsReasoning!))")
        }

        return conflicts.isEmpty ? nil : conflicts.joined(separator: "; ")
    }

    /// Overlays vendor official catalog facts on top of generic discovery metadata
    /// without pruning or altering other discovered models.
    /// If upstream same-provider catalog entries conflict with official facts,
    /// blocks automatic overwrite and records the conflict.
    public static func applyOfficialFacts(
        to model: inout ProviderModel,
        identity: ProviderIdentity?,
        protocolAdapter: ProviderAPIFormat? = nil
    ) {
        let effectiveIdentity = identity ?? (model.capabilitySourceURL == geminiSourceURL ? .gemini : nil)
        if effectiveIdentity == .gemini, model.id == geminiTTSModelID {
            let official = gemini38TTSModel
            if let conflict = detectOfficialFactsConflict(model: model, identity: effectiveIdentity) {
                model.officialFactsConflict = conflict
                return
            }

            model.officialFactsConflict = nil
            model.baseModality = official.baseModality
            model.baseContextWindow = official.baseContextWindow
            model.baseMaxOutputTokens = official.baseMaxOutputTokens
            model.baseSupportsReasoning = official.baseSupportsReasoning
            model.reasoningEffortValues = official.reasoningEffortValues
            model.declaresNoEffortTiers = official.declaresNoEffortTiers
            model.effortDeclarationIsAuthoritative = official.effortDeclarationIsAuthoritative
            model.baseMetadataSource = official.baseMetadataSource
            model.baseCapabilityProvenance = official.baseCapabilityProvenance
            model.capabilitySourceURL = official.capabilitySourceURL
            model.capabilityCatalogVersion = official.capabilityCatalogVersion
            if model.baseDisplayName == model.id || model.baseDisplayName.isEmpty {
                model.baseDisplayName = official.baseDisplayName
            }
        }
    }
}
