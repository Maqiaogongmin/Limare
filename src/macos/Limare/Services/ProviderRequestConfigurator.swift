import Foundation

public enum LimareUserAgent {
    public static var `default`: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        return "Limare/\(version)"
    }

    public static func resolve(customUserAgent: String?, extraHeaders: [String: String]) -> String {
        if let custom = customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        for (k, v) in extraHeaders {
            if k.caseInsensitiveCompare("User-Agent") == .orderedSame {
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return Self.default
    }
}

public enum ProviderRequestConfigurator {
    public static func modelsEndpoint(_ provider: ProviderConfiguration) throws -> URL {
        if let raw = provider.modelsURL, !raw.isEmpty {
            guard let components = URLComponents(string: raw), ["http", "https"].contains(components.scheme ?? ""),
                  components.host?.isEmpty == false, components.user == nil, components.password == nil,
                  components.fragment == nil, let url = components.url else { throw ProviderClientError.invalidModelsPayload }
            return url
        }
        return try EndpointBuilder.endpoint(baseURL: provider.baseURL, appendV1Suffix: provider.appendV1Suffix, endpoint: "models")
    }
    public static let reservedHeaderNames: Set<String> = [
        "authorization",
        "api-key",
        "x-api-key",
        "x-goog-api-key",
        "content-type",
        "accept",
        "host",
        "user-agent"
    ]

    public static func isReservedHeader(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return reservedHeaderNames.contains(lower)
    }

    public static func validateHeaderName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Header name cannot be empty."
        }
        if trimmed.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) {
            return "Header name cannot contain colons or newlines."
        }
        if isReservedHeader(trimmed) {
            return "'\(trimmed)' is a reserved header name."
        }
        return nil
    }

    public static func validateHeaderValue(_ value: String) -> String? {
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return "Header value cannot contain newlines."
        }
        return nil
    }

    public static func configureHeaders(
        request: inout URLRequest,
        provider: ProviderConfiguration,
        apiKey: String?,
        isChat: Bool
    ) {
        // 1. Apply allowed custom extraHeaders (filtering reserved & invalid/unsafe headers)
        for (name, value) in provider.extraHeaders {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty || isReservedHeader(trimmedName) {
                continue
            }
            if trimmedName.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) {
                continue
            }
            if trimmedName.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) {
                continue
            }
            if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
                continue
            }
            request.setValue(value, forHTTPHeaderField: trimmedName)
        }

        // 2. Apply Content-Type and Accept for Chat
        if isChat {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        // 3. Clear pre-existing authentication headers before setting mode-specific auth
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "api-key")
        request.setValue(nil, forHTTPHeaderField: "x-api-key")
        request.setValue(nil, forHTTPHeaderField: "x-goog-api-key")
        if provider.protocolAdapter == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        switch provider.authenticationMode {
        case .bearer, .oauth:
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                switch provider.apiFormat {
                case .anthropicMessages: request.setValue(key, forHTTPHeaderField: "x-api-key")
                case .geminiNative: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
            }
        case .azureAPIKey:
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "api-key")
            }
        case .none:
            break
        }

        // 4. Apply Effective User-Agent
        let effectiveUA = LimareUserAgent.resolve(
            customUserAgent: provider.customUserAgent,
            extraHeaders: provider.extraHeaders
        )
        request.setValue(effectiveUA, forHTTPHeaderField: "User-Agent")
    }
}
