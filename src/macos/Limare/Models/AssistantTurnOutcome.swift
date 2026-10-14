import Foundation

/// Provider facts are classified exactly once, at the AgentLoop turn boundary.
enum AssistantTurnOutcome: String, Sendable {
    case toolCalls, answer, outputLimited, contentFiltered, noOutput, reasoningOnly, streamIncomplete

    static func classify(text: String, reasoning: String?, hasToolCalls: Bool, diagnostics: ProviderStreamDiagnostics?, finishReason: String?) -> Self {
        let terminal = diagnostics?.completedReceived == true
        if hasToolCalls && terminal { return .toolCalls }
        switch finishReason {
        case "content_filter", "contentFilter", "refusal": return .contentFiltered
        case "length", "max_tokens", "max_output_tokens": return .outputLimited
        default: break
        }
        // G.0 qualification: both configured providers emit explicit terminal evidence.
        guard terminal else { return .streamIncomplete }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .answer }
        return (reasoning?.isEmpty == false) ? .reasoningOnly : .noOutput
    }
}

struct AssistantTurnError: LocalizedError, Sendable {
    let outcome: AssistantTurnOutcome
    let partialText: String
    let reasoning: String?
    let diagnostics: ProviderStreamDiagnostics?
    let finishReason: String?
    var errorDescription: String? {
        switch outcome {
        case .noOutput: return "The model returned no answer. Retry the request."
        case .reasoningOnly: return "The model returned reasoning without an answer. Retry the request."
        case .outputLimited: return "The model reached its output limit. The partial response was preserved."
        case .contentFiltered: return "The provider filtered the response. The request was stopped."
        case .streamIncomplete: return "The provider stream ended without a terminal marker. The partial response was preserved."
        case .answer, .toolCalls: return "Invalid assistant turn rejection."
        }
    }
    var isTransient: Bool { [.noOutput, .reasoningOnly, .streamIncomplete].contains(outcome) }
    var evidence: [String: String] {
        ["outcome": outcome.rawValue, "finishRaw": finishReason ?? "", "finishUnified": unifiedFinish,
         "textCharacters": "\(partialText.count)", "reasoningCharacters": "\(reasoning?.count ?? 0)",
         "terminalMarkerReceived": "\(diagnostics?.completedReceived == true)"]
    }
    private var unifiedFinish: String {
        switch finishReason {
        case "stop": return "stop"
        case "tool_calls", "function_call": return "toolCalls"
        case "length", "max_tokens", "max_output_tokens": return "length"
        case "content_filter", "contentFilter", "refusal": return "contentFilter"
        default: return "other"
        }
    }
}
