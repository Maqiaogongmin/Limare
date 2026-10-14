import Foundation

/// Classification of token count measurements and estimates.
public enum TokenEstimateClassification: String, Sendable, Equatable, Codable {
    /// Pure local heuristic estimate based on byte/character fallback rules.
    case heuristicFallback
    /// Heuristic estimate adjusted by empirical provider usage feedback.
    case calibratedHeuristic
    /// Authoritative ground-truth count reported directly by the model provider.
    case authoritativeProviderUsage
}

/// Structured, epistemically classified token estimate.
public struct TokenEstimate: Sendable, Equatable, Codable {
    public let count: Int
    public let classification: TokenEstimateClassification
    public let appliedCalibrationFactor: Double

    public var isHeuristic: Bool {
        classification != .authoritativeProviderUsage
    }

    public init(
        count: Int,
        classification: TokenEstimateClassification = .heuristicFallback,
        appliedCalibrationFactor: Double = 1.0
    ) {
        self.count = max(0, count)
        self.classification = classification
        self.appliedCalibrationFactor = min(4.0, max(1.0, appliedCalibrationFactor))
    }
}

/// Authoritative token estimation engine used across Context Lifecycle and WorkingSet management.
enum ContextTokenEstimator {
    /// Standard fallback bytes-per-token heuristic: `max(0, (UTF8_bytes + 2) / 3)`
    static func rawEstimatedTokens(bytes: Int) -> Int {
        max(0, (bytes + 2) / 3)
    }

    static func rawEstimatedTokens(text: String) -> Int {
        rawEstimatedTokens(bytes: text.utf8.count)
    }

    /// Standard bounded image attachment byte accounting shared across Context Lifecycle (FIX-E04).
    public static let standardImageAttachmentByteCount: Int = 6_144

    /// Raw token cost of an image observation matching standard multimodal attachment accounting.
    public static func rawImageObservationTokens() -> Int {
        rawEstimatedTokens(bytes: standardImageAttachmentByteCount) + 12
    }

    static func rawMessageContentTokens(_ message: ChatMessage) -> Int {
        var bytes = message.content.lengthOfBytes(using: .utf8)
        bytes += (message.reasoningContent ?? "").lengthOfBytes(using: .utf8)
        for call in message.toolCalls {
            bytes += call.name.utf8.count + call.input.utf8.count + call.output.utf8.count
        }
        if let echo = message.responsesReasoningEcho {
            for item in echo.items {
                bytes += item.id.utf8.count
                for s in item.summary { bytes += s.utf8.count }
                if let enc = item.encryptedContent { bytes += enc.utf8.count }
            }
        }
        bytes += message.attachments.count * standardImageAttachmentByteCount
        return rawEstimatedTokens(bytes: bytes) + 12
    }

    static func rawTotalContentTokens(systemPrompt: String, messages: [ChatMessage]) -> Int {
        let sysRaw = rawEstimatedTokens(text: systemPrompt)
        let msgRaw = messages.reduce(0) { total, msg in
            total + rawMessageContentTokens(msg)
        }
        return sysRaw + msgRaw
    }

    /// Calibrated input estimation helper sharing consistent accounting across Context Lifecycle and WorkingSet management.
    ///
    /// Formula:
    /// - rawTotalInput = rawContentInputTokens + toolReserve
    /// - calibratedTotalInput = ceil(Double(rawTotalInput) * boundedFactor)
    /// - calibratedContentForBudget = max(0, calibratedTotalInput - toolReserve)
    ///
    /// `effectiveInputBudget` already excludes `toolReserve` once. Therefore, `toolReserve` is not double deducted.
    static func calibratedContentForBudget(
        rawContentInputTokens: Int,
        toolReserve: Int,
        factor: Double = 1.0
    ) -> (calibratedTotalInput: Int, calibratedContentForBudget: Int, estimate: TokenEstimate) {
        let rawContent = max(0, rawContentInputTokens)
        let tool = max(0, toolReserve)
        let boundedFactor = min(4.0, max(1.0, factor))
        let rawTotal = rawContent + tool
        let calibratedTotal = Int(ceil(Double(rawTotal) * boundedFactor))
        let calibratedContent = max(0, calibratedTotal - tool)
        let estimate = TokenEstimate(
            count: calibratedContent,
            classification: boundedFactor > 1.0 ? .calibratedHeuristic : .heuristicFallback,
            appliedCalibrationFactor: boundedFactor
        )
        return (calibratedTotal, calibratedContent, estimate)
    }

    static func calibratedContentForBudget(
        systemPrompt: String,
        messages: [ChatMessage],
        toolReserve: Int,
        factor: Double = 1.0
    ) -> (rawContentInputTokens: Int, calibratedTotalInput: Int, calibratedContentForBudget: Int, estimate: TokenEstimate) {
        let rawContent = rawTotalContentTokens(systemPrompt: systemPrompt, messages: messages)
        let result = calibratedContentForBudget(rawContentInputTokens: rawContent, toolReserve: toolReserve, factor: factor)
        return (rawContent, result.calibratedTotalInput, result.calibratedContentForBudget, result.estimate)
    }

    static func estimate(message: ChatMessage, factor: Double = 1.0) -> TokenEstimate {
        let rawTokens = rawMessageContentTokens(message)
        let boundedFactor = min(4.0, max(1.0, factor))
        let calibratedCount = Int(ceil(Double(rawTokens) * boundedFactor))
        let classification: TokenEstimateClassification = boundedFactor > 1.0 ? .calibratedHeuristic : .heuristicFallback
        return TokenEstimate(
            count: calibratedCount,
            classification: classification,
            appliedCalibrationFactor: boundedFactor
        )
    }

    static func estimateTotal(systemPrompt: String, messages: [ChatMessage], factor: Double = 1.0) -> TokenEstimate {
        let totalRaw = rawTotalContentTokens(systemPrompt: systemPrompt, messages: messages)
        let boundedFactor = min(4.0, max(1.0, factor))
        let calibratedCount = Int(ceil(Double(totalRaw) * boundedFactor))
        let classification: TokenEstimateClassification = boundedFactor > 1.0 ? .calibratedHeuristic : .heuristicFallback
        return TokenEstimate(
            count: calibratedCount,
            classification: classification,
            appliedCalibrationFactor: boundedFactor
        )
    }
}
