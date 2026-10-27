import Foundation

enum EndpointBuilderError: LocalizedError, Equatable {
    case emptyBaseURL
    case invalidBaseURL
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .emptyBaseURL:
            String(localized: "Base URL is required.")
        case .invalidBaseURL:
            String(localized: "Base URL must be a complete URL with a host.")
        case .unsupportedScheme:
            String(localized: "Base URL must use HTTP or HTTPS.")
        }
    }
}

enum EndpointBuilder {
    static func endpoint(
        baseURL rawBaseURL: String,
        appendV1Suffix: Bool,
        endpoint: String
    ) throws -> URL {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EndpointBuilderError.emptyBaseURL }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw EndpointBuilderError.invalidBaseURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw EndpointBuilderError.unsupportedScheme
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }

        if appendV1Suffix {
            let finalComponent = path.split(separator: "/").last?.lowercased()
            if finalComponent != "v1" {
                path += "/v1"
            }
        }

        let endpointComponent = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "/" {
            path = "/\(endpointComponent)"
        } else {
            path += "/\(endpointComponent)"
        }
        components.percentEncodedPath = path

        guard let url = components.url else {
            throw EndpointBuilderError.invalidBaseURL
        }
        return url
    }

    static func displayPath(for url: URL) -> String {
        guard let host = url.host else { return url.path }
        return host + url.path
    }
}
