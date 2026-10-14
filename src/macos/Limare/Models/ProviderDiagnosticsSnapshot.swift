import Foundation

public struct ProviderDiagnosticsSnapshot: Identifiable, Sendable, Equatable {
    public var id: String { "\(providerID.uuidString):\(modelID)" }

    // Provider Level
    public let providerID: UUID
    public let providerName: String
    public let providerKind: ProviderKind
    public let apiFormat: ProviderAPIFormat
    public let baseURL: String
    public let appendV1Suffix: Bool
    public let endpointSummary: String
    public let authenticationMode: ProviderAuthenticationMode
    public let hasStoredSecret: Bool
    public let isConfigured: Bool
    public let customUserAgent: String?
    public let customHeadersCount: Int
    public let customHeaderKeys: [String]
    public let totalModels: Int

    // Model Level
    public let modelID: String
    public let modelDisplayName: String
    public let isCustomModel: Bool
    public let isHidden: Bool
    public let baseMetadataSource: String?
    public let capabilityProvenance: ModelCapabilityProvenance
    public let hasOverrides: Bool
    public let effectiveModalities: ModelModality?
    public let supportsText: Bool
    public let supportsVision: Bool
    public let isVisionInferredOrUnknown: Bool
    public let supportsReasoning: Bool?
    public let reasoningEffortValues: [String]?
    public let contextWindow: Int?
    public let maxOutputTokens: Int?

    public init(
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKeyAvailable: Bool? = nil
    ) {
        self.providerID = provider.id
        self.providerName = provider.name.isEmpty ? "Untitled Provider" : provider.name
        self.providerKind = provider.kind
        self.apiFormat = provider.apiFormat
        self.baseURL = provider.baseURL
        self.appendV1Suffix = provider.appendV1Suffix

        var isEndpointValid = false
        let ep: String
        do {
            let targetEndpoint: String = switch provider.apiFormat {
            case .responses: "responses"
            case .chatCompletions: "chat/completions"
            case .anthropicMessages: "messages"
            case .geminiNative: "models/\(model.id):streamGenerateContent"
            }
            let url = try EndpointBuilder.endpoint(
                baseURL: provider.baseURL,
                appendV1Suffix: provider.apiFormat == .geminiNative ? false : provider.appendV1Suffix,
                endpoint: targetEndpoint
            )
            ep = url.absoluteString
            isEndpointValid = true
        } catch {
            ep = provider.baseURL.isEmpty ? "No Base URL" : "\(provider.baseURL) (Invalid)"
            isEndpointValid = false
        }
        self.endpointSummary = ep

        self.authenticationMode = provider.authenticationMode
        self.hasStoredSecret = apiKeyAvailable ?? provider.hasStoredSecret
        self.isConfigured = isEndpointValid
        self.customUserAgent = provider.customUserAgent
        self.customHeadersCount = provider.extraHeaders.count
        self.customHeaderKeys = provider.extraHeaders.keys.sorted()
        self.totalModels = provider.models.count

        self.modelID = model.id
        self.modelDisplayName = model.displayName
        self.isCustomModel = model.isCustom
        self.isHidden = model.isHidden
        self.baseMetadataSource = model.baseMetadataSource?.rawValue ?? (model.isCustom ? "Custom" : "Unknown")
        self.capabilityProvenance = model.capabilityProvenance
        self.hasOverrides = !model.overrides.isEmpty

        let effective = model.modality ?? model.baseModality
        self.effectiveModalities = effective
        if let effective {
            self.supportsText = effective.contains(.textInput) && effective.contains(.textOutput)
            self.supportsVision = effective.contains(.textInput) && effective.contains(.textOutput) && effective.contains(.imageInput)
            self.isVisionInferredOrUnknown = model.capabilityProvenance.modality == .inferred
        } else {
            self.supportsText = true
            self.supportsVision = false
            self.isVisionInferredOrUnknown = true
        }
        self.supportsReasoning = model.supportsReasoning
        self.reasoningEffortValues = model.reasoningEffortValues
        self.contextWindow = model.contextWindow
        self.maxOutputTokens = model.maxOutputTokens
    }

    public init(
        provider: ProviderConfiguration,
        modelID: String,
        apiKeyAvailable: Bool? = nil
    ) {
        let model = provider.models.first(where: { $0.id == modelID }) ?? ProviderModel(id: modelID, displayName: modelID)
        self.init(provider: provider, model: model, apiKeyAvailable: apiKeyAvailable)
    }
}
