import Foundation

/// URL boundary only; SDK owns OAuth code/state/issuer validation.
enum MCPCallbackURL {
    static func canonicalize(_ raw: URL, expected: URL) throws -> URL {
        guard var origin = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil,
              origin.user == nil, origin.password == nil else { throw MCPOAuthError.cancelled }
        origin.path = "/"
        origin.query = nil
        origin.fragment = nil
        guard let base = origin.url,
              let resolved = URL(string: raw.relativeString, relativeTo: base)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.scheme == expected.scheme, components.host == expected.host,
              components.port == expected.port, components.path == expected.path,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw MCPOAuthError.cancelled
        }
        return resolved
    }
}
