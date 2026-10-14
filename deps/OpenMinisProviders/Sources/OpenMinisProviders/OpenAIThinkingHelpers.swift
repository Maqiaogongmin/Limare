import Foundation
enum OpenAIAgentProvider {
    static func wireEffort(for level: ThinkingLevel) -> String {
        switch level {
        case .off: "none"
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        case .max, .ultra: "max"
        }
    }
    static func reasoningEffort(for model: LLMModel, level: ThinkingLevel = .medium) -> String? {
        guard model.supportsReasoning ?? false else { return nil }
        return switch level {
        case .off: nil
        case .minimal: "minimal"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        // [T-ios-ultra-effort-clamp] Ultra is a CLIENT-SIDE "Max + multi-agent
        // orchestration" toggle, not a server reasoning-effort tier. The wire
        // `reasoning.effort` field tops out at "max": ChatGPT/Codex compact
        // endpoints reject a literal "ultra" (400 invalid effort / silently
        // ignored), and CLIProxyAPI / sub2api both send "max" for Ultra (their
        // forwarding registries list levels only up to "max"; the "ultra" entry
        // is display-manifest-only and never enters the request body). So clamp
        // ultra → "max" here. If/when we implement the orchestration layer it
        // stays a local behavior; the effort string never becomes "ultra".
        case .max, .ultra: "max"
        }
    }
    static func clampEffort(_ effort: String, to values: [String]?) -> String {
        guard let values, !values.isEmpty else { return effort }
        if values.contains(effort) { return effort }
        // Canonical weakest → strongest ladder. Anything the catalog lists that
        // isn't on this ladder (unknown future tier) is ignored for ordering
        // purposes but still honored by the exact-match check above.
        let ladder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        guard let want = ladder.firstIndex(of: effort) else { return effort }
        let declared = values.compactMap { v in ladder.firstIndex(of: v).map { ($0, v) } }
            .sorted { $0.0 < $1.0 }
        guard !declared.isEmpty else { return effort }
        if let below = declared.last(where: { $0.0 <= want }) { return below.1 }
        return declared[0].1
    }
}
