import Foundation

public enum VoiceOutputRoutingDecision: Equatable, Sendable {
    case openAIAudioSpeech
    case geminiNativeInteractions
    case protocolUnsupported(reason: String)
}

public enum VoiceOutputRouting {
    public static func route(
        provider: ProviderConfiguration,
        modelID: String
    ) -> VoiceOutputRoutingDecision {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Google Gemini Native
        if provider.protocolAdapter == .geminiNative {
            if trimmedModelID == ProviderOfficialCatalog.geminiTTSModelID {
                return .geminiNativeInteractions
            } else {
                return .protocolUnsupported(reason: "Model '\(trimmedModelID)' is not supported by Gemini Native Interactions TTS. Only '\(ProviderOfficialCatalog.geminiTTSModelID)' is supported.")
            }
        }

        // 2. Reject Google generativelanguage OpenAI compatible endpoint
        let lowerBase = provider.baseURL.lowercased()
        if lowerBase.contains("generativelanguage.googleapis.com") {
            return .protocolUnsupported(reason: "Google Gemini does not support OpenAI-compatible /audio/speech endpoints. Use Google Gemini with Native protocol.")
        }

        // 3. Providers with standard OpenAI-compatible audio speech endpoints
        if provider.protocolAdapter == .chatCompletions || provider.protocolAdapter == .responses {
            return .openAIAudioSpeech
        }

        return .protocolUnsupported(reason: "Protocol adapter '\(provider.protocolAdapter.rawValue)' does not support audio speech synthesis.")
    }
}
