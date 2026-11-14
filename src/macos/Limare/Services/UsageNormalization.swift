import Foundation

enum UsageStatus: String, Sendable { case complete, partial, unknown }
enum UsageOutcome: String, Sendable { case completed, failed, cancelled }

struct NormalizedUsage: Sendable, Equatable {
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    var toolUsePrompt: Int?
    var providerTotal: Int?
    var status: UsageStatus = .unknown

    static func from(_ raw: ProviderUsageTelemetry?, format: ProviderAPIFormat, finished: Bool) -> Self {
        guard let raw, raw.hasAnyValue else { return Self() }
        var result = Self(cacheRead: raw.cacheReadTokens, cacheWrite: raw.cacheWriteTokens,
                          reasoning: raw.reasoningTokens, toolUsePrompt: raw.toolUsePromptTokens,
                          providerTotal: raw.totalTokens)
        switch format {
        case .chatCompletions, .responses:
            result.input = raw.inputTokens
            result.output = raw.outputTokens
        case .anthropicMessages:
            if let input = raw.inputTokens {
                result.input = input + (raw.cacheReadTokens ?? 0) + (raw.cacheWriteTokens ?? 0)
            }
            result.output = raw.outputTokens
        case .geminiNative:
            if let input = raw.inputTokens { result.input = input + (raw.toolUsePromptTokens ?? 0) }
            if raw.outputTokens != nil || raw.reasoningTokens != nil || (finished && raw.inputTokens != nil) {
                result.output = (raw.outputTokens ?? 0) + (raw.reasoningTokens ?? 0)
            }
        }
        result.status = finished && result.input != nil && result.output != nil ? .complete : .partial
        return result
    }

    /// Different dispatched attempts contribute separately; repeated frames have already been merged.
    mutating func add(_ other: Self) {
        func sum(_ a: Int?, _ b: Int?) -> Int? {
            switch (a, b) { case let (a?, b?): a + b; case let (a?, nil): a; case let (nil, b?): b; default: nil }
        }
        input = sum(input, other.input)
        output = sum(output, other.output)
        cacheRead = sum(cacheRead, other.cacheRead)
        cacheWrite = sum(cacheWrite, other.cacheWrite)
        reasoning = sum(reasoning, other.reasoning)
        toolUsePrompt = sum(toolUsePrompt, other.toolUsePrompt)
        providerTotal = sum(providerTotal, other.providerTotal)
    }
}

struct UsageRequestRecord: Sendable {
    var id = UUID()
    var providerID: UUID
    var providerName: String
    var modelID: String
    var modelName: String
    var format: ProviderAPIFormat
    var kind: UsageKind
    var startedAt = Date()
    var endedAt = Date()
    var outcome: UsageOutcome = .completed
    var attemptCount = 0
    var attemptsWithoutUsage = 0
    var usage = NormalizedUsage()
    private var incompleteAttempts = 0
    private var attemptsWithUsage = 0

    init(providerID: UUID, providerName: String, modelID: String, modelName: String, format: ProviderAPIFormat, kind: UsageKind) {
        self.providerID = providerID; self.providerName = providerName
        self.modelID = modelID; self.modelName = modelName; self.format = format; self.kind = kind
    }

    mutating func addAttempt(_ telemetry: ProviderUsageTelemetry?, finished: Bool, excluded: Bool) {
        guard !excluded else { return }
        let normalized = NormalizedUsage.from(telemetry, format: format, finished: finished)
        if normalized.status == .unknown { attemptsWithoutUsage += 1 }
        else { attemptsWithUsage += 1; usage.add(normalized) }
        if normalized.status != .complete { incompleteAttempts += 1 }
        usage.status = attemptsWithUsage == 0 ? .unknown : (incompleteAttempts == 0 ? .complete : .partial)
    }
}

/// Diagnostics callbacks are synchronous but can be invoked from a Sendable closure.
final class UsageAttemptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ProviderStreamDiagnostics?
    func update(_ diagnostics: ProviderStreamDiagnostics) { lock.withLock { current = diagnostics } }
    var diagnostics: ProviderStreamDiagnostics? { lock.withLock { current } }
}
