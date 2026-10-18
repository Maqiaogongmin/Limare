import Foundation
import CryptoKit

/// Durable, inference-only state. Conversation records remain the complete user history.
struct ContextCompactionState: Codable, Sendable, Equatable {
    let conversationID: UUID
    let lastCompactedMessageID: UUID
    let summary: String
    let compactedMessageCount: Int
    let updatedAt: Date
    let sourcePrefixAnchorID: UUID?
    let sourcePrefixMessageCount: Int?
    let sourcePrefixDigest: String?

    init(
        conversationID: UUID,
        lastCompactedMessageID: UUID,
        summary: String,
        compactedMessageCount: Int,
        updatedAt: Date,
        sourcePrefixAnchorID: UUID? = nil,
        sourcePrefixMessageCount: Int? = nil,
        sourcePrefixDigest: String? = nil
    ) {
        self.conversationID = conversationID
        self.lastCompactedMessageID = lastCompactedMessageID
        self.summary = summary
        self.compactedMessageCount = compactedMessageCount
        self.updatedAt = updatedAt
        self.sourcePrefixAnchorID = sourcePrefixAnchorID ?? lastCompactedMessageID
        self.sourcePrefixMessageCount = sourcePrefixMessageCount ?? compactedMessageCount
        self.sourcePrefixDigest = sourcePrefixDigest
    }
}

struct ContextSourceSnapshot: Sendable, Equatable {
    let conversationID: UUID
    let messageCount: Int
    let anchorID: UUID?
    let digest: String
}

enum ContextPlanningControl: LocalizedError, Equatable {
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .sourceChanged: return "Canonical conversation source mutated during context planning."
        }
    }
}

enum ContextFailureKind: String, Codable, Sendable, Equatable {
    case protectedContextExhaustion
    case noSafeCompactionBoundary
    case recoveryExhaustion
    case providerAuthoritativeOverflow
    case derivedStatePersistenceFailure
}

struct ContextFailureMetrics: Sendable, Equatable {
    let estimatedTokens: Int?
    let effectiveBudget: Int?
    let contextWindow: Int?
    let stagesAttempted: Int?

    init(
        estimatedTokens: Int? = nil,
        effectiveBudget: Int? = nil,
        contextWindow: Int? = nil,
        stagesAttempted: Int? = nil
    ) {
        self.estimatedTokens = estimatedTokens
        self.effectiveBudget = effectiveBudget
        self.contextWindow = contextWindow
        self.stagesAttempted = stagesAttempted
    }
}

enum ContextDiagnosticEvent: Sendable, Equatable {
    case staleDerivedStateDiscarded(conversationID: UUID)
    case compactionStarted(stage: Int, boundary: Int)
    case compactionFallback(stage: Int, reason: String)
    case compactionSucceeded(stage: Int, boundary: Int)
}

@MainActor
final class ContextLifecycleStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let logs: DebugLogStore
    var atomicWriter: ((Data, URL) throws -> Void)? = nil

    init(storageRootURL: URL? = nil, fileManager: FileManager = .default, logs: DebugLogStore) {
        self.fileManager = fileManager
        self.logs = logs
        let root = storageRootURL ?? LimareStorage.applicationSupport
            .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        directoryURL = root.appendingPathComponent("context_lifecycle", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func load(conversationID: UUID) -> ContextCompactionState? {
        let url = fileURL(for: conversationID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(ContextCompactionState.self, from: Data(contentsOf: url))
            guard state.conversationID == conversationID else {
                logs.error("ContextLifecycle", "Discarded compact state with mismatched conversation ownership.")
                try? fileManager.removeItem(at: url)
                return nil
            }
            return state
        } catch {
            logs.error("ContextLifecycle", "Discarded unreadable compact state for conversation '\(conversationID.uuidString.prefix(8))'.")
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    func save(_ state: ContextCompactionState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let url = fileURL(for: state.conversationID)
        if let atomicWriter {
            try atomicWriter(data, url)
        } else {
            try data.write(to: url, options: .atomic)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func discard(conversationID: UUID) {
        try? fileManager.removeItem(at: fileURL(for: conversationID))
    }

    func fileURL(for conversationID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(conversationID.uuidString).json")
    }
}

struct ContextCalibrationBaseline: Sendable, Equatable {
    let rawContentInputTokens: Int
    let toolReserve: Int
    var rawTotalInputTokens: Int {
        rawContentInputTokens + toolReserve
    }

    init(rawContentInputTokens: Int, toolReserve: Int) {
        self.rawContentInputTokens = max(0, rawContentInputTokens)
        self.toolReserve = max(0, toolReserve)
    }
}

struct ContextBudget: Sendable, Equatable {
    let contextWindow: Int?
    let estimatedTokens: Int
    let estimate: TokenEstimate
    let effectiveInputBudget: Int?
    let outputReserve: Int
    let toolReserve: Int
    let safetyReserve: Int
    let targetBudgetRatio: Double
    let calibrationBaseline: ContextCalibrationBaseline

    var needsCompaction: Bool {
        guard let effectiveInputBudget else { return false }
        return estimatedTokens > effectiveInputBudget
    }

    init(
        contextWindow: Int?,
        estimatedTokens: Int,
        effectiveInputBudget: Int?,
        outputReserve: Int,
        toolReserve: Int,
        safetyReserve: Int,
        estimate: TokenEstimate? = nil,
        targetBudgetRatio: Double = ContextWorkingSetManager.defaultTargetBudgetRatio,
        calibrationBaseline: ContextCalibrationBaseline? = nil
    ) {
        self.contextWindow = contextWindow
        self.estimatedTokens = estimatedTokens
        self.estimate = estimate ?? TokenEstimate(count: estimatedTokens)
        self.effectiveInputBudget = effectiveInputBudget
        self.outputReserve = outputReserve
        self.toolReserve = toolReserve
        self.safetyReserve = safetyReserve
        self.targetBudgetRatio = targetBudgetRatio
        self.calibrationBaseline = calibrationBaseline ?? ContextCalibrationBaseline(rawContentInputTokens: estimatedTokens, toolReserve: toolReserve)
    }
}

struct ContextLifecycleResult: Sendable {
    let messages: [ChatMessage]
    let state: ContextCompactionState?
    let budget: ContextBudget
    let reductionReport: ContextReductionReport?
    let didCompactThisCall: Bool
    let didReduceWorkingSetThisCall: Bool
    let attemptedBoundaries: [Int]
    let diagnostics: [ContextDiagnosticEvent]
    /// The estimate before reduction and compaction, when this call compacted.
    var estimatedTokensBefore: Int?

    init(
        messages: [ChatMessage],
        state: ContextCompactionState?,
        budget: ContextBudget,
        reductionReport: ContextReductionReport? = nil,
        didCompactThisCall: Bool = false,
        didReduceWorkingSetThisCall: Bool = false,
        attemptedBoundaries: [Int] = [],
        diagnostics: [ContextDiagnosticEvent] = []
    ) {
        self.messages = messages
        self.state = state
        self.budget = budget
        self.reductionReport = reductionReport
        self.didCompactThisCall = didCompactThisCall
        self.didReduceWorkingSetThisCall = didReduceWorkingSetThisCall
        self.attemptedBoundaries = attemptedBoundaries
        self.diagnostics = diagnostics
    }
}

/// Pure policy plus a small transactional coordinator. It intentionally never edits ChatMessage history.
@MainActor
final class ContextLifecycle {
    typealias ContextCommitAuthority = @MainActor () -> Bool

    private let store: ContextLifecycleStore
    private let logs: DebugLogStore
    nonisolated static let maximumSummaryCharacters = 12_000

    init(store: ContextLifecycleStore, logs: DebugLogStore) {
        self.store = store
        self.logs = logs
    }

    nonisolated static func computePrefixDigest(_ prefix: [ChatMessage]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(prefix) else { return "" }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func validateProvenance(state: ContextCompactionState, messages: [ChatMessage]) -> Bool {
        guard let digest = state.sourcePrefixDigest, !digest.isEmpty else { return false }
        let anchorID = state.sourcePrefixAnchorID ?? state.lastCompactedMessageID
        let count = state.sourcePrefixMessageCount ?? state.compactedMessageCount
        guard count > 0, messages.count >= count else { return false }
        guard messages[count - 1].id == anchorID else { return false }
        let prefix = Array(messages.prefix(count))
        guard computePrefixDigest(prefix) == digest else { return false }
        return true
    }

    private func validateSourceSnapshot(
        conversationID: UUID,
        stageBoundary: Int,
        messages: [ChatMessage],
        sourceSnapshotValidator: (@MainActor (ContextSourceSnapshot) -> Bool)?
    ) throws {
        try Task.checkCancellation()
        if let sourceSnapshotValidator {
            guard stageBoundary > 0 && stageBoundary <= messages.count else {
                throw ContextPlanningControl.sourceChanged
            }
            let anchorID = messages[stageBoundary - 1].id
            let prefix = Array(messages[0..<stageBoundary])
            let digest = Self.computePrefixDigest(prefix)
            let snap = ContextSourceSnapshot(
                conversationID: conversationID,
                messageCount: stageBoundary,
                anchorID: anchorID,
                digest: digest
            )
            guard sourceSnapshotValidator(snap) else {
                throw ContextPlanningControl.sourceChanged
            }
        }
    }

    private func validateActivePlanningSnapshot(
        conversationID: UUID,
        stageBoundary: Int,
        messages: [ChatMessage],
        sourceSnapshotValidator: (@MainActor (ContextSourceSnapshot) -> Bool)?,
        commitAuthority: ContextCommitAuthority
    ) throws {
        try validateSourceSnapshot(
            conversationID: conversationID, stageBoundary: stageBoundary,
            messages: messages, sourceSnapshotValidator: sourceSnapshotValidator
        )
        guard commitAuthority() else {
            logs.error("ContextLifecycle", "Planning rejected: mutation authority invalid or revoked for conversation '\(conversationID.uuidString.prefix(8))'.")
            throw ContextLifecycleError.commitAuthorityRevoked
        }
    }

    /// The budget the next request starts from, for display: the same assembly and estimate as
    /// the start of `workingMessages`, without its writes. A stale summary is left for the
    /// next request to discard and is not counted here.
    func previewBudget(
        conversationID: UUID,
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ChatToolDefinition],
        options: ChatInferenceOptions,
        calibrationFactor: Double = 1.0
    ) -> ContextBudget {
        let state = store.load(conversationID: conversationID).flatMap {
            Self.validateProvenance(state: $0, messages: messages) ? $0 : nil
        }
        var hints = ContextProtectionHints()
        hints.acknowledgedToolCallIDs = ContextWorkingSetManager.acknowledgedToolCallIDs(in: messages)
        let current = assemble(messages: messages, state: state, protectionHints: hints)
        let budget = Self.makeBudget(
            systemPrompt: systemPrompt,
            messages: current,
            tools: tools,
            options: options,
            factor: calibrationFactor
        )
        // Past the soft threshold a request reduces its working set before it is sent
        // (`workingMessages`), so the preview measures the reduced one. Compaction, which
        // needs a model call, is not previewed: a budget still over the limit means it.
        guard let effectiveBudget = budget.effectiveInputBudget,
              budget.estimatedTokens > max(1, Int(Double(effectiveBudget) * ContextWorkingSetManager.softThresholdRatio))
        else { return budget }
        return Self.reduce(
            current,
            budget: budget,
            effectiveBudget: effectiveBudget,
            systemPrompt: systemPrompt,
            tools: tools,
            options: options,
            protocolContext: WorkingSetProtocolContext(
                apiFormat: options.apiFormat,
                providerID: options.providerID,
                modelID: options.model?.id
            ),
            calibrationFactor: calibrationFactor,
            targetBudgetRatio: ContextWorkingSetManager.defaultTargetBudgetRatio,
            protectionHints: hints
        ).budget
    }

    /// The deterministic working-set reduction a request runs past the soft threshold, and
    /// the budget of what it leaves.
    private static func reduce(
        _ current: [ChatMessage],
        budget: ContextBudget,
        effectiveBudget: Int,
        systemPrompt: String,
        tools: [ChatToolDefinition],
        options: ChatInferenceOptions,
        protocolContext: WorkingSetProtocolContext,
        calibrationFactor: Double,
        targetBudgetRatio: Double,
        protectionHints: ContextProtectionHints
    ) -> (messages: [ChatMessage], report: ContextReductionReport, budget: ContextBudget) {
        let (reduced, report) = ContextWorkingSetManager.reduceWorkingSet(
            messages: current,
            systemPrompt: systemPrompt,
            effectiveInputBudget: effectiveBudget,
            toolReserve: budget.toolReserve,
            protocolContext: protocolContext,
            calibrationFactor: calibrationFactor,
            targetBudgetRatio: targetBudgetRatio,
            protectionHints: protectionHints
        )
        let reducedBudget = makeBudget(
            systemPrompt: systemPrompt,
            messages: reduced,
            tools: tools,
            options: options,
            factor: calibrationFactor,
            targetBudgetRatio: targetBudgetRatio
        )
        return (reduced, report, reducedBudget)
    }

    func workingMessages(
        conversationID: UUID,
        messages: [ChatMessage],
        systemPrompt: String,
        tools: [ChatToolDefinition],
        options: ChatInferenceOptions,
        modelID: String,
        calibrationFactor: Double = 1.0,
        targetBudgetRatio: Double = ContextWorkingSetManager.defaultTargetBudgetRatio,
        protectionHints: ContextProtectionHints = ContextProtectionHints(),
        compactorConfig: SemanticCompactorConfiguration = SemanticCompactorConfiguration(),
        semanticCompactor: (any ContextSemanticCompacting)? = nil,
        candidateProviderID: String? = nil,
        apiKey: String? = nil,
        extraHeaders: [String: String] = [:],
        secrets: [String] = [],
        sourceSnapshotValidator: (@MainActor (ContextSourceSnapshot) -> Bool)? = nil,
        forceCompaction: Bool = false,
        commitAuthority: @escaping ContextCommitAuthority
    ) async throws -> ContextLifecycleResult {
        // `forceCompaction` is the user's Compact command (Claude Code's and Codex's /compact):
        // everything up to now is summarized in one stage, whatever the budget; the mandatory
        // units of a run in progress stay verbatim, as in automatic compaction.
        var diagnostics: [ContextDiagnosticEvent] = []

        var state = store.load(conversationID: conversationID)
        if let loadedState = state {
            if !Self.validateProvenance(state: loadedState, messages: messages) {
                logs.error("ContextLifecycle", "Discarded stale or unverified compact state for conversation '\(conversationID.uuidString.prefix(8))'.")
                store.discard(conversationID: conversationID)
                state = nil
                diagnostics.append(.staleDerivedStateDiscarded(conversationID: conversationID))
            }
        }

        var planningHints = protectionHints
        planningHints.acknowledgedToolCallIDs = ContextWorkingSetManager.acknowledgedToolCallIDs(in: messages)
        let current = assemble(messages: messages, state: state, protectionHints: planningHints)
        let budget = Self.makeBudget(
            systemPrompt: systemPrompt,
            messages: current,
            tools: tools,
            options: options,
            factor: calibrationFactor,
            targetBudgetRatio: targetBudgetRatio
        )
        // The Compact command does not depend on the window; an unknown one just never binds.
        let unboundedBudget = forceCompaction ? Int(Int32.max) : nil
        guard let contextWindow = budget.contextWindow ?? unboundedBudget,
              let effectiveBudget = budget.effectiveInputBudget ?? unboundedBudget else {
            logs.info("ContextLifecycle", "Capacity unknown for model '\(modelID)'; skipped proactive compaction.")
            return ContextLifecycleResult(
                messages: current,
                state: state,
                budget: budget,
                reductionReport: nil,
                didCompactThisCall: false,
                didReduceWorkingSetThisCall: false,
                attemptedBoundaries: [],
                diagnostics: diagnostics
            )
        }

        let softBudget = max(1, Int(Double(effectiveBudget) * ContextWorkingSetManager.softThresholdRatio))

        // Check if estimated tokens is within soft budget
        if !forceCompaction && budget.estimatedTokens <= softBudget {
            logs.info("ContextLifecycle", "model=\(modelID) window=\(contextWindow) estimated=\(budget.estimatedTokens) budget=\(effectiveBudget) soft=\(softBudget) factor=\(calibrationFactor) reduce=false compact=false")
            return ContextLifecycleResult(
                messages: current,
                state: state,
                budget: budget,
                reductionReport: nil,
                didCompactThisCall: false,
                didReduceWorkingSetThisCall: false,
                attemptedBoundaries: [],
                diagnostics: diagnostics
            )
        }

        let protocolContext = WorkingSetProtocolContext(
            apiFormat: options.apiFormat,
            providerID: options.providerID,
            modelID: options.model?.id ?? modelID
        )

        // Soft threshold or hard threshold exceeded: execute WorkingSet Reduction first
        let (reducedWorking, reductionReport, afterReductionBudget) = Self.reduce(
            current,
            budget: budget,
            effectiveBudget: effectiveBudget,
            systemPrompt: systemPrompt,
            tools: tools,
            options: options,
            protocolContext: protocolContext,
            calibrationFactor: calibrationFactor,
            targetBudgetRatio: targetBudgetRatio,
            protectionHints: planningHints
        )
        let didReduce = reductionReport.didReduce

        // If WorkingSet reduction brought context within hard budget (and towards soft/target budget), proceed without compaction
        if !forceCompaction && !afterReductionBudget.needsCompaction {
            logs.info("ContextLifecycle", "model=\(modelID) window=\(contextWindow) estimatedBefore=\(budget.estimatedTokens) afterReduction=\(afterReductionBudget.estimatedTokens) budget=\(effectiveBudget) factor=\(calibrationFactor) reduced=\(didReduce) compact=false")
            return ContextLifecycleResult(
                messages: reducedWorking,
                state: state,
                budget: afterReductionBudget,
                reductionReport: didReduce ? reductionReport : nil,
                didCompactThisCall: false,
                didReduceWorkingSetThisCall: didReduce,
                attemptedBoundaries: [],
                diagnostics: diagnostics
            )
        }

        // Check for safe compaction boundaries between priorBoundary and tailStart
        let priorBoundary = state.flatMap { old in
            let anchorID = old.sourcePrefixAnchorID ?? old.lastCompactedMessageID
            return messages.firstIndex(where: { $0.id == anchorID }).map { $0 + 1 }
        } ?? 0
        let tailStart = forceCompaction ? messages.count : ContextWorkingSetManager.ordinaryTailStartIndex(
            in: messages, effectiveInputBudget: effectiveBudget, calibrationFactor: calibrationFactor
        )
        let hardBlockerIndices = Self.findCompactionHardBlockerIndices(in: messages)

        func isSafeCompactionBoundary(_ b: Int) -> Bool {
            guard b > priorBoundary && b <= tailStart else { return false }
            // Slice priorBoundary..<b must contain ZERO active/in-flight hard blockers
            for idx in priorBoundary..<b {
                if hardBlockerIndices.contains(idx) {
                    return false
                }
            }
            return true
        }

        let eligibleSafeBoundaries: [Int]
        if tailStart > priorBoundary {
            eligibleSafeBoundaries = (priorBoundary + 1...tailStart).filter { isSafeCompactionBoundary($0) }
        } else {
            eligibleSafeBoundaries = []
        }
        if tailStart > priorBoundary && eligibleSafeBoundaries.isEmpty {
            throw ContextLifecycleError.noSafeCompactionBoundary
        }

        // Evaluate irreducible protected semantic footprint (CTX-D1)
        let irreducibleIndices = ContextWorkingSetManager.mandatoryFloorIndices(in: messages, protectionHints: planningHints)
        // Measure the same reduced projection used above. A subset-only reduction would
        // erase later provider turns and falsely treat acknowledged results as raw floor.
        let floorIDs = Set(irreducibleIndices.map { messages[$0].id })
        let reducedIrreducible = reducedWorking.filter { floorIDs.contains($0.id) }
        let protectedFootprintBudget = Self.makeBudget(
            systemPrompt: systemPrompt,
            messages: reducedIrreducible,
            tools: tools,
            options: options,
            factor: calibrationFactor,
            targetBudgetRatio: targetBudgetRatio
        )
        if protectedFootprintBudget.needsCompaction {
            throw ContextLifecycleError.protectedContextExhaustion(
                details: ContextFailureMetrics(
                    estimatedTokens: protectedFootprintBudget.estimatedTokens,
                    effectiveBudget: effectiveBudget,
                    contextWindow: contextWindow,
                    stagesAttempted: 0
                )
            )
        }

        guard !eligibleSafeBoundaries.isEmpty && tailStart > priorBoundary else {
            if forceCompaction { throw ContextLifecycleError.nothingToCompact }
            throw ContextLifecycleError.recoveryExhaustion(
                details: ContextFailureMetrics(
                    estimatedTokens: afterReductionBudget.estimatedTokens,
                    effectiveBudget: effectiveBudget,
                    contextWindow: contextWindow,
                    stagesAttempted: 0
                )
            )
        }

        let eligibleCount = tailStart - priorBoundary

        // Active secrets collation for strict CTX-I16 redaction across all candidates
        var allActiveSecrets = secrets
        if let apiKey, !apiKey.isEmpty { allActiveSecrets.append(apiKey) }
        for (_, headerVal) in extraHeaders where !headerVal.isEmpty {
            allActiveSecrets.append(headerVal)
        }

        var stage = 0
        var stoppedByActiveBlocker = false
        var currentCompactedCount = priorBoundary
        var currentSummary = state?.summary
        var lastEstimatedTokens = afterReductionBudget.estimatedTokens
        var candidateState: ContextCompactionState?
        var compactedWorking = reducedWorking
        var finalBudget = afterReductionBudget
        var attemptedBoundaries: [Int] = []
        // A failed compactor call has already spent the provider client's retry budget; calling the
        // same provider again for the next stage would spend it once per stage before the turn's own
        // request is sent. After one failure the rest of this pass summarizes deterministically.
        var semanticCompactorFailed = false

        let maxStages = forceCompaction ? 1 : max(1, compactorConfig.maxStages)

        while stage < maxStages && currentCompactedCount < tailStart {
            let availableBoundaries = eligibleSafeBoundaries.filter { $0 > currentCompactedCount }
            guard !availableBoundaries.isEmpty else {
                stoppedByActiveBlocker = true
                break
            }

            // Progressive linear boundary calculation strictly bounded by eligible safe boundaries
            let stageBoundary: Int
            if stage == maxStages - 1 {
                stageBoundary = availableBoundaries.last!
            } else {
                let fraction = Double(stage + 1) / Double(maxStages)
                let target = priorBoundary + Int(round(Double(eligibleCount) * fraction))
                stageBoundary = availableBoundaries.last(where: { $0 <= target }) ?? availableBoundaries.first!
            }

            guard stageBoundary > currentCompactedCount else {
                break
            }

            attemptedBoundaries.append(stageBoundary)
            diagnostics.append(.compactionStarted(stage: stage + 1, boundary: stageBoundary))

            // Mandatory units are carried verbatim by `assemble`; do not also
            // summarize them into background prose that could contradict their
            // terminal states or duplicate admitted instructions.
            let sliceToCompact = (currentCompactedCount..<stageBoundary)
                .filter { !irreducibleIndices.contains($0) }
                .map { messages[$0] }
            let anchorID = messages[stageBoundary - 1].id
            let prefix = Array(messages[0..<stageBoundary])
            let digest = Self.computePrefixDigest(prefix)

            var candidateForStage: ContextCompactionState? = nil
            var candidateBudgetForStage: ContextBudget? = nil
            var candidateWorkingForStage: [ChatMessage]? = nil

            // 1. Try semantic compactor if available
            if let semanticCompactor, !semanticCompactorFailed {
                // Revalidate snapshot & ownership prior to semantic async dispatch
                try validateActivePlanningSnapshot(
                    conversationID: conversationID,
                    stageBoundary: stageBoundary,
                    messages: messages,
                    sourceSnapshotValidator: sourceSnapshotValidator,
                    commitAuthority: commitAuthority
                )

                do {
                    let rawSemantic = try await semanticCompactor.compact(
                        previousSummary: currentSummary,
                        messages: sliceToCompact,
                        candidateOptions: options,
                        candidateProviderID: candidateProviderID ?? options.providerID?.uuidString ?? "unknown",
                        candidateModelID: options.model?.id ?? modelID,
                        apiKey: apiKey,
                        extraHeaders: extraHeaders,
                        secrets: secrets
                    )

                    // Immediately revalidate upon return from async suspension
                    try validateActivePlanningSnapshot(
                        conversationID: conversationID,
                        stageBoundary: stageBoundary,
                        messages: messages,
                        sourceSnapshotValidator: sourceSnapshotValidator,
                        commitAuthority: commitAuthority
                    )

                    let sanitized = SecretMasker.redactCredentials(rawSemantic, secrets: allActiveSecrets)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !sanitized.isEmpty && sanitized.count <= compactorConfig.localCharacterCeiling {
                        let semCandidate = ContextCompactionState(
                            conversationID: conversationID,
                            lastCompactedMessageID: anchorID,
                            summary: sanitized,
                            compactedMessageCount: stageBoundary,
                            updatedAt: Date(),
                            sourcePrefixAnchorID: anchorID,
                            sourcePrefixMessageCount: stageBoundary,
                            sourcePrefixDigest: digest
                        )
                        let semAssembled = assemble(messages: messages, state: semCandidate, protectionHints: planningHints)
                        let (semReduced, _) = ContextWorkingSetManager.reduceWorkingSet(
                            messages: semAssembled,
                            systemPrompt: systemPrompt,
                            effectiveInputBudget: effectiveBudget,
                            toolReserve: budget.toolReserve,
                            protocolContext: protocolContext,
                            calibrationFactor: calibrationFactor,
                            targetBudgetRatio: targetBudgetRatio,
                            protectionHints: planningHints
                        )
                        let semBudget = Self.makeBudget(
                            systemPrompt: systemPrompt,
                            messages: semReduced,
                            tools: tools,
                            options: options,
                            factor: calibrationFactor,
                            targetBudgetRatio: targetBudgetRatio
                        )

                        if !semBudget.needsCompaction || semBudget.estimatedTokens < lastEstimatedTokens {
                            candidateForStage = semCandidate
                            candidateBudgetForStage = semBudget
                            candidateWorkingForStage = semReduced
                        } else {
                            logs.info("ContextLifecycle", "Semantic candidate for stage \(stage + 1) made no progress; attempting deterministic fallback for same boundary.")
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ContextPlanningControl {
                    throw error
                } catch let error as ContextLifecycleError {
                    throw error
                } catch {
                    // Revalidate snapshot on compactor failure BEFORE attempting fallback
                    try validateActivePlanningSnapshot(
                        conversationID: conversationID,
                        stageBoundary: stageBoundary,
                        messages: messages,
                        sourceSnapshotValidator: sourceSnapshotValidator,
                        commitAuthority: commitAuthority
                    )
                    let safeReason = SecretMasker.redactCredentials(error.localizedDescription, secrets: allActiveSecrets)
                    semanticCompactorFailed = true
                    diagnostics.append(.compactionFallback(stage: stage + 1, reason: safeReason))
                    logs.info("ContextLifecycle", "Semantic compactor failed (\(safeReason)); attempting deterministic fallback.", masking: allActiveSecrets)
                }
            }

            // 2. Deterministic fallback for the current stage boundary if semantic candidate not accepted
            if candidateForStage == nil {
                try validateSourceSnapshot(
                    conversationID: conversationID,
                    stageBoundary: stageBoundary,
                    messages: messages,
                    sourceSnapshotValidator: sourceSnapshotValidator
                )
                let detRaw = Self.summarize(previous: currentSummary, messages: sliceToCompact)
                let detSanitized = SecretMasker.redactCredentials(detRaw, secrets: allActiveSecrets)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !detSanitized.isEmpty else {
                    throw ContextLifecycleError.emptySummary
                }

                let detCandidate = ContextCompactionState(
                    conversationID: conversationID,
                    lastCompactedMessageID: anchorID,
                    summary: detSanitized,
                    compactedMessageCount: stageBoundary,
                    updatedAt: Date(),
                    sourcePrefixAnchorID: anchorID,
                    sourcePrefixMessageCount: stageBoundary,
                    sourcePrefixDigest: digest
                )
                let detAssembled = assemble(messages: messages, state: detCandidate, protectionHints: planningHints)
                let (detReduced, _) = ContextWorkingSetManager.reduceWorkingSet(
                    messages: detAssembled,
                    systemPrompt: systemPrompt,
                    effectiveInputBudget: effectiveBudget,
                    toolReserve: budget.toolReserve,
                    protocolContext: protocolContext,
                    calibrationFactor: calibrationFactor,
                    targetBudgetRatio: targetBudgetRatio,
                    protectionHints: planningHints
                )
                let detBudget = Self.makeBudget(
                    systemPrompt: systemPrompt,
                    messages: detReduced,
                    tools: tools,
                    options: options,
                    factor: calibrationFactor,
                    targetBudgetRatio: targetBudgetRatio
                )

                candidateForStage = detCandidate
                candidateBudgetForStage = detBudget
                candidateWorkingForStage = detReduced
            }

            guard let chosenCandidate = candidateForStage,
                  let chosenBudget = candidateBudgetForStage,
                  let chosenWorking = candidateWorkingForStage else {
                throw ContextLifecycleError.emptySummary
            }

            let boundaryAdvanced = stageBoundary > currentCompactedCount
            let tokenProgress = chosenBudget.estimatedTokens < lastEstimatedTokens

            candidateState = chosenCandidate
            compactedWorking = chosenWorking
            finalBudget = chosenBudget
            currentCompactedCount = stageBoundary
            currentSummary = chosenCandidate.summary
            lastEstimatedTokens = chosenBudget.estimatedTokens
            stage += 1
            diagnostics.append(.compactionSucceeded(stage: stage, boundary: stageBoundary))

            let targetBudget = max(1, Int(Double(effectiveBudget) * targetBudgetRatio))
            if chosenBudget.estimatedTokens <= targetBudget {
                // Target headroom (<= 75%) comfortably reached!
                break
            }

            if !boundaryAdvanced || !tokenProgress {
                logs.info("ContextLifecycle", "Zero progress detected in compaction stage \(stage); terminating loop.")
                break
            }
        }

        logs.info("ContextLifecycle", "model=\(modelID) window=\(contextWindow) estimated=\(budget.estimatedTokens) budget=\(effectiveBudget) factor=\(calibrationFactor) compact=\(candidateState != nil) boundary=\(currentCompactedCount) tail=\(messages.count - currentCompactedCount) after=\(finalBudget.estimatedTokens)")

        guard !finalBudget.needsCompaction else {
            if stoppedByActiveBlocker {
                throw ContextLifecycleError.noSafeCompactionBoundary
            }
            throw ContextLifecycleError.recoveryExhaustion(
                details: ContextFailureMetrics(
                    estimatedTokens: finalBudget.estimatedTokens,
                    effectiveBudget: effectiveBudget,
                    contextWindow: contextWindow,
                    stagesAttempted: stage
                )
            )
        }

        // Validation is deliberately before the atomic write: a failed candidate
        // never becomes authoritative durable state.
        if let candidate = candidateState {
            try validateActivePlanningSnapshot(
                conversationID: conversationID,
                stageBoundary: candidate.compactedMessageCount,
                messages: messages,
                sourceSnapshotValidator: sourceSnapshotValidator,
                commitAuthority: commitAuthority
            )
            try Task.checkCancellation()
            do {
                try store.save(candidate)
            } catch {
                let safeReason = SecretMasker.redactCredentials(error.localizedDescription, secrets: allActiveSecrets)
                logs.error("ContextLifecycle", "Failed to save derived context state: \(safeReason)", masking: allActiveSecrets)
                throw ContextLifecycleError.derivedStatePersistenceFailure(reason: safeReason)
            }
        }

        var result = ContextLifecycleResult(
            messages: compactedWorking,
            state: candidateState ?? state,
            budget: finalBudget,
            reductionReport: didReduce ? reductionReport : nil,
            didCompactThisCall: candidateState != nil,
            didReduceWorkingSetThisCall: didReduce,
            attemptedBoundaries: attemptedBoundaries,
            diagnostics: diagnostics
        )
        result.estimatedTokensBefore = budget.estimatedTokens
        return result
    }

    /// Identifies message indices containing un-compactable atomic protocol state (active/in-flight tool interactions).
    ///
    /// Unlike WorkingSet protection (which protects recent tails and the latest mutation tool against destructive stubbing),
    /// compaction hard blockers apply ONLY to messages with non-terminal tool states (.running, .queued, .awaitingApproval).
    /// Historical terminal tool units (completed, failed, denied, timedOut, cancelled, interrupted) are legally compactable
    /// provided their epistemic outcome markers are preserved in the compaction summary.
    nonisolated static func findCompactionHardBlockerIndices(in messages: [ChatMessage]) -> Set<Int> {
        var blockers = Set<Int>()
        for idx in messages.indices {
            let msg = messages[idx]
            if msg.toolCalls.contains(where: {
                $0.state == .running || $0.state == .queued || $0.state == .awaitingApproval
            }) {
                blockers.insert(idx)
            }
        }
        return blockers
    }

    private func assemble(messages: [ChatMessage], state: ContextCompactionState?, protectionHints: ContextProtectionHints) -> [ChatMessage] {
        guard let state else { return messages }
        let anchorID = state.sourcePrefixAnchorID ?? state.lastCompactedMessageID
        guard let boundary = messages.firstIndex(where: { $0.id == anchorID }) else { return messages }
        let summary = ChatMessage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            role: .user,
            content: "[Durable context summary of earlier conversation — background only]\n\(state.summary)",
            state: .complete
        )
        // Compaction may cross an old run-start request. Reinsert every mandatory unit
        // from canonical source verbatim; the persisted summary remains derived background.
        let floor = ContextWorkingSetManager.mandatoryFloorIndices(in: messages, protectionHints: protectionHints)
        let retained = messages[0...boundary].enumerated().compactMap { floor.contains($0.offset) ? $0.element : nil }
        return [summary] + retained + Array(messages.suffix(from: boundary + 1))
    }

    nonisolated static func summarizeToolCall(_ call: ToolCallRecord) -> String {
        let name = call.name.isEmpty ? "tool" : call.name
        var trimmedOutput = call.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.count > 1_000 {
            trimmedOutput = String(trimmedOutput.prefix(1_000)) + " [truncated]"
        }
        var trimmedError = call.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = trimmedError, err.count > 1_000 {
            trimmedError = String(err.prefix(1_000)) + " [truncated]"
        }

        let detail: String
        switch call.state {
        case .completed:
            detail = trimmedOutput.isEmpty ? "completed without captured output" : trimmedOutput
            return "Tool \(name) [completed]: \(detail)"
        case .failed:
            if let err = trimmedError, !err.isEmpty {
                detail = err
            } else if !trimmedOutput.isEmpty {
                detail = trimmedOutput
            } else {
                detail = "failed without error output"
            }
            return "Tool \(name) [failed]: \(detail)"
        case .denied:
            if let err = trimmedError, !err.isEmpty {
                detail = err
            } else if !trimmedOutput.isEmpty {
                detail = trimmedOutput
            } else {
                detail = "denied by policy or user permission"
            }
            return "Tool \(name) [denied]: \(detail)"
        case .cancelled:
            if let err = trimmedError, !err.isEmpty {
                detail = err
            } else if !trimmedOutput.isEmpty {
                detail = trimmedOutput
            } else {
                detail = "cancelled"
            }
            return "Tool \(name) [cancelled]: \(detail)"
        case .timedOut:
            if let err = trimmedError, !err.isEmpty {
                detail = err
            } else if !trimmedOutput.isEmpty {
                detail = trimmedOutput
            } else {
                detail = "timed out"
            }
            return "Tool \(name) [timed out]: \(detail)"
        case .interrupted:
            if let err = trimmedError, !err.isEmpty {
                detail = err
            } else if !trimmedOutput.isEmpty {
                detail = trimmedOutput
            } else {
                detail = "interrupted before completion; outcome unknown"
            }
            return "Tool \(name) [interrupted / outcome unknown]: \(detail)"
        case .queued, .awaitingApproval, .running:
            return "Tool \(name) [\(call.state.rawValue)]: incomplete execution"
        }
    }

    nonisolated static func summarize(previous: String?, messages: [ChatMessage]) -> String {
        var chunks: [String] = []
        if let previous, !previous.isEmpty { chunks.append(previous) }
        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { chunks.append("\(role): \(text)") }
            for call in message.toolCalls where !call.name.isEmpty {
                chunks.append(summarizeToolCall(call))
            }
        }
        let joined = chunks.joined(separator: "\n")
        if joined.count <= maximumSummaryCharacters { return joined }

        // Bounded deterministic summary: preserve critical tool outcome and constraint lines
        var criticalLines: [String] = []
        var normalLines: [String] = []
        for line in joined.components(separatedBy: "\n") {
            if line.contains("[failed]") || line.contains("[denied]") || line.contains("[timed out]") || line.contains("[interrupted") || line.contains("••••") || (line.contains("Tool ") && line.contains("[completed]")) {
                criticalLines.append(line)
            } else {
                normalLines.append(line)
            }
        }

        let criticalBlock = criticalLines.joined(separator: "\n")
        let availableProse = max(0, maximumSummaryCharacters - criticalBlock.count - 100)
        let normalBlock = normalLines.joined(separator: "\n")
        let trimmedNormal = normalBlock.count <= availableProse ? normalBlock : String(normalBlock.suffix(availableProse))

        if criticalBlock.isEmpty {
            return trimmedNormal
        } else if trimmedNormal.isEmpty {
            return criticalBlock
        } else {
            return "\(trimmedNormal)\n\n[Authoritative Tool Outcomes]\n\(criticalBlock)"
        }
    }

    private func shortenedToolOutput(_ output: String, maximumBytes: Int) -> String {
        let bytes = Data(output.utf8)
        guard bytes.count > maximumBytes else { return output }
        let head = String(decoding: bytes.prefix(maximumBytes / 2), as: UTF8.self)
        let tail = String(decoding: bytes.suffix(maximumBytes / 2), as: UTF8.self)
        return "\(head)\n[Earlier tool output shortened for context; full result remains in conversation history.]\n\(tail)"
    }

    static func makeBudget(
        systemPrompt: String,
        messages: [ChatMessage],
        tools: [ChatToolDefinition],
        options: ChatInferenceOptions,
        factor: Double = 1.0,
        targetBudgetRatio: Double = ContextWorkingSetManager.defaultTargetBudgetRatio
    ) -> ContextBudget {
        let limits = options.effectiveLimits(tools: tools)
        let eval = ContextTokenEstimator.calibratedContentForBudget(
            systemPrompt: systemPrompt,
            messages: messages,
            toolReserve: limits.toolReserve,
            factor: factor
        )
        let baseline = ContextCalibrationBaseline(
            rawContentInputTokens: eval.rawContentInputTokens,
            toolReserve: limits.toolReserve
        )

        return ContextBudget(
            contextWindow: limits.effectiveContextWindow,
            estimatedTokens: eval.calibratedContentForBudget,
            effectiveInputBudget: limits.effectiveInputBudget,
            outputReserve: limits.outputReserve,
            toolReserve: limits.toolReserve,
            safetyReserve: limits.safetyReserve,
            estimate: eval.estimate,
            targetBudgetRatio: targetBudgetRatio,
            calibrationBaseline: baseline
        )
    }
}

enum ContextLifecycleError: LocalizedError, Equatable {
    case protectedContextExhaustion(details: ContextFailureMetrics? = nil)
    case noSafeCompactionBoundary
    case recoveryExhaustion(details: ContextFailureMetrics? = nil)
    case derivedStatePersistenceFailure(reason: String)
    case emptySummary
    case commitAuthorityRevoked
    case sourceMutatedDuringPlanning
    case recentContextExceedsBudget
    /// The Compact command found nothing new since the last summary.
    case nothingToCompact

    var kind: ContextFailureKind? {
        switch self {
        case .protectedContextExhaustion: return .protectedContextExhaustion
        case .noSafeCompactionBoundary: return .noSafeCompactionBoundary
        case .recoveryExhaustion: return .recoveryExhaustion
        case .derivedStatePersistenceFailure: return .derivedStatePersistenceFailure
        case .recentContextExceedsBudget: return .recoveryExhaustion
        case .emptySummary, .commitAuthorityRevoked, .sourceMutatedDuringPlanning, .nothingToCompact: return nil
        }
    }

    var isCapacityFailure: Bool {
        switch self {
        case .protectedContextExhaustion, .noSafeCompactionBoundary, .recoveryExhaustion, .recentContextExceedsBudget:
            return true
        case .derivedStatePersistenceFailure, .emptySummary, .commitAuthorityRevoked, .sourceMutatedDuringPlanning, .nothingToCompact:
            return false
        }
    }

    static let recoveryMessage = "Conversation too large for this model. Choose a model with a larger context window or start a new conversation. Your history is saved."

    var userFacingMessage: String {
        switch self {
        case .protectedContextExhaustion:
            return "The system instructions and recent protected conversation are too large for this model. Shorten current instructions or recent request, or choose a model with a larger context window."
        case .noSafeCompactionBoundary:
            return "Active or protocol-sensitive context cannot be reduced safely. Complete or resolve the active tool operation or choose a model with a larger context window."
        case .recoveryExhaustion:
            return "Conversation context reduction was attempted but could not fit this model. Choose a model with a larger context window or start a new conversation. Your history is saved."
        case .derivedStatePersistenceFailure(let reason):
            let clean = SecretMasker.redactCredentials(reason)
            return "Context state could not be saved locally: \(clean). Check disk space or storage permissions. Your conversation history remains saved."
        case .recentContextExceedsBudget:
            return Self.recoveryMessage
        case .emptySummary:
            return "Context compaction could not produce a durable summary."
        case .commitAuthorityRevoked:
            return "Context compaction derived-state commit rejected: mutation authority invalid or revoked."
        case .sourceMutatedDuringPlanning:
            return "Context planning aborted: canonical conversation source mutated repeatedly."
        case .nothingToCompact:
            return "Nothing new to compact since the last summary."
        }
    }

    var errorDescription: String? {
        userFacingMessage
    }
}
