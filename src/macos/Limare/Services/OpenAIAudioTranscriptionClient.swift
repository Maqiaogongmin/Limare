import Foundation

public final class OpenAIAudioTranscriptionClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func transcribeAudio(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        audioData: Data,
        filename: String = "voice.wav"
    ) async throws -> String {
        let endpointURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: provider.appendV1Suffix,
            endpoint: "audio/transcriptions"
        )

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120.0

        let boundary = "Boundary-\(UUID().uuidString)"

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = createMultipartBody(
            boundary: boundary,
            audioData: audioData,
            filename: filename,
            modelID: modelID
        )
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let nsError as NSError where nsError.domain == "Swift.CancellationError" || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            throw CancellationError()
        } catch {
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMsg = SecretMasker.redact(error.localizedDescription, secrets: secrets)
            throw VoiceInputError.networkError(safeMsg)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceInputError.transcriptionFailed("Invalid HTTP response from ASR provider.")
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
            throw VoiceInputError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(safeMessage)")
        }

        return try parseTranscriptionResponse(data: data, statusCode: httpResponse.statusCode)
    }

    private func createMultipartBody(
        boundary: String,
        audioData: Data,
        filename: String,
        modelID: String
    ) -> Data {
        var body = Data()

        // 1. file field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n".utf8))

        // 2. model field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("\(modelID)\r\n".utf8))

        // 3. response_format field
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".utf8))
        body.append(Data("json\r\n".utf8))

        // End boundary
        body.append(Data("--\(boundary)--\r\n".utf8))

        return body
    }

    private func parseTranscriptionResponse(data: Data, statusCode: Int) throws -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw VoiceInputError.emptyTranscription
                }
                return trimmed
            }
        }
        // Fallback: raw text if valid UTF8
        if let rawText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if rawText.isEmpty {
                throw VoiceInputError.emptyTranscription
            }
            return rawText
        }
        throw VoiceInputError.transcriptionFailed("HTTP \(statusCode): Response did not contain transcription text.")
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var msg: String?
        if let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String, !message.isEmpty {
            msg = message
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
