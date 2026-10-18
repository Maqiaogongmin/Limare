import Foundation

/// The context budget of a conversation's next or latest provider request, for display only.
/// Never written into a request, a runtime event or the system prompt.
struct ContextUsageSnapshot: Equatable, Sendable {
    enum Provenance: Equatable, Sendable {
        case heuristic
        case calibrated(factor: Double)
    }

    /// What produced the estimate: the plan of a provider request in a run, or a preview of
    /// the next request while the conversation is idle (also after the Compact command).
    enum Origin: Equatable, Sendable {
        case request
        case preview
    }

    let conversationID: UUID
    let modelID: String
    let providerID: UUID?
    let estimatedInputTokens: Int
    let effectiveInputBudget: Int?
    let contextWindow: Int?
    let outputReserve: Int
    let toolReserve: Int
    let safetyReserve: Int
    let provenance: Provenance
    let origin: Origin
    var lastActualInputTokens: Int?
    var updatedAt: Date

    init(
        conversationID: UUID,
        modelID: String,
        providerID: UUID?,
        budget: ContextBudget,
        origin: Origin,
        lastActualInputTokens: Int?,
        updatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.modelID = modelID
        self.providerID = providerID
        self.estimatedInputTokens = budget.estimatedTokens
        self.effectiveInputBudget = budget.effectiveInputBudget
        self.contextWindow = budget.contextWindow
        self.outputReserve = budget.outputReserve
        self.toolReserve = budget.toolReserve
        self.safetyReserve = budget.safetyReserve
        let factor = budget.estimate.appliedCalibrationFactor
        self.provenance = factor > 1 ? .calibrated(factor: factor) : .heuristic
        self.origin = origin
        self.lastActualInputTokens = lastActualInputTokens
        self.updatedAt = updatedAt
    }
}
