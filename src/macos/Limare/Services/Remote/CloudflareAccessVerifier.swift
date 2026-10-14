#if canImport(JWTKit)
import Foundation
import JWTKit

/// Verifies the Cloudflare Access token on every remote request (Cloudflare's "validate the
/// JWT at the origin"). Loopback is reachable by every local process, including shells the
/// agent starts; only a token Access signed for this application and this person gets in.
actor CloudflareAccessVerifier {
    struct Identity: Sendable {
        let email: String
        let expiresAt: Date
    }

    private struct Claims: JWTPayload {
        let aud: AudienceClaim
        let iss: IssuerClaim
        let exp: ExpirationClaim
        let email: String?

        func verify(using algorithm: some JWTAlgorithm) async throws {
            try exp.verifyNotExpired()
        }
    }

    private let configuration: RemoteAccessConfiguration
    private let fetchSigningKeys: @Sendable () async throws -> String
    private var keys: JWTKeyCollection?
    private var keysFetchedAt: Date?
    /// Keys rotate; a token that does not verify triggers one refetch, at most this often.
    private let refetchInterval: TimeInterval

    init(
        configuration: RemoteAccessConfiguration,
        refetchInterval: TimeInterval = 60,
        fetchSigningKeys: (@Sendable () async throws -> String)? = nil
    ) {
        self.configuration = configuration
        self.refetchInterval = refetchInterval
        let url = configuration.signingKeysURL
        self.fetchSigningKeys = fetchSigningKeys ?? {
            guard let url else { throw RemoteAccessRejection.keysUnavailable }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteAccessRejection.keysUnavailable }
            return String(decoding: data, as: UTF8.self)
        }
    }

    func verify(_ token: String) async throws(RemoteAccessRejection) -> Identity {
        let claims: Claims
        do {
            claims = try await verifiedClaims(token, refetchIfStale: true)
        } catch let rejection as RemoteAccessRejection {
            throw rejection
        } catch {
            throw .invalidToken
        }
        if let rejection = RemoteAccessPolicy.check(audiences: claims.aud.value, issuer: claims.iss.value,
                                                    email: claims.email, configuration: configuration) {
            throw rejection
        }
        return Identity(email: claims.email ?? "", expiresAt: claims.exp.value)
    }

    private func verifiedClaims(_ token: String, refetchIfStale: Bool) async throws -> Claims {
        let collection = try await currentKeys()
        do {
            return try await collection.verify(token, as: Claims.self)
        } catch {
            let stale = keysFetchedAt.map { Date().timeIntervalSince($0) >= refetchInterval } ?? true
            guard refetchIfStale, stale else { throw error }
            keys = nil
            return try await verifiedClaims(token, refetchIfStale: false)
        }
    }

    private func currentKeys() async throws -> JWTKeyCollection {
        if let keys { return keys }
        let json: String
        do {
            json = try await fetchSigningKeys()
        } catch {
            throw RemoteAccessRejection.keysUnavailable
        }
        let collection = JWTKeyCollection()
        do {
            try await collection.add(jwksJSON: json)
        } catch {
            throw RemoteAccessRejection.keysUnavailable
        }
        keys = collection
        keysFetchedAt = Date()
        return collection
    }
}
#endif
