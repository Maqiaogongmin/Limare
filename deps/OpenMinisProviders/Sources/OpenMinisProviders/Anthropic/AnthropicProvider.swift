import Foundation
struct AnthropicProvider {
 let model: LLMModel
 let isOfficialAnthropicEndpoint: Bool
 let isClaudeCode = false
 let name = "Anthropic"
    static func parseClaudeVersion(_ modelId: String) -> (major: Int, minor: Int)? {
        let lower = modelId.lowercased()
        guard lower.contains("claude") else { return nil }
        // Accepts `claude-opus-4-7`, `claude-sonnet-4-6-thinking`,
        // `anthropic/claude-opus-4.7`, `claude-fable-5`, `claude-opus-5`, etc.
        // The minor group is optional but greedy, so `claude-3-5-sonnet` still
        // parses its first PAIR as (3,5) — never (3,0).
        let pattern = #"[-/]?(\d+)(?:[-.](\d+))?(?:\b|[^0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = regex.firstMatch(in: lower, range: range),
              match.numberOfRanges >= 3,
              let majorRange = Range(match.range(at: 1), in: lower),
              let major = Int(lower[majorRange]) else {
            return nil
        }
        // Group 2 (minor) is absent for single-segment versions → minor 0.
        let minor: Int
        if let minorRange = Range(match.range(at: 2), in: lower),
           let parsed = Int(lower[minorRange]) {
            minor = parsed
        } else {
            minor = 0
        }
        return (major, minor)
    }
    static func modelRejectsTemperature(_ modelId: String) -> Bool {
        guard let v = parseClaudeVersion(modelId) else { return false }
        return v.major > 4 || (v.major == 4 && v.minor >= 6)
    }
    static func modelUsesAdaptiveThinking(_ modelId: String) -> Bool {
        guard let v = parseClaudeVersion(modelId) else { return false }
        return v.major > 4 || (v.major == 4 && v.minor >= 6)
    }
    static func modelAcceptsExplicitThinkingDisabled(_ modelId: String) -> Bool {
        guard let v = parseClaudeVersion(modelId) else { return false }
        return v.major == 4 && v.minor >= 6
    }
}
