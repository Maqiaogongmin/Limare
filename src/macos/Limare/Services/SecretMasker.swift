import Foundation

/// The one registry of credential formats Limare recognises: redaction and detection share it, so a
/// format added here is both masked in output and rejected where credentials must not appear.
enum SecretMasker {
    private static let keyPatterns = [
        // Anthropic API keys (e.g. sk-ant-api03-abcdef1234567890)
        "sk-ant-[A-Za-z0-9_\\-]{10,}",
        // OpenAI API keys (e.g. sk-abcdef1234567890abcdef1234567890)
        "sk-[A-Za-z0-9_\\-]{20,}",
        // GitHub tokens (ghp_..., gho_..., ghu_..., ghs_..., ghr_...) and fine-grained PATs
        "gh[pousr]_[A-Za-z0-9_]{20,}",
        "github_pat_[A-Za-z0-9_]{20,}"
    ]

    /// `name=value` where the name says the value is a credential.
    private static let assignmentPattern =
        "(?i)\\b((?:access_token|api_key|apikey|key|token|secret|password|auth|pat)=)[^\\s&\"']+"

    /// True when `text` carries something that looks like a credential (anything `redactCredentials` masks).
    static func containsCredential(_ text: String) -> Bool {
        redactCredentials(text) != text
    }

    static func redact(_ message: String, secrets: [String]) -> String {
        secrets.reduce(message) { redacted, secret in
            guard !secret.isEmpty else { return redacted }
            return redacted.replacingOccurrences(of: secret, with: "••••")
        }
    }

    static func redactCredentials(_ message: String, secrets: [String] = []) -> String {
        var result = redact(message, secrets: secrets)

        // Redact Bearer tokens: "Authorization: Bearer <token>" or "Bearer <token>" -> "... Bearer ••••"
        if let bearerRegex = try? NSRegularExpression(pattern: "(?i)(bearer\\s+)[A-Za-z0-9\\-\\._~\\+\\/]+=*") {
            result = bearerRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1••••"
            )
        }

        // Redact credential assignments in query strings and arguments: "token=<value>" -> "token=••••"
        if let assignmentRegex = try? NSRegularExpression(pattern: assignmentPattern) {
            result = assignmentRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1••••"
            )
        }

        // Redact recognized API-key patterns
        for pattern in keyPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "••••"
                )
            }
        }

        return result
    }
}
