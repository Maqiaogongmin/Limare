import Foundation

public final class OpenAIImageGenerationClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func generateImage(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        size: String? = nil,
        quality: String? = nil
    ) async throws -> OpenAIImageGenerationResponse {
        let endpointURL = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: provider.appendV1Suffix,
            endpoint: "images/generations"
        )

        // Attempt 1: with response_format = "b64_json"
        do {
            return try await sendRequest(
                endpointURL: endpointURL,
                provider: provider,
                apiKey: apiKey,
                modelID: modelID,
                prompt: prompt,
                size: size,
                quality: quality,
                includeResponseFormat: true
            )
        } catch let error as ProviderClientError {
            if case .http(let status, let message) = error, status == 400 {
                let lower = message.lowercased()
                if lower.contains("response_format") || lower.contains("b64_json") {
                    // Protocol compatibility retry: retry exactly once without response_format
                    return try await sendRequest(
                        endpointURL: endpointURL,
                        provider: provider,
                        apiKey: apiKey,
                        modelID: modelID,
                        prompt: prompt,
                        size: size,
                        quality: quality,
                        includeResponseFormat: false
                    )
                }
            }
            throw error
        }
    }

    private func sendRequest(
        endpointURL: URL,
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        prompt: String,
        size: String?,
        quality: String?,
        includeResponseFormat: Bool
    ) async throws -> OpenAIImageGenerationResponse {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 600.0

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var bodyDict: [String: Any] = [
            "model": modelID,
            "prompt": prompt,
            "n": 1,
        ]
        if let size = size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            bodyDict["size"] = size
        }
        if let quality = quality?.trimmingCharacters(in: .whitespacesAndNewlines), !quality.isEmpty {
            bodyDict["quality"] = quality
        }
        if includeResponseFormat {
            bodyDict["response_format"] = "b64_json"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

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
            throw ProviderClientError.http(status: -1, message: safeMsg)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderClientError.http(status: -1, message: "Invalid HTTP response from image generation provider.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? ""
            let parsedMessage = parseErrorMessage(from: data) ?? responseString
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMessage = SecretMasker.redact(parsedMessage, secrets: secrets)
            throw ProviderClientError.http(status: httpResponse.statusCode, message: safeMessage)
        }

        return try await parseImageGenerationResponse(data: data, statusCode: httpResponse.statusCode)
    }

    private func parseImageGenerationResponse(data: Data, statusCode: Int) async throws -> OpenAIImageGenerationResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw ProviderClientError.http(status: statusCode, message: "Invalid image generation response: missing data array.")
        }

        guard !dataArray.isEmpty else {
            throw ProviderClientError.http(status: statusCode, message: "Invalid image generation response: empty data array.")
        }

        guard let firstItem = dataArray.first else {
            throw ProviderClientError.http(status: statusCode, message: "Invalid image generation response: no image entry found.")
        }

        let revisedPrompt = firstItem["revised_prompt"] as? String
        let responseMime = firstItem["mime_type"] as? String

        if let b64String = firstItem["b64_json"] as? String {
            guard let imageData = Data(base64Encoded: b64String, options: [.ignoreUnknownCharacters]), !imageData.isEmpty else {
                throw ProviderClientError.http(status: statusCode, message: "Invalid or empty base64 payload in image generation response.")
            }
            if Int64(imageData.count) > AttachmentStore.maxGeneratedImageBytes {
                throw ProviderClientError.http(status: statusCode, message: "Generated image exceeds size limit.")
            }
            return OpenAIImageGenerationResponse(
                imageData: imageData,
                mimeType: responseMime,
                revisedPrompt: revisedPrompt
            )
        } else if let urlString = firstItem["url"] as? String {
            guard let parsedURL = URL(string: urlString),
                  let scheme = parsedURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw ProviderClientError.http(status: statusCode, message: "Invalid or unsupported image download URL scheme.")
            }

            let (downloadedData, downloadMime) = try await downloadImage(from: parsedURL)
            return OpenAIImageGenerationResponse(
                imageData: downloadedData,
                mimeType: responseMime ?? downloadMime,
                revisedPrompt: revisedPrompt
            )
        } else {
            throw ProviderClientError.http(status: statusCode, message: "No valid image data or URL in image generation response.")
        }
    }

    private func downloadImage(from url: URL) async throws -> (Data, String?) {
        var downloadRequest = URLRequest(url: url)
        downloadRequest.httpMethod = "GET"
        downloadRequest.timeoutInterval = 600.0

        // Clean request: Explicitly do not pass Authorization, api-key, or Provider Custom Headers
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: downloadRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let nsError as NSError where nsError.domain == "Swift.CancellationError" || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
            throw CancellationError()
        } catch {
            throw ProviderClientError.http(status: -1, message: "Failed to download generated image from remote URL.")
        }

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ProviderClientError.http(status: code, message: "Failed to download generated image (HTTP \(code)).")
        }

        if Int64(data.count) > AttachmentStore.maxGeneratedImageBytes {
            throw ProviderClientError.http(status: httpResponse.statusCode, message: "Generated image exceeds size limit.")
        }

        let mime = httpResponse.mimeType
        return (data, mime)
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return nil
    }
}
