import Foundation

public final class OpenAIAudioSpeechClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func synthesizeSpeech(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        text: String,
        voice: String = VoiceOutputDefaults.cloudVoice,
        responseFormat: String = VoiceOutputDefaults.responseFormat
    ) async throws -> Data {
        let endpointURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: provider.appendV1Suffix,
            endpoint: "audio/speech"
        )

        try Task.checkCancellation()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120.0

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let payload: [String: Any] = [
            "model": modelID,
            "input": text,
            "voice": voice,
            "response_format": responseFormat
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            throw VoiceOutputError.synthesisFailed("Failed to encode speech synthesis request payload.")
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
            throw VoiceOutputError.synthesisFailed("Invalid HTTP response from TTS provider.")
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
            throw VoiceOutputError.synthesisFailed("Empty audio data returned from TTS provider.")
        }

        if Int64(data.count) > VoiceOutputDefaults.maxSegmentBytes {
            throw VoiceOutputError.audioTooLarge(Int64(data.count))
        }

        // Check if 2xx response was actually a JSON payload instead of audio
        let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json") || (data.count < 1024 && String(data: data, encoding: .utf8)?.contains("\"error\"") == true) {
            let parsedMessage = parseErrorMessage(from: data)
            let errorMsg = parsedMessage ?? "Provider returned JSON instead of audio."
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            var safeMsg = SecretMasker.redact(errorMsg, secrets: secrets)
            if safeMsg.count > 1000 {
                safeMsg = String(safeMsg.prefix(1000)) + "… (truncated)"
            }
            throw VoiceOutputError.invalidAudioResponse(safeMsg)
        }

        return data
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var msg: String?
        if let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String, !message.isEmpty {
            msg = message
        } else if let errorObj = json["error"] as? String, !errorObj.isEmpty {
            msg = errorObj
        } else if let message = json["message"] as? String, !message.isEmpty {
            msg = message
        }
        if let m = msg {
            if m.count > 1000 {
                return String(m.prefix(1000)) + "… (truncated)"
            }
            return m
        }
        return nil
    }
}
