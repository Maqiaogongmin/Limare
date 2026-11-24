import Foundation

public struct GeneratedMediaResponse: Sendable {
    public let data: Data
    public let mimeType: String
    public let text: String?

    public init(data: Data, mimeType: String, text: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.text = text
    }
}

public final class GeminiMediaGenerationClient: Sendable {
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    public static let maxVideoBytes: Int64 = 128 * 1024 * 1024
    public static let maxAudioBytes: Int64 = 64 * 1024 * 1024
    public static let defaultPollIntervalNanoseconds: UInt64 = 2_000_000_000
    public static let maxPollAttempts: Int = 180

    private let session: URLSession
    private let geminiTTSClient: GeminiTTSClient
    private let openAISpeechClient: OpenAIAudioSpeechClient
    private let sleeper: Sleeper

    public init(
        session: URLSession = .shared,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.session = session
        self.geminiTTSClient = GeminiTTSClient(session: session)
        self.openAISpeechClient = OpenAIAudioSpeechClient(session: session)
        self.sleeper = sleeper
    }

    public func generateVideo(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        aspectRatio: String? = nil,
        durationSeconds: Int? = nil
    ) async throws -> GeneratedMediaResponse {
        guard provider.protocolAdapter == .geminiNative else {
            throw ProviderClientError.http(
                status: 400,
                message: "Video generation requires a Google Gemini Native provider (e.g. gemini-omni-1.2-flash or veo-3.1)."
            )
        }

        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedModelID.lowercased().hasPrefix("veo") {
            return try await generateVeoVideo(
                provider: provider,
                apiKey: apiKey,
                modelID: trimmedModelID,
                prompt: prompt,
                aspectRatio: aspectRatio,
                durationSeconds: durationSeconds
            )
        } else {
            return try await generateViaInteractions(
                provider: provider,
                apiKey: apiKey,
                modelID: trimmedModelID,
                prompt: prompt,
                responseModalities: ["video"],
                background: true,
                targetKind: .video
            )
        }
    }

    public func generateAudio(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        voice: String? = nil
    ) async throws -> GeneratedMediaResponse {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.protocolAdapter == .geminiNative {
            if GeminiTTSClient.supportedModelIDs.contains(trimmedModelID) {
                let effectiveVoice = (voice?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? GeminiTTSClient.defaultVoice
                let data = try await geminiTTSClient.synthesizeSpeech(
                    provider: provider,
                    apiKey: apiKey,
                    modelID: trimmedModelID,
                    text: prompt,
                    voice: effectiveVoice
                )
                return GeneratedMediaResponse(data: data, mimeType: "audio/wav", text: nil)
            }
            return try await generateViaInteractions(
                provider: provider,
                apiKey: apiKey,
                modelID: trimmedModelID,
                prompt: prompt,
                responseModalities: ["audio", "text"],
                background: false,
                targetKind: .audio
            )
        }

        if provider.protocolAdapter == .responses || provider.protocolAdapter == .chatCompletions {
            let effectiveVoice = (voice?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? VoiceOutputDefaults.cloudVoice
            let data = try await openAISpeechClient.synthesizeSpeech(
                provider: provider,
                apiKey: apiKey,
                modelID: trimmedModelID,
                text: prompt,
                voice: effectiveVoice
            )
            return GeneratedMediaResponse(data: data, mimeType: "audio/mpeg", text: nil)
        }

        throw ProviderClientError.http(
            status: 400,
            message: "Protocol adapter '\(provider.protocolAdapter.rawValue)' does not support audio generation."
        )
    }

    // MARK: - Gemini Interactions API (gemini-omni-* / lyria-*)

    private enum MediaTargetKind {
        case video
        case audio

        var expectedPrefix: String {
            switch self {
            case .video: return "video"
            case .audio: return "audio"
            }
        }

        var defaultMimeType: String {
            switch self {
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            }
        }

        var maxBytes: Int64 {
            switch self {
            case .video: return GeminiMediaGenerationClient.maxVideoBytes
            case .audio: return GeminiMediaGenerationClient.maxAudioBytes
            }
        }
    }

    private func generateViaInteractions(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        responseModalities: [String],
        background: Bool,
        targetKind: MediaTargetKind
    ) async throws -> GeneratedMediaResponse {
        let createURL = try geminiEndpoint(provider: provider, suffix: "interactions")
        let payload: [String: Any] = [
            "model": modelID,
            "input": prompt,
            "response_modalities": responseModalities,
            "store": background,
            "background": background,
        ]
        var root = try await postJSON(url: createURL, body: payload, provider: provider, apiKey: apiKey, timeout: 600.0)

        var status = (root["status"] as? String)?.lowercased()
        if let interactionID = root["id"] as? String, !interactionID.isEmpty,
           status != "completed" && status != "failed" {
            let pollURL = try geminiEndpoint(provider: provider, suffix: "interactions/\(interactionID)")
            for _ in 0..<Self.maxPollAttempts {
                try Task.checkCancellation()
                try await sleeper(Self.defaultPollIntervalNanoseconds)
                try Task.checkCancellation()
                root = try await getJSON(url: pollURL, provider: provider, apiKey: apiKey, timeout: 120.0)
                status = (root["status"] as? String)?.lowercased()
                if status == "completed" || status == "failed" {
                    break
                }
            }
        }

        if status == "failed" {
            let msg = ((root["error"] as? [String: Any])?["message"] as? String) ?? "Interaction failed."
            throw ProviderClientError.http(status: 500, message: redact(msg, provider: provider, apiKey: apiKey))
        }
        guard status == "completed" || status == nil else {
            throw ProviderClientError.http(status: 504, message: "Media generation interaction did not complete (status: \(status ?? "unknown")).")
        }

        let contentItems = collectInteractionContentItems(from: root)
        var textNotes: [String] = []
        var mediaData: Data?
        var mediaMime: String?

        for item in contentItems {
            let itemType = (item["type"] as? String)?.lowercased() ?? ""
            let itemMime = (item["mime_type"] as? String) ?? (item["mimeType"] as? String)
            if itemType == "text", let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { textNotes.append(trimmed) }
                continue
            }
            if mediaData == nil,
               itemType == targetKind.expectedPrefix || itemMime?.lowercased().hasPrefix("\(targetKind.expectedPrefix)/") == true {
                if let b64 = item["data"] as? String, !b64.isEmpty,
                   let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !decoded.isEmpty {
                    mediaData = decoded
                    mediaMime = itemMime ?? Self.sniffMimeType(data: decoded, fallback: targetKind.defaultMimeType)
                } else if let uriString = (item["uri"] as? String) ?? (item["url"] as? String),
                          let downloadURL = URL(string: uriString) {
                    let (downloaded, downloadedMime) = try await downloadMedia(
                        from: downloadURL,
                        provider: provider,
                        apiKey: apiKey,
                        maxBytes: targetKind.maxBytes
                    )
                    mediaData = downloaded
                    mediaMime = itemMime ?? downloadedMime ?? Self.sniffMimeType(data: downloaded, fallback: targetKind.defaultMimeType)
                }
            }
        }

        guard let finalData = mediaData else {
            throw ProviderClientError.http(status: 502, message: "No \(targetKind.expectedPrefix) output returned by Gemini Interactions API.")
        }
        if Int64(finalData.count) > targetKind.maxBytes {
            throw ProviderClientError.http(status: 413, message: "Generated \(targetKind.expectedPrefix) exceeds size limit.")
        }
        return GeneratedMediaResponse(
            data: finalData,
            mimeType: mediaMime ?? targetKind.defaultMimeType,
            text: textNotes.isEmpty ? nil : textNotes.joined(separator: "\n")
        )
    }

    // MARK: - Veo Long-Running Video API

    private func generateVeoVideo(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        aspectRatio: String?,
        durationSeconds: Int?
    ) async throws -> GeneratedMediaResponse {
        let startURL = try geminiEndpoint(provider: provider, suffix: "models/\(modelID):predictLongRunning")
        var parameters: [String: Any] = [:]
        if let aspectRatio = aspectRatio?.trimmingCharacters(in: .whitespacesAndNewlines), !aspectRatio.isEmpty {
            parameters["aspectRatio"] = aspectRatio
        }
        if let durationSeconds, durationSeconds > 0 {
            parameters["durationSeconds"] = durationSeconds
        }
        var body: [String: Any] = [
            "instances": [["prompt": prompt]]
        ]
        if !parameters.isEmpty {
            body["parameters"] = parameters
        }

        var opRoot = try await postJSON(url: startURL, body: body, provider: provider, apiKey: apiKey, timeout: 120.0)
        if let opName = opRoot["name"] as? String, !opName.isEmpty, (opRoot["done"] as? Bool) != true {
            let pollURL = try geminiEndpoint(provider: provider, suffix: opName)
            for _ in 0..<Self.maxPollAttempts {
                try Task.checkCancellation()
                try await sleeper(Self.defaultPollIntervalNanoseconds)
                try Task.checkCancellation()
                opRoot = try await getJSON(url: pollURL, provider: provider, apiKey: apiKey, timeout: 120.0)
                if (opRoot["done"] as? Bool) == true {
                    break
                }
            }
        }

        if let errorObj = opRoot["error"] as? [String: Any],
           let msg = errorObj["message"] as? String, !msg.isEmpty {
            throw ProviderClientError.http(status: 500, message: redact(msg, provider: provider, apiKey: apiKey))
        }
        guard (opRoot["done"] as? Bool) == true else {
            throw ProviderClientError.http(status: 504, message: "Veo video generation timed out waiting for completion.")
        }

        guard let responseObj = opRoot["response"] as? [String: Any],
              let videoResp = (responseObj["generateVideoResponse"] as? [String: Any]) ?? (responseObj["predictLongRunningResponse"] as? [String: Any]) ?? Optional(responseObj),
              let samples = videoResp["generatedSamples"] as? [[String: Any]],
              let firstVideo = samples.first?["video"] as? [String: Any] else {
            throw ProviderClientError.http(status: 502, message: "Invalid Veo response: missing generated video sample.")
        }

        if let b64 = firstVideo["bytesBase64Encoded"] as? String,
           let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !decoded.isEmpty {
            if Int64(decoded.count) > Self.maxVideoBytes {
                throw ProviderClientError.http(status: 413, message: "Generated video exceeds size limit.")
            }
            let mime = (firstVideo["mimeType"] as? String) ?? "video/mp4"
            return GeneratedMediaResponse(data: decoded, mimeType: mime, text: nil)
        }

        if let uri = firstVideo["uri"] as? String, let downloadURL = URL(string: uri) {
            let (downloaded, mime) = try await downloadMedia(
                from: downloadURL,
                provider: provider,
                apiKey: apiKey,
                maxBytes: Self.maxVideoBytes
            )
            return GeneratedMediaResponse(data: downloaded, mimeType: mime ?? "video/mp4", text: nil)
        }

        throw ProviderClientError.http(status: 502, message: "Veo response contained neither video bytes nor download URI.")
    }

    // MARK: - Helpers

    private func collectInteractionContentItems(from root: [String: Any]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if let steps = root["steps"] as? [[String: Any]] {
            let modelSteps = steps.filter { ($0["type"] as? String) == "model_output" }
            let targetSteps = modelSteps.isEmpty ? steps : modelSteps
            for step in targetSteps {
                if let content = step["content"] as? [[String: Any]] {
                    items.append(contentsOf: content)
                }
            }
        }
        if let outputs = root["outputs"] as? [[String: Any]] {
            items.append(contentsOf: outputs)
        }
        return items
    }

    private func geminiEndpoint(provider: ProviderConfiguration, suffix: String) throws -> URL {
        let trimmedBase = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasV1Beta = trimmedBase.lowercased().contains("v1beta")
        let cleanSuffix = suffix.hasPrefix("v1beta/") && hasV1Beta ? String(suffix.dropFirst(7)) : suffix
        let endpointName = (hasV1Beta || cleanSuffix.hasPrefix("v1beta/")) ? cleanSuffix : "v1beta/\(cleanSuffix)"
        return try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: false,
            endpoint: endpointName
        )
    }

    private func postJSON(
        url: URL,
        body: [String: Any],
        provider: ProviderConfiguration,
        apiKey: String?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        configureGeminiHeaders(&request, provider: provider, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await executeJSON(request, provider: provider, apiKey: apiKey)
    }

    private func getJSON(
        url: URL,
        provider: ProviderConfiguration,
        apiKey: String?,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        configureGeminiHeaders(&request, provider: provider, apiKey: apiKey)
        return try await executeJSON(request, provider: provider, apiKey: apiKey)
    }

    private func configureGeminiHeaders(_ request: inout URLRequest, provider: ProviderConfiguration, apiKey: String?) {
        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func executeJSON(
        _ request: URLRequest,
        provider: ProviderConfiguration,
        apiKey: String?
    ) async throws -> [String: Any] {
        let (data, httpResponse) = try await performData(request, provider: provider, apiKey: apiKey)
        guard (200...299).contains(httpResponse.statusCode) else {
            let parsed = parseErrorMessage(from: data) ?? (String(data: data, encoding: .utf8) ?? "")
            throw ProviderClientError.http(status: httpResponse.statusCode, message: redact(parsed, provider: provider, apiKey: apiKey))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.http(status: httpResponse.statusCode, message: "Invalid JSON response from Gemini media endpoint.")
        }
        return root
    }

    private func downloadMedia(
        from url: URL,
        provider: ProviderConfiguration,
        apiKey: String?,
        maxBytes: Int64
    ) async throws -> (Data, String?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ProviderClientError.http(status: 400, message: "Unsupported media download URL scheme.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 600.0
        if url.host?.lowercased().contains("googleapis.com") == true,
           let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        let (data, httpResponse) = try await performData(request, provider: provider, apiKey: apiKey)
        guard (200...299).contains(httpResponse.statusCode) else {
            throw ProviderClientError.http(status: httpResponse.statusCode, message: "Failed to download generated media (HTTP \(httpResponse.statusCode)).")
        }
        guard !data.isEmpty else {
            throw ProviderClientError.http(status: 502, message: "Downloaded media file is empty.")
        }
        if Int64(data.count) > maxBytes {
            throw ProviderClientError.http(status: 413, message: "Downloaded media exceeds size limit.")
        }
        return (data, httpResponse.mimeType)
    }

    private func performData(
        _ request: URLRequest,
        provider: ProviderConfiguration,
        apiKey: String?
    ) async throws -> (Data, HTTPURLResponse) {
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
            throw ProviderClientError.http(status: -1, message: redact(error.localizedDescription, provider: provider, apiKey: apiKey))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.http(status: -1, message: "Invalid HTTP response from media provider.")
        }
        return (data, httpResponse)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let msg = json["message"] as? String { return msg }
        return nil
    }

    private func redact(_ message: String, provider: ProviderConfiguration, apiKey: String?) -> String {
        let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
        return SecretMasker.redact(message, secrets: secrets)
    }

    private static func sniffMimeType(data: Data, fallback: String) -> String {
        if GeminiTTSClient.isValidWAVHeader(data) { return "audio/wav" }
        if data.count >= 3 && data.prefix(3) == Data([0x49, 0x44, 0x33]) { return "audio/mpeg" }
        if data.count >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 { return "audio/mpeg" }
        return fallback
    }
}
