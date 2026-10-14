import Foundation

/// Remote Access settings. None of these is a secret (the tunnel token lives in
/// `RemoteAccessSecrets`), so they are kept in UserDefaults.
struct RemoteAccessConfiguration: Equatable, Sendable {
    static let defaultPort = 47615

    var isEnabled: Bool
    /// The loopback port Limare serves on; the Cloudflare Tunnel route points at `http://127.0.0.1:<port>`.
    var port: Int
    /// The public hostname of the tunnel route, e.g. `limare.example.com`.
    var publicHostname: String
    /// The Cloudflare Zero Trust team, as `myteam`, `myteam.cloudflareaccess.com` or its URL.
    var teamDomain: String
    /// The Access application's AUD tag.
    var audienceTag: String
    /// The one person allowed in (the `email` claim of the Access token).
    var ownerEmail: String

    init(isEnabled: Bool = false, port: Int = Self.defaultPort, publicHostname: String = "", teamDomain: String = "",
         audienceTag: String = "", ownerEmail: String = "") {
        self.isEnabled = isEnabled
        self.port = port
        self.publicHostname = publicHostname
        self.teamDomain = teamDomain
        self.audienceTag = audienceTag
        self.ownerEmail = ownerEmail
    }

    /// Hostnames, team domains, AUD tags and email addresses never contain whitespace; a space
    /// typed or pasted into one would otherwise make every request fail the Access check.
    var normalized: RemoteAccessConfiguration {
        func squeeze(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        return RemoteAccessConfiguration(isEnabled: isEnabled, port: port, publicHostname: squeeze(publicHostname),
                                         teamDomain: squeeze(teamDomain), audienceTag: squeeze(audienceTag), ownerEmail: squeeze(ownerEmail))
    }

    /// `https://<team>.cloudflareaccess.com`: the token issuer, and where its signing keys are published.
    var teamIssuer: String {
        var team = teamDomain.filter { !$0.isWhitespace }.lowercased()
        for prefix in ["https://", "http://"] where team.hasPrefix(prefix) { team.removeFirst(prefix.count) }
        while team.hasSuffix("/") { team.removeLast() }
        if !team.hasSuffix(".cloudflareaccess.com") { team += ".cloudflareaccess.com" }
        return "https://\(team)"
    }

    var signingKeysURL: URL? { URL(string: "\(teamIssuer)/cdn-cgi/access/certs") }

    var normalizedHostname: String {
        publicHostname.filter { !$0.isWhitespace }.lowercased()
    }

    var publicOrigin: String { "https://\(normalizedHostname)" }

    /// What is still missing before Remote Access can run; empty when it can.
    var missingSettings: [String] {
        var missing: [String] = []
        if !(1024...65535).contains(port) { missing.append("port") }
        if normalizedHostname.isEmpty { missing.append("public hostname") }
        if teamDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("team domain") }
        if audienceTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("AUD tag") }
        if ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("owner email") }
        return missing
    }

    // MARK: - Persistence

    private enum Key {
        static let enabled = "remoteAccess.enabled"
        static let port = "remoteAccess.port"
        static let hostname = "remoteAccess.publicHostname"
        static let team = "remoteAccess.teamDomain"
        static let audience = "remoteAccess.audienceTag"
        static let owner = "remoteAccess.ownerEmail"
    }

    static func load(from defaults: UserDefaults = .standard) -> RemoteAccessConfiguration {
        return RemoteAccessConfiguration(
            isEnabled: defaults.bool(forKey: Key.enabled),
            port: defaults.object(forKey: Key.port) as? Int ?? defaultPort,
            publicHostname: defaults.string(forKey: Key.hostname) ?? "",
            teamDomain: defaults.string(forKey: Key.team) ?? "",
            audienceTag: defaults.string(forKey: Key.audience) ?? "",
            ownerEmail: defaults.string(forKey: Key.owner) ?? ""
        ).normalized
    }

    func save(to defaults: UserDefaults = .standard) {
        let configuration = normalized
        defaults.set(configuration.isEnabled, forKey: Key.enabled)
        defaults.set(configuration.port, forKey: Key.port)
        defaults.set(configuration.publicHostname, forKey: Key.hostname)
        defaults.set(configuration.teamDomain, forKey: Key.team)
        defaults.set(configuration.audienceTag, forKey: Key.audience)
        defaults.set(configuration.ownerEmail, forKey: Key.owner)
    }
}

/// Why a remote request was refused. Logged by name only; never with a token.
enum RemoteAccessRejection: String, Error, Sendable {
    case wrongHost
    case wrongOrigin
    case missingToken
    case invalidToken
    case wrongAudience
    case wrongIssuer
    case wrongUser
    case keysUnavailable
}

/// The request checks that need no cryptography.
enum RemoteAccessPolicy {
    /// The header Cloudflare Access puts the signed identity token in.
    static let tokenHeader = "Cf-Access-Jwt-Assertion"

    /// Requests must name the public hostname: anything else did not come through the tunnel
    /// (for example a page in a local browser trying DNS rebinding against the loopback port).
    static func check(host: String?, configuration: RemoteAccessConfiguration) -> RemoteAccessRejection? {
        guard let host, host.lowercased() == configuration.normalizedHostname else { return .wrongHost }
        return nil
    }

    /// WebSocket upgrades must come from the Remote page itself.
    static func check(origin: String?, configuration: RemoteAccessConfiguration) -> RemoteAccessRejection? {
        guard let origin, origin.lowercased() == configuration.publicOrigin else { return .wrongOrigin }
        return nil
    }

    /// The claims of a token whose signature already verified.
    static func check(audiences: [String], issuer: String, email: String?, configuration: RemoteAccessConfiguration) -> RemoteAccessRejection? {
        let configuration = configuration.normalized
        guard audiences.contains(configuration.audienceTag) else { return .wrongAudience }
        guard issuer == configuration.teamIssuer else { return .wrongIssuer }
        let owner = configuration.ownerEmail.lowercased()
        guard let email, email.lowercased() == owner else { return .wrongUser }
        return nil
    }

    /// Security headers for every Remote response. Caching is decided per response: the page is
    /// `no-store` (map §9.4), its static files revalidate (`no-cache`), see `cacheControl(path:current:)`.
    static let responseHeaders: [(String, String)] = [
        ("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
    ]

    /// An uploaded file's name as it may be stored: its last path component, without control
    /// characters or a leading dot, at most 255 bytes; "upload" if nothing is left.
    static func uploadFilename(_ raw: String?) -> String {
        let last = (raw ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(String.UnicodeScalarView(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > 255 { name.removeLast() }
        return name.isEmpty ? "upload" : name
    }

    /// `no-store` for the page and anything without a policy of its own; static files keep theirs.
    static func cacheControl(path: String, current: String?) -> String {
        if path == "/" || path.hasSuffix(".html") || current == nil { return "no-store" }
        return current!
    }
}
