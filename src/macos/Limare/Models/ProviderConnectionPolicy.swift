import Foundation

public enum ProviderIdentity: String, Codable, CaseIterable, Sendable {
    case custom, openAI, anthropic, gemini, antigravity, openRouter, xAI, kimiCode, unsupported

    public var displayName: String {
        switch self {
        case .custom: "Custom / Local"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .antigravity: "Antigravity"
        case .openRouter: "OpenRouter"
        case .xAI: "xAI"
        case .kimiCode: "Kimi Code"
        case .unsupported: "Unsupported"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .custom, .antigravity, .unsupported: ""
        case .openAI: "https://api.openai.com"
        case .anthropic: "https://api.anthropic.com"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: "https://openrouter.ai/api"
        case .xAI: "https://api.x.ai"
        case .kimiCode: "https://api.kimi.com/coding"
        }
    }

    public var defaultProtocol: ProviderAPIFormat {
        switch self {
        case .openAI, .xAI: .responses
        case .anthropic: .anthropicMessages
        case .gemini: .geminiNative
        default: .chatCompletions
        }
    }
}

public enum ProviderCredentialKind: String, Codable, Sendable {
    case apiKey, azureAPIKey, oauthAccessToken, none
}

public enum CredentialAcquisitionMethod: String, Codable, CaseIterable, Sendable {
    case manualAPIKey, authorizationCodePKCE, vendorWebAPIKey, azureAPIKey, none
    public var displayName: String {
        switch self {
        case .manualAPIKey: "API Key"
        case .authorizationCodePKCE: "ChatGPT Account"
        case .vendorWebAPIKey: "OpenRouter Login"
        case .azureAPIKey: "Azure API Key"
        case .none: "No authentication"
        }
    }

    /// The button that starts a browser acquisition.
    public var actionTitle: String {
        switch self {
        case .authorizationCodePKCE: "Sign in with ChatGPT"
        case .vendorWebAPIKey: "Connect OpenRouter"
        default: displayName
        }
    }
}

public struct ProviderAuthenticationSelection: Codable, Hashable, Sendable {
    public var credentialKind: ProviderCredentialKind
    public var acquisitionMethod: CredentialAcquisitionMethod
    public var authenticationIdentityID: String
    public var unknownCredentialKindRaw: String? = nil
    public var unknownAcquisitionRaw: String? = nil

    public init(credentialKind: ProviderCredentialKind, acquisitionMethod: CredentialAcquisitionMethod,
                authenticationIdentityID: String = "legacy-api-key") {
        self.credentialKind = credentialKind
        self.acquisitionMethod = acquisitionMethod
        self.authenticationIdentityID = authenticationIdentityID
    }

    private enum CodingKeys: String, CodingKey { case credentialKind, acquisitionMethod, authenticationIdentityID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kindRaw = try c.decode(String.self, forKey: .credentialKind)
        let methodRaw = try c.decode(String.self, forKey: .acquisitionMethod)
        credentialKind = ProviderCredentialKind(rawValue: kindRaw) ?? .none
        acquisitionMethod = CredentialAcquisitionMethod(rawValue: methodRaw) ?? .none
        unknownCredentialKindRaw = ProviderCredentialKind(rawValue: kindRaw) == nil ? kindRaw : nil
        unknownAcquisitionRaw = CredentialAcquisitionMethod(rawValue: methodRaw) == nil ? methodRaw : nil
        authenticationIdentityID = try c.decode(String.self, forKey: .authenticationIdentityID)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unknownCredentialKindRaw ?? credentialKind.rawValue, forKey: .credentialKind)
        try c.encode(unknownAcquisitionRaw ?? acquisitionMethod.rawValue, forKey: .acquisitionMethod)
        try c.encode(authenticationIdentityID, forKey: .authenticationIdentityID)
    }

    public static func legacy(_ mode: ProviderAuthenticationMode) -> Self {
        switch mode {
        case .bearer: .init(credentialKind: .apiKey, acquisitionMethod: .manualAPIKey)
        case .azureAPIKey: .init(credentialKind: .azureAPIKey, acquisitionMethod: .azureAPIKey)
        case .none: .init(credentialKind: .none, acquisitionMethod: .none)
        case .oauth: .init(credentialKind: .oauthAccessToken, acquisitionMethod: .authorizationCodePKCE, authenticationIdentityID: "chatgpt-account")
        }
    }
}

public enum AuthAvailability: String, Codable, Sendable {
    case supported = "SUPPORTED"
    case disabledByPolicy = "DISABLED_BY_POLICY"
    case unsupported = "UNSUPPORTED"
}

public enum ProviderConnectionError: LocalizedError, Equatable {
    case disabled(String), invalidCredentialRoute, untrustedOAuthEndpoint, unsupportedProtocol
    case invalidThinking(String)
    public var errorDescription: String? {
        switch self {
        case .disabled(let name): "\(name) authentication is disabled by product policy."
        case .invalidCredentialRoute: "The selected credential does not belong to this authentication route."
        case .untrustedOAuthEndpoint: "ChatGPT OAuth credentials can only be sent to the official OpenAI resource."
        case .unsupportedProtocol: "This protocol is not supported by the selected provider."
        case .invalidThinking(let reason): reason
        }
    }
}

/// A compiled product policy, not a provider/configuration registry. UI and admission share it.
public enum ProviderProductPolicy {
    public static func availability(_ provider: ProviderConfiguration) -> AuthAvailability {
        let selection = provider.authenticationSelection
        if provider.unknownProviderIdentityRaw != nil || provider.unknownProtocolRaw != nil
            || provider.unknownLegacyKindRaw != nil || selection.unknownCredentialKindRaw != nil
            || selection.unknownAcquisitionRaw != nil || provider.providerIdentity == .unsupported { return .unsupported }
        if provider.providerIdentity == .antigravity {
            return selection.credentialKind == .oauthAccessToken ? .disabledByPolicy : .unsupported
        }
        if selection.acquisitionMethod == .authorizationCodePKCE,
           [.anthropic, .gemini, .xAI, .kimiCode].contains(provider.providerIdentity) { return .disabledByPolicy }
        do { try validate(provider); return .supported }
        catch { return .unsupported }
    }

    public static func allowsOAuthResource(_ url: URL) -> Bool {
        guard let endpoint = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return endpoint.scheme == "https" && endpoint.host == "api.openai.com" && endpoint.port == nil
            && (endpoint.path == "/v1" || endpoint.path.hasPrefix("/v1/"))
            && endpoint.user == nil && endpoint.password == nil && endpoint.fragment == nil
    }

    public static var selectableIdentities: [ProviderIdentity] {
        ProviderIdentity.allCases.filter { ![.antigravity, .unsupported].contains($0) }
    }

    public static func protocols(for identity: ProviderIdentity) -> [ProviderAPIFormat] {
        switch identity {
        case .custom: [.chatCompletions, .responses, .anthropicMessages]
        case .openAI, .xAI: [.responses, .chatCompletions]
        case .anthropic: [.anthropicMessages]
        case .gemini: [.geminiNative]
        case .kimiCode: [.chatCompletions, .anthropicMessages]
        case .openRouter: [.chatCompletions]
        case .antigravity, .unsupported: []
        }
    }

    public static func acquisitions(for identity: ProviderIdentity, protocol format: ProviderAPIFormat) -> [CredentialAcquisitionMethod] {
        guard protocols(for: identity).contains(format) else { return [] }
        return switch identity {
        case .custom: format == .anthropicMessages ? [.manualAPIKey] : [.manualAPIKey, .azureAPIKey, .none]
        case .openAI: format == .responses ? [.manualAPIKey, .authorizationCodePKCE] : [.manualAPIKey]
        case .openRouter: [.manualAPIKey, .vendorWebAPIKey]
        case .antigravity, .unsupported: []
        default: [.manualAPIKey]
        }
    }

    public static func validate(_ provider: ProviderConfiguration) throws {
        guard provider.unknownProtocolRaw == nil, provider.unknownLegacyKindRaw == nil, ![.antigravity, .unsupported].contains(provider.providerIdentity) else {
            throw ProviderConnectionError.disabled(provider.providerIdentity.displayName)
        }
        guard protocols(for: provider.providerIdentity).contains(provider.protocolAdapter) else {
            throw ProviderConnectionError.unsupportedProtocol
        }
        let selection = provider.authenticationSelection
        guard selection.unknownCredentialKindRaw == nil, selection.unknownAcquisitionRaw == nil else {
            throw ProviderConnectionError.invalidCredentialRoute
        }
        guard acquisitions(for: provider.providerIdentity, protocol: provider.protocolAdapter).contains(selection.acquisitionMethod) else {
            throw ProviderConnectionError.disabled(selection.acquisitionMethod.displayName)
        }
        let expected: ProviderCredentialKind = switch selection.acquisitionMethod {
        case .manualAPIKey, .vendorWebAPIKey: .apiKey
        case .authorizationCodePKCE: .oauthAccessToken
        case .azureAPIKey: .azureAPIKey
        case .none: .none
        }
        guard expected == selection.credentialKind else { throw ProviderConnectionError.invalidCredentialRoute }
        if selection.credentialKind == .oauthAccessToken {
            if let modelsURL = provider.modelsURL {
                guard let url = URL(string: modelsURL), allowsOAuthResource(url), url.path == "/v1/models" else {
                    throw ProviderConnectionError.untrustedOAuthEndpoint
                }
            }
            guard provider.providerIdentity == .openAI, provider.protocolAdapter == .responses,
                  let endpoint = URLComponents(string: provider.baseURL), endpoint.scheme == "https",
                  endpoint.host == "api.openai.com", endpoint.port == nil,
                  ["", "/", "/v1", "/v1/"].contains(endpoint.path),
                  endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
                throw ProviderConnectionError.untrustedOAuthEndpoint
            }
        }
    }
}
