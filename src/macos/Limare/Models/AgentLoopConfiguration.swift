import Foundation

enum AgentLoopTerminationReason: LocalizedError, Sendable, Equatable {
    case turnLimitReached(limit: Int)
    case repeatedToolCall(name: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .turnLimitReached(let limit):
            "Agent reached its configured turn budget of \(limit) turns without finishing. This budget belongs to the agent's own policy, not to a global Harness default."
        case .repeatedToolCall(let name, let count):
            "Agent stopped because tool '\(name)' was repeatedly called with identical arguments \(count) times without progress."
        }
    }
}

/// The turn budget a Run carries into `AgentLoopEngine`.
///
/// A *turn* is one loop iteration: one model inference request plus the
/// assistant/tool output it produces. The engine's counter therefore advances
/// once per provider turn, not once per tool call — a single turn may contain
/// any number of tool calls.
///
/// The distinction matters because the two populations have different failure
/// semantics:
///
/// - A user-initiated Primary Run is an open-ended task. "It has taken N turns"
///   is not evidence of failure, so it has no ordinary fixed cap. It runs until
///   a real terminal cause appears: a final answer, user cancellation, an
///   unrecoverable provider error, Context Lifecycle exhaustion, a fatal
///   persistence error, a permission/policy boundary, or a detected no-progress
///   loop (the duplicate-call guard).
/// - An explicitly bounded Run (research Subagent, deterministic fixture)
///   carries a finite budget from its own policy. Exhausting that budget is a
///   truthful statement about *that* policy, and is reported as such.
enum AgentLoopTurnBudget: Sendable, Equatable {
    /// No ordinary fixed turn cap. Termination comes from real causes only.
    case unbounded
    /// A finite budget supplied by an explicit caller-owned policy.
    case bounded(maximumTurns: Int)
}

struct AgentLoopConfiguration: Sendable, Equatable {
    let turnBudget: AgentLoopTurnBudget
    let consecutiveDuplicateCallLimit: Int

    init(turnBudget: AgentLoopTurnBudget = .unbounded, consecutiveDuplicateCallLimit: Int = 3) {
        self.turnBudget = turnBudget
        self.consecutiveDuplicateCallLimit = consecutiveDuplicateCallLimit
    }

    /// Convenience for callers that already own an explicit finite policy
    /// budget (e.g. a subagent's allowance).
    init(maximumTurns: Int, consecutiveDuplicateCallLimit: Int = 3) {
        self.init(
            turnBudget: .bounded(maximumTurns: maximumTurns),
            consecutiveDuplicateCallLimit: consecutiveDuplicateCallLimit
        )
    }

    /// The configuration for user-initiated Primary Runs: no ordinary fixed
    /// turn cap, duplicate-call loop protection retained.
    static let standard = AgentLoopConfiguration(turnBudget: .unbounded, consecutiveDuplicateCallLimit: 3)
}
