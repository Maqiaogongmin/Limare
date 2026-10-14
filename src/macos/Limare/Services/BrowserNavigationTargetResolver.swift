import Foundation

/// Resolution result for human-entered navigation target.
public enum BrowserTargetResolution: Equatable, Sendable {
    case empty
    case valid(URL)
    case invalid(String)
}

/// Parses and validates human-entered URL strings into valid web navigation targets.
/// Explicitly rejects natural language searches, preventing silent transmission to search engines.
public struct BrowserNavigationTargetResolver: Sendable {

    public static func resolve(_ rawInput: String) -> BrowserTargetResolution {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }

        // A local file, as a browser opens one: file://, an absolute path or ~/.
        if let fileURL = BrowserRuntime.localFileURL(trimmed) {
            if let problem = BrowserRuntime.localFileProblem(fileURL) { return .invalid(problem) }
            return .valid(fileURL)
        }

        // If it contains whitespace, it's natural language / search phrase, not a URL
        if trimmed.contains(where: { $0.isWhitespace }) {
            return .invalid("Enter a valid URL")
        }

        // Check explicit scheme with ://
        if let schemeColonRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeColonRange.lowerBound]).lowercased()
            guard ["http", "https"].contains(scheme) else {
                return .invalid("Unsupported URL scheme '\(scheme)://'. Use http://, https:// or a local file.")
            }
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
                return .invalid("Invalid URL: '\(trimmed)'")
            }
            return .valid(url)
        }

        // Check explicit non-http scheme without :// (e.g. javascript:, mailto:, file:)
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[..<colonIndex]).lowercased()
            if ["file", "javascript", "data", "ftp", "mailto", "about", "ssh", "tel"].contains(prefix) {
                return .invalid("Unsupported URL scheme '\(prefix):'. Use http://, https:// or a local file.")
            }
        }

        // Localhost or IPv4 loopback without scheme
        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            let urlString = "http://\(trimmed)"
            if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
                return .valid(url)
            } else {
                return .invalid("Invalid local URL: '\(trimmed)'")
            }
        }

        // Domain check (must have at least one dot in host portion, e.g. example.com, github.com/openai)
        let hostPart = trimmed.components(separatedBy: "/").first ?? trimmed
        let hostWithoutPort = hostPart.components(separatedBy: ":").first ?? hostPart

        if hostWithoutPort.contains(".") && !hostWithoutPort.hasPrefix(".") && !hostWithoutPort.hasSuffix(".") {
            let urlString = "https://\(trimmed)"
            if let url = URL(string: urlString), let host = url.host, !host.isEmpty {
                return .valid(url)
            }
        }

        return .invalid("Enter a valid URL")
    }
}
