import Foundation
import AppKit
#if canImport(AppAuth)
@preconcurrency import AppAuth
@preconcurrency import AppAuthCore
#endif
#if canImport(JWTKit)
import JWTKit
#endif

enum ProviderAuthenticationError: LocalizedError {
    case unavailable, cancelled, invalidIdentity, missingScope, failedExchange
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The required authentication library is unavailable.")
        case .cancelled: String(localized: "Authentication was cancelled.")
        case .invalidIdentity: String(localized: "The returned identity or authorization transaction could not be verified.")
        case .missingScope: String(localized: "This account did not authorize ChatGPT plan inference.")
        case .failedExchange: String(localized: "Authorization exchange failed. Start a new sign-in attempt.")
        }
    }
}

struct ProviderAuthenticationResult: Sendable {
    var apiKey: String?
    var archive: Data?
    var registration: ProviderOAuthRegistration?
    /// A readable account name (the verified email), never the opaque subject.
    var accountDisplay: String? = nil
}

/// Request-scoped library controller. All durable state is returned to ProviderStore.
@MainActor
final class ProviderAuthenticationService: NSObject {
    let selection: ProviderAuthenticationSelection

    init(selection: ProviderAuthenticationSelection) {
        self.selection = selection
        super.init()
    }
    private var timeoutTask: Task<Void, Never>?
    #if canImport(AppAuth)
    private var redirectHandler: OIDRedirectHTTPHandler?
    private var flow: (any OIDExternalUserAgentSession)?
    #endif

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        #if canImport(AppAuth)
        flow?.cancel()
        redirectHandler?.cancelHTTPListener()
        flow = nil
        redirectHandler = nil
        #endif
    }

    func authenticate(provider: ProviderConfiguration, hostID: String,
                      registration: ProviderOAuthRegistration? = nil) async throws -> ProviderAuthenticationResult {
        try ProviderProductPolicy.validate(provider)
        guard provider.authenticationSelection == selection else { throw ProviderConnectionError.invalidCredentialRoute }
        #if canImport(AppAuth)
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(300)); self?.cancel() }
            catch { /* Normal cancellation when the transaction ends. */ }
        }
        defer { cancel() }
        switch provider.authenticationSelection.acquisitionMethod {
        case .authorizationCodePKCE:
            return try await chatGPT(hostID: hostID, registration: registration)
        case .vendorWebAPIKey:
            return try await openRouter()
        default: throw ProviderConnectionError.invalidCredentialRoute
        }
        #else
        throw ProviderAuthenticationError.unavailable
        #endif
    }

    static func currentToken(archive: Data) throws -> String {
        #if canImport(AppAuth)
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive),
              let token = state.lastTokenResponse?.accessToken, !token.isEmpty else {
            throw ProviderCredentialStorageError.credentialMissing
        }
        return token
        #else
        throw ProviderAuthenticationError.unavailable
        #endif
    }

    /// The email in the ID token AppAuth archived at sign-in, where that token was signature-verified.
    /// Display only; a refresh response without an ID token yields nil.
    static func accountEmail(archive: Data) -> String? {
        #if canImport(AppAuth)
        guard let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive),
              let idToken = state.lastTokenResponse?.idToken ?? state.lastAuthorizationResponse.idToken,
              let email = OIDIDToken(idTokenString: idToken)?.claims["email"] as? String, !email.isEmpty else { return nil }
        return email
        #else
        return nil
        #endif
    }

    static func freshToken(archive: Data) async throws -> (token: String, archive: Data) {
        #if canImport(AppAuth)
        guard let state = try NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: archive) else {
            throw ProviderCredentialStorageError.invalidRecord
        }
        let token: String = try await withCheckedThrowingContinuation { continuation in
            state.performAction(freshTokens: { token, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let token, !token.isEmpty { continuation.resume(returning: token) }
                else { continuation.resume(throwing: ProviderCredentialStorageError.credentialMissing) }
            }, additionalRefreshParameters: ["resource": "https://api.openai.com/v1"])
        }
        try Task.checkCancellation()
        return (token, try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true))
        #else
        throw ProviderAuthenticationError.unavailable
        #endif
    }

    #if canImport(AppAuth)
    private func chatGPT(hostID: String, registration: ProviderOAuthRegistration?) async throws -> ProviderAuthenticationResult {
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let base = handler.startHTTPListener(&listenerError)
        if let listenerError { throw listenerError }
        let redirect = base.appendingPathComponent("auth/callback")
        redirectHandler = handler
        defer { cancel() }
        let config = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            tokenEndpoint: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        let clientID = registration?.issuedClientID ?? "dynamic_agent_client"
        var extra = ["resource": "https://api.openai.com/v1", "ext_agent_host_id": hostID]
        if registration == nil { extra["agent_name_hint"] = "Limare" }
        let request = OIDAuthorizationRequest(configuration: config, clientId: clientID,
            scopes: ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"],
            redirectURL: redirect, responseType: OIDResponseTypeCode, additionalParameters: extra)
        let response: OIDAuthorizationResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                flow = OIDAuthorizationService.present(request) { response, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let response { continuation.resume(returning: response) }
                    else { continuation.resume(throwing: ProviderAuthenticationError.failedExchange) }
                }
                handler.currentAuthorizationFlow = flow
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        let issued = response.additionalParameters?["client_id"] as? String ?? registration?.issuedClientID
        guard let issued, issued != "dynamic_agent_client",
              registration == nil || issued == registration?.issuedClientID,
              let code = response.authorizationCode else { throw ProviderAuthenticationError.invalidIdentity }
        let tokenRequest = OIDTokenRequest(configuration: config, grantType: OIDGrantTypeAuthorizationCode,
            authorizationCode: code, redirectURL: redirect, clientID: issued, clientSecret: nil,
            scopes: nil, refreshToken: nil, codeVerifier: request.codeVerifier,
            additionalParameters: ["resource": "https://api.openai.com/v1"])
        let tokens: OIDTokenResponse = try await withCheckedThrowingContinuation { continuation in
            OIDAuthorizationService.perform(tokenRequest) { response, error in
                if let error { continuation.resume(throwing: error) }
                else if let response { continuation.resume(returning: response) }
                else { continuation.resume(throwing: ProviderAuthenticationError.failedExchange) }
            }
        }
        guard let idToken = tokens.idToken, let nonce = request.nonce else { throw ProviderAuthenticationError.invalidIdentity }
        let identity = try await OpenAIIdentityVerifier.verify(idToken, clientID: issued, nonce: nonce)
        guard registration == nil || identity.subject == registration?.subject else { throw ProviderAuthenticationError.invalidIdentity }
        let scopes = (tokens.scope ?? "").split(separator: " ").map(String.init)
        guard scopes.contains("chatgpt.tokens.use.direct") else { throw ProviderAuthenticationError.missingScope }
        // AppAuth refresh uses lastAuthorizationResponse.request.clientID: bind it to the issued ID.
        let boundRequest = OIDAuthorizationRequest(configuration: config, clientId: issued, clientSecret: nil,
            scope: request.scope, redirectURL: redirect, responseType: request.responseType,
            state: request.state, nonce: request.nonce, codeVerifier: request.codeVerifier,
            codeChallenge: request.codeChallenge, codeChallengeMethod: request.codeChallengeMethod,
            additionalParameters: extra)
        let boundResponse = OIDAuthorizationResponse(request: boundRequest, parameters: ["code": code as NSString, "state": (request.state ?? "") as NSString])
        let state = OIDAuthState(authorizationResponse: boundResponse, tokenResponse: tokens)
        return ProviderAuthenticationResult(archive: try NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: true),
            registration: ProviderOAuthRegistration(issuedClientID: issued, issuer: "https://auth.openai.com",
                subject: identity.subject, workspaceID: identity.workspaceID, grantedScopes: scopes),
            accountDisplay: identity.email)
    }

    private func openRouter() async throws -> ProviderAuthenticationResult {
        let handler = OIDRedirectHTTPHandler(successURL: nil)
        var listenerError: NSError?
        let base = handler.startHTTPListener(&listenerError)
        if let listenerError { throw listenerError }
        let redirect = base.appendingPathComponent("callback")
        redirectHandler = handler
        defer { cancel() }
        guard let verifier = OIDTokenUtilities.randomURLSafeString(withSize: 64),
              let state = OIDAuthorizationRequest.generateState(),
              let challenge = OIDAuthorizationRequest.codeChallengeS256(forVerifier: verifier) else {
            throw ProviderAuthenticationError.failedExchange
        }
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [URLQueryItem(name: "callback_url", value: redirect.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "key_label", value: "Limare")]
        let result: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = VendorKeyCallbackSession(expectedState: state, continuation: continuation)
                flow = session
                handler.currentAuthorizationFlow = session
                guard NSWorkspace.shared.open(components.url!) else { session.cancel() ; return }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        let items = URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw ProviderAuthenticationError.failedExchange }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/auth/keys")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": verifier, "code_challenge_method": "S256"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let key = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String,
              !key.isEmpty else { throw ProviderAuthenticationError.failedExchange }
        return ProviderAuthenticationResult(apiKey: key)
    }
    #endif
}

#if canImport(AppAuth)
private final class VendorKeyCallbackSession: NSObject, OIDExternalUserAgentSession, @unchecked Sendable {
    private let expectedState: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    init(expectedState: String, continuation: CheckedContinuation<URL, Error>) {
        self.expectedState = expectedState
        self.continuation = continuation
    }
    private func take() -> CheckedContinuation<URL, Error>? {
        lock.lock(); defer { lock.unlock() }
        let value = continuation; continuation = nil; return value
    }
    func cancel() { take()?.resume(throwing: ProviderAuthenticationError.cancelled) }
    func cancel(completion: (() -> Void)?) { cancel(); completion?() }
    func resumeExternalUserAgentFlow(with url: URL) -> Bool {
        do { try resumeExternalUserAgentFlow(url); return true } catch { return false }
    }
    func resumeExternalUserAgentFlow(_ url: URL) throws {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { throw ProviderAuthenticationError.invalidIdentity }
        if items.contains(where: { $0.name == "error" }) { cancel(); return }
        take()?.resume(returning: url)
    }
    func failExternalUserAgentFlowWithError(_ error: Error) { take()?.resume(throwing: error) }
}
#endif

private enum OpenAIIdentityVerifier {
    struct Identity: Sendable { let subject: String; let workspaceID: String?; let email: String? }
    static func verify(_ token: String, clientID: String, nonce: String) async throws -> Identity {
        #if canImport(JWTKit)
        struct Claims: JWTPayload {
            let iss: IssuerClaim; let aud: AudienceClaim; let exp: ExpirationClaim
            let sub: String; let nonce: String?; let email: String?
            func verify(using algorithm: some JWTAlgorithm) async throws { try exp.verifyNotExpired() }
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderAuthenticationError.invalidIdentity }
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: String(decoding: data, as: UTF8.self))
        let claims = try await keys.verify(token, as: Claims.self)
        guard claims.iss.value == "https://auth.openai.com", claims.aud.value.contains(clientID),
              claims.nonce == nonce, !claims.sub.isEmpty else { throw ProviderAuthenticationError.invalidIdentity }
        return Identity(subject: claims.sub, workspaceID: nil, email: claims.email)
        #else
        throw ProviderAuthenticationError.unavailable
        #endif
    }
}
