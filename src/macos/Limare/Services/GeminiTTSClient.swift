import Foundation

public final class GeminiTTSClient: Sendable {
    public static let supportedModelIDs: Set<String> = [ProviderOfficialCatalog.geminiTTSModelID]
    public static let defaultVoice: String = "Kore"
    public static let maxSegmentBytes: Int64 = 32 * 1024 * 1024 // 32 MB (safely covers up to 10 minutes of 24kHz 16-bit mono WAV)
    public static let maxChunkCharacters: Int = 2000 // Provable bound: even if every character is 4 UTF-8 bytes, 2000 * 4 = 8000 <= 8192
    public static let maxChunkBytes: Int = 8000 // Strict UTF-8 byte boundary, strictly below 8,192 max input tokens
    public static let maxInputTokens: Int = 8192
    public static let maxOutputTokens: Int = 16384
    public static let defaultTimeoutSeconds: TimeInterval = 120.0

    private let session: URLSession
    private let audioValidator: AudioDataValidating

    public init(
        session: URLSession = .shared,
        audioValidator: AudioDataValidating = AVAudioDataValidator()
    ) {
        self.session = session
        self.audioValidator = audioValidator
    }

    public static func isValidWAVHeader(_ data: Data) -> Bool {
        guard data.count >= 44 else { return false }
        let riff = data.prefix(4)
        let wave = data.subdata(in: 8..<12)
        return riff == Data([0x52, 0x49, 0x46, 0x46]) && wave == Data([0x57, 0x41, 0x56, 0x45])
    }

    /// Conservative client-side partition threshold for long text splitting.
    ///
    /// Background & Boundary Rationale:
    /// This local heuristic (based on UTF-8 byte count, bounded at 2,000 characters and 8,000 bytes)
    /// provides a conservative client-side partition threshold to safely chunk long texts prior to transmission,
    /// preventing oversized request payloads and maintaining a safe margin below Gemini's 8,192 input token limit.
    ///
    /// IMPORTANT: This is an offline safety threshold to avoid payload overflows, NOT an empirical claim or
    /// deterministic proof of Google Gemini's internal server-side tokenization rules.
    /// For authoritative token counts, use the official `countTokens` API.
    /// Real end-to-end token acceptance and audio playback integrity remain subject to user manual verification
    /// ("待真实端到端验收").
    public static func conservativeTokenEstimate(_ text: String) -> Int {
        return text.utf8.count
    }

    /// Backward-compatible alias for conservativeTokenEstimate.
    public static func provableUpperTokenBound(_ text: String) -> Int {
        return conservativeTokenEstimate(text)
    }

    /// Backward-compatible alias for conservativeTokenEstimate.
    public static func estimateTokenCount(_ text: String) -> Int {
        return conservativeTokenEstimate(text)
    }

    public func synthesizeSpeech(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        text: String,
        voice: String = defaultVoice
    ) async throws -> Data {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.supportedModelIDs.contains(trimmedModelID) else {
            throw VoiceOutputError.synthesisFailed("Model '\(trimmedModelID)' is not supported by Gemini TTS adapter. Only 'gemini-3.8-flash-tts' is supported.")
        }

        // 1. Client-side sanity check: Reject obviously oversized input prior to network request
        let estimatedTokens = Self.conservativeTokenEstimate(text)
        guard estimatedTokens <= Self.maxInputTokens else {
            throw VoiceOutputError.synthesisFailed("Input text exceeds conservative client partition threshold: \(estimatedTokens) estimated tokens/bytes > \(Self.maxInputTokens) limit. Partition text into smaller chunks or verify with countTokens.")
        }

        // 2. Authoritative token verification: Call official Google Gemini countTokens API
        let officialTokens = try await countTokens(
            provider: provider,
            apiKey: apiKey,
            modelID: trimmedModelID,
            text: text
        )
        guard officialTokens <= Self.maxInputTokens else {
            throw VoiceOutputError.synthesisFailed("Input text exceeds official Gemini token limit: \(officialTokens) tokens > \(Self.maxInputTokens) max input tokens.")
        }

        let effectiveVoice: String = {
            let v = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty || v.caseInsensitiveCompare("alloy") == .orderedSame {
                return Self.defaultVoice
            }
            return v
        }()

        let trimmedBase = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasV1Beta = trimmedBase.lowercased().contains("v1beta")
        let endpointName = hasV1Beta ? "interactions" : "v1beta/interactions"

        let endpointURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: false,
            endpoint: endpointName
        )

        try Task.checkCancellation()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.defaultTimeoutSeconds

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )

        // Ensure Gemini authentication header
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "model": trimmedModelID,
            "input": text,
            "response_format": [
                "type": "audio"
            ],
            "generation_config": [
                "speech_config": [
                    ["voice": effectiveVoice]
                ]
            ],
            "store": false,
            "background": false
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw VoiceOutputError.synthesisFailed("Failed to encode Gemini TTS request payload.")
        }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let nsError as NSError where nsError.domain == "Swift.CancellationError" || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMsg = SecretMasker.redact(error.localizedDescription, secrets: secrets)
            throw VoiceOutputError.networkError(safeMsg)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceOutputError.synthesisFailed("Invalid HTTP response from Gemini TTS provider.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var responseString = String(data: data, encoding: .utf8) ?? ""
            if responseString.count > 1000 {
                responseString = String(responseString.prefix(1000)) + "… (truncated)"
            }
            let parsedMessage = parseErrorMessage(from: data) ?? responseString
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            var safeMessage = SecretMasker.redact(parsedMessage, secrets: secrets)
            if safeMessage.count > 1000 {
                safeMessage = String(safeMessage.prefix(1000)) + "… (truncated)"
            }
            throw VoiceOutputError.synthesisFailed("HTTP \(httpResponse.statusCode): \(safeMessage)")
        }

        guard !data.isEmpty else {
            throw VoiceOutputError.synthesisFailed("Empty response returned from Gemini TTS provider.")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceOutputError.synthesisFailed("Invalid JSON response from Gemini TTS provider.")
        }

        let status = root["status"] as? String
        guard status == "completed" else {
            if status == "failed", let errorObj = root["error"] as? [String: Any],
               let msg = errorObj["message"] as? String, !msg.isEmpty {
                let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
                let safeMsg = SecretMasker.redact(msg, secrets: secrets)
                throw VoiceOutputError.synthesisFailed("Interaction failed: \(safeMsg)")
            }
            throw VoiceOutputError.synthesisFailed("Interaction did not complete (status: \(status ?? "unknown")).")
        }

        guard let steps = root["steps"] as? [[String: Any]], !steps.isEmpty else {
            throw VoiceOutputError.synthesisFailed("No steps in Gemini TTS interaction response.")
        }

        guard let modelOutputStep = steps.last(where: { ($0["type"] as? String) == "model_output" }) else {
            throw VoiceOutputError.synthesisFailed("No model_output step in Gemini TTS interaction response.")
        }

        guard let contents = modelOutputStep["content"] as? [[String: Any]], !contents.isEmpty else {
            throw VoiceOutputError.synthesisFailed("No content in Gemini TTS model_output step.")
        }

        guard let audioContent = contents.first(where: { ($0["type"] as? String) == "audio" }) else {
            throw VoiceOutputError.synthesisFailed("No audio content in Gemini TTS model_output step.")
        }

        guard let b64String = audioContent["data"] as? String, !b64String.isEmpty else {
            throw VoiceOutputError.synthesisFailed("Empty audio base64 data returned from Gemini TTS.")
        }

        guard let audioData = Data(base64Encoded: b64String, options: [.ignoreUnknownCharacters]), !audioData.isEmpty else {
            throw VoiceOutputError.synthesisFailed("Corrupted base64 audio data in Gemini TTS response.")
        }

        if Int64(audioData.count) > Self.maxSegmentBytes {
            throw VoiceOutputError.audioTooLarge(Int64(audioData.count))
        }

        guard Self.isValidWAVHeader(audioData) else {
            throw VoiceOutputError.invalidAudioResponse("Invalid WAV audio header in Gemini TTS response.")
        }

        try audioValidator.validate(audioData)

        return audioData
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// Calls the official Google Gemini `countTokens` API endpoint (`POST /v1beta/models/{modelID}:countTokens`).
    /// Returns the authoritative server-side token count computed by Google's official tokenizer.
    public func countTokens(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        text: String
    ) async throws -> Int {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            throw VoiceOutputError.synthesisFailed("Model ID cannot be empty for countTokens.")
        }

        let trimmedBase = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasV1Beta = trimmedBase.lowercased().contains("v1beta")
        let endpointName = hasV1Beta ? "models/\(trimmedModelID):countTokens" : "v1beta/models/\(trimmedModelID):countTokens"

        let endpointURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: false,
            endpoint: endpointName
        )

        try Task.checkCancellation()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.defaultTimeoutSeconds

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )

        // Ensure Gemini authentication header
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": text]
                    ]
                ]
            ]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw VoiceOutputError.synthesisFailed("Failed to encode countTokens request payload.")
        }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let nsError as NSError where nsError.domain == "Swift.CancellationError" || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMsg = SecretMasker.redact(error.localizedDescription, secrets: secrets)
            throw VoiceOutputError.networkError(safeMsg)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceOutputError.synthesisFailed("Invalid HTTP response from Gemini countTokens API.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let parsedMessage = parseErrorMessage(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMessage = SecretMasker.redact(parsedMessage, secrets: secrets)
            throw VoiceOutputError.synthesisFailed("HTTP \(httpResponse.statusCode): \(safeMessage)")
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let totalTokens = root["totalTokens"] as? Int else {
            throw VoiceOutputError.synthesisFailed("Failed to parse totalTokens from Gemini countTokens response.")
        }

        return totalTokens
    }
}
