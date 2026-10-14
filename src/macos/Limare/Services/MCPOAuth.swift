import Foundation
import AppKit
#if canImport(MCP)
import MCP
#endif
#if canImport(AppAuth)
@preconcurrency import AppAuth
#endif

enum MCPOAuthError: LocalizedError {
    case unavailable
    case notOAuthServer(String)
    case clientRegistrationUnavailable
    case authorizationDenied(String)
    case cancelled
    case browserOpenFailed
    /// The authorization server issued a credential that Limare could not durably store.
    case credentialNotCommitted

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MCP OAuth is not available in this build."
        case .notOAuthServer(let reason):
            return reason
        case .clientRegistrationUnavailable:
            return "This server's authorization server does not support automatic client registration. Configure a self-owned, pre-registered OAuth client in the native setup UI. There is no automatic token fallback."
        case .authorizationDenied(let reason):
            return "Authorization was denied: \(reason)"
        case .cancelled:
            return "Sign-in was cancelled or timed out."
        case .browserOpenFailed:
            return "Could not open the browser for sign-in."
        case .credentialNotCommitted:
            return "The server may have completed sign-in, but Limare could not store the credential securely. Sign in again."
        }
    }
}

enum MCPOAuth {
    /// How long Limare waits for the user to finish a browser sign-in or paste a token.
    static let interactiveTimeoutSeconds: TimeInterval = 300

    /// OAuth applies to HTTP servers without a fixed Authorization header, at an endpoint the MCP
    /// authorization spec allows (HTTPS, or HTTP on loopback). Other servers keep the plain transport.
    static func appliesTo(_ config: MCPServerConfig) -> Bool {
        guard config.isHTTP, !config.hasStaticAuthorizationHeader,
              let urlString = config.url,
              let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }
}

// SDK OAuth is closed in this phase (MCPStore.oauthAdmitted). The frozen callback receiver below is
// kept for that phase; the token adapter is rebuilt then as the blueprint's §9.1 working-copy →
// native commit → acknowledgment chain, not on the former cache-first storage.

#if canImport(MCP)

/// Opens the authorization URL in the default browser and waits for the loopback redirect.
#if canImport(AppAuth)
final class MCPOAuthBrowserPresenter: OAuthAuthorizationDelegate, @unchecked Sendable {
    let receiver: MCPOAuthBoundReceiver
    init(receiver: MCPOAuthBoundReceiver) { self.receiver = receiver }
    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        try await receiver.receive(authorizationURL: url)
    }
}
#endif
#endif

#if canImport(AppAuth)
@MainActor
final class MCPOAuthBoundReceiver {
    let redirectURI: URL
    private let handler: OIDRedirectHTTPHandler
    private let session: MCPOAuthCallbackSession

    init() throws {
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var error: NSError?
        guard let address = LimareStartMCPRedirectListener(handler, &error), error == nil,
              var components = URLComponents(url: address, resolvingAgainstBaseURL: true),
              components.host == "127.0.0.1", components.port != nil else {
            handler.cancelHTTPListener()
            throw MCPOAuthError.unavailable
        }
        components.path = "/callback"
        components.query = nil
        guard let uri = components.url else { handler.cancelHTTPListener(); throw MCPOAuthError.unavailable }
        redirectURI = uri
        self.handler = handler
        session = MCPOAuthCallbackSession(expectedURI: uri)
        handler.currentAuthorizationFlow = session
    }

    func close() { handler.cancelHTTPListener(); session.cancel() }
    func receive(authorizationURL: URL, timeoutSeconds: Double = MCPOAuth.interactiveTimeoutSeconds) async throws -> URL {
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(timeoutSeconds)); close() }
            catch { }
        }
        defer { timeout.cancel(); close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.attach(continuation)
                if !NSWorkspace.shared.open(authorizationURL) {
                    session.failExternalUserAgentFlowWithError(MCPOAuthError.browserOpenFailed)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }
}
#endif

#if canImport(AppAuth)
/// Receives the loopback redirect. The SDK validates `state` and extracts the code; this only filters
/// out unrelated requests (favicon) and surfaces an authorization-server `error`.
private final class MCPOAuthCallbackSession: NSObject, OIDExternalUserAgentSession, @unchecked Sendable {
    private let expectedURI: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var completedResult: Result<URL, Error>?

    init(expectedURI: URL) {
        self.expectedURI = expectedURI
    }

    func attach(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(with: completedResult)
            return
        }
        guard self.continuation == nil else {
            lock.unlock()
            continuation.resume(throwing: MCPOAuthError.cancelled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard completedResult == nil else { lock.unlock(); return }
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() { finish(.failure(MCPOAuthError.cancelled)) }
    func cancel(completion: (() -> Void)?) { cancel(); completion?() }

    func resumeExternalUserAgentFlow(_ url: URL) throws {
        guard resumeExternalUserAgentFlow(with: url) else { throw MCPOAuthError.cancelled }
    }

    func resumeExternalUserAgentFlow(with url: URL) -> Bool {
        guard let canonical = try? MCPCallbackURL.canonicalize(url, expected: expectedURI) else { return false }
        finish(.success(canonical))
        return true
    }

    func failExternalUserAgentFlowWithError(_ error: Error) { finish(.failure(error)) }
}
#endif
