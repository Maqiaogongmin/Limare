import Foundation

/// Turns transport errors into `MCPTransportError`, and failure kinds into what the UI shows.
enum MCPErrorClassifier {
    struct ClassifiedDetails: Sendable, Equatable {
        let explanation: String
        let recommendedAction: String
        let technicalDetails: String
    }

    /// The HTTP transport's request timeout: the SDK transport runs on a default URLSession configuration.
    static let httpRequestTimeoutSeconds = Int(URLSessionConfiguration.default.timeoutIntervalForRequest)

    /// Classifies an error thrown during MCP transport operations. The SDK reports HTTP failures only as
    /// message text ("Authentication required", "Server error: 503"), so this boundary is the one place
    /// that reads messages; everything after it works with the typed error and its `failureKind`.
    static func classify(_ error: Error, url: String? = nil) -> MCPTransportError {
        if let transportError = error as? MCPTransportError {
            return transportError
        }

        let desc = error.localizedDescription
        let lower = desc.lowercased()

        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("authentication required") || lower.contains("missing or invalid token") {
            return .authenticationRequired(
                message: "Authentication failed (401): the server rejected the request's credentials (\(desc))."
            )
        }

        if lower.contains("403") || lower.contains("forbidden") || lower.contains("access forbidden") || lower.contains("policy") {
            return .accessForbidden(
                message: "Access forbidden (403): the server refused this request (\(desc))."
            )
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout(seconds: httpRequestTimeoutSeconds)
            case .cannotFindHost, .dnsLookupFailed:
                return .networkUnreachable("DNS resolution failed: Host could not be found for \(url ?? "endpoint").")
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return .networkUnreachable("Network unreachable: Could not establish connection to \(url ?? "endpoint").")
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted:
                return .networkUnreachable("TLS/SSL security handshake failed with \(url ?? "endpoint").")
            default:
                return .networkUnreachable("Network error (\(urlError.code.rawValue)): \(urlError.localizedDescription)")
            }
        }

        if lower.contains("timed out") || lower.contains("timeout") {
            return .timeout(seconds: httpRequestTimeoutSeconds)
        }

        if lower.contains("cannot connect") || lower.contains("connection refused") || lower.contains("could not resolve host") {
            return .networkUnreachable("Could not reach endpoint: \(desc)")
        }

        if lower.contains("500") || lower.contains("502") || lower.contains("503") || lower.contains("504") || lower.contains("server error:") {
            return .serverError(code: 500, message: desc)
        }

        if lower.contains("protocol") || lower.contains("invalid json") || lower.contains("parse error") {
            return .protocolError(code: -32600, message: desc)
        }

        return .executionFailed(desc)
    }

    /// The three-level failure display in MCP settings.
    static func details(for kind: MCPFailureKind, message: String) -> ClassifiedDetails {
        let (explanation, action): (String, String) = switch kind {
        case .authentication:
            ("Authentication failed", "Sign in again, or replace the token this connection sends.")
        case .forbidden:
            ("Access forbidden (403)", "The account is signed in but not allowed to do this. Check its permissions with the server's provider.")
        case .network:
            ("Network unreachable", "Check that the endpoint is running, the URL is correct, and your network is connected.")
        case .timeout:
            ("Request timed out", "Check that the endpoint or process is responding within the expected time limit.")
        case .serverError:
            ("Remote server error", "The remote service encountered an error. Please try again later.")
        case .protocolError:
            ("MCP protocol error", "Verify server compatibility and protocol implementation.")
        case .processExited:
            ("Server process terminated", "Check command arguments, executable path, and required environment dependencies.")
        case .credentialStorage:
            ("Credential could not be saved", "Limare could not write to the Keychain. Try again, or check Keychain Access.")
        case .other:
            ("Connection failed", "Review the technical details and update the connection settings if needed.")
        }
        return ClassifiedDetails(explanation: explanation, recommendedAction: action, technicalDetails: message)
    }
}
