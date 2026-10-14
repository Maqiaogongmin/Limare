import Foundation

/// Readable failure categories for subagent operations; a few other stores reuse them.
enum DelegationFailure: String, Error, Codable, Sendable, LocalizedError {
    case invalidRequest, duplicateCommandConflict, admissionRejected, permissionDenied
    case resourceUnavailable, resourceWaiting, budgetExhausted, persistenceFailure
    case providerFailure, generationMismatch, executorLost, effectUnknown
    case unsupportedCapability, reconciliationRequired, resultNotReady

    var errorDescription: String? {
        let guidance: String
        switch self {
        case .invalidRequest: guidance = "the request is invalid; correct it and try again"
        case .duplicateCommandConflict: guidance = "the same identity was used with different content; nothing was done"
        case .admissionRejected: guidance = "this operation does not apply to the task in its current state"
        case .permissionDenied: guidance = "not allowed for this conversation; nothing was done"
        case .resourceUnavailable: guidance = "a required resource is unavailable"
        case .resourceWaiting: guidance = "the resource is busy; wait or cancel"
        case .budgetExhausted: guidance = "the task used its allowance; its final report is its result"
        case .persistenceFailure: guidance = "saving failed; try again once storage recovers"
        case .providerFailure: guidance = "the model provider failed"
        case .generationMismatch: guidance = "the task changed meanwhile; read its status first"
        case .executorLost: guidance = "the task's run is gone; continue it to start again"
        case .effectUnknown: guidance = "the effect of an interrupted action is unknown; check before retrying"
        case .unsupportedCapability: guidance = "not supported"
        case .reconciliationRequired: guidance = "the state needs checking before this operation"
        case .resultNotReady: guidance = "the task has no result yet"
        }
        return "delegation.\(rawValue): \(guidance)"
    }
}

/// A subagent's role decides its tools: research reads, coding gets the parent's tools.
enum SubagentRole: String, Codable, Sendable {
    case research, coding
}

enum SubagentStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted
    var isFinished: Bool { self != .queued && self != .running }
}

/// Model requests, tool calls and wall-clock seconds: a run's allowance, or what it spent.
struct SubagentAllowance: Codable, Sendable, Equatable {
    var modelRequests: Int
    var toolCalls: Int
    var seconds: TimeInterval
    static let zero = SubagentAllowance(modelRequests: 0, toolCalls: 0, seconds: 0)

    /// The numbers `task_effort` advertises: its turns, four tool calls per turn, its seconds.
    init(effort: AgentTaskEffortProfile) {
        self.init(modelRequests: effort.maximumTurns, toolCalls: effort.maximumTurns * 4, seconds: effort.maximumRuntimeSeconds)
    }

    init(modelRequests: Int, toolCalls: Int, seconds: TimeInterval) {
        self.modelRequests = modelRequests
        self.toolCalls = toolCalls
        self.seconds = seconds
    }
}

/// What a subagent reports: its `delegation_result`, or its last text.
struct SubagentResult: Codable, Sendable, Equatable {
    var summary: String
    var partial: Bool
    var changedFiles: [String] = []
    var openItems: [String] = []
}

/// One delegated task: a child conversation driven by the ordinary run engine.
struct SubagentTask: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let parentConversationID: UUID
    let childConversationID: UUID
    var title: String
    var goal: String
    var role: SubagentRole
    var allowWeb: Bool
    var allowance: SubagentAllowance
    var background: Bool
    var status: SubagentStatus
    /// The child's current (or last) run.
    var runID: UUID?
    /// What the current run has spent.
    var spent: SubagentAllowance = .zero
    /// What every run of this task has spent, including the current run. Optional so task files
    /// written before cumulative accounting remain decodable; their last known `spent` value is
    /// used as the migration baseline.
    var totalSpent: SubagentAllowance? = nil
    var result: SubagentResult?
    /// Why the task did not complete normally, in words.
    var failure: String?
    /// Instruction for the next run when the task is continued.
    var pendingInstruction: String?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    var cumulativeSpent: SubagentAllowance { totalSpent ?? spent }

    mutating func beginRun() {
        totalSpent = cumulativeSpent
        spent = .zero
    }

    mutating func countModelRequest() {
        var total = cumulativeSpent
        spent.modelRequests += 1
        total.modelRequests += 1
        totalSpent = total
    }

    mutating func countToolCall() {
        var total = cumulativeSpent
        spent.toolCalls += 1
        total.toolCalls += 1
        totalSpent = total
    }

    mutating func recordRunSeconds(_ seconds: TimeInterval) {
        let next = max(0, seconds)
        var total = cumulativeSpent
        total.seconds += max(0, next - spent.seconds)
        spent.seconds = next
        totalSpent = total
    }
}
