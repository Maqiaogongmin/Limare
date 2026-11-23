import Foundation

/// Admission facts for one run. The coordinator owns these IDs; Context never persists them.
struct ContextProtectionHints: Sendable, Equatable {
    var mandatoryUserMessageIDs: Set<UUID> = []
    /// Re-derived from canonical history during each planning call, never persisted.
    var acknowledgedToolCallIDs: Set<UUID> = []
}

/// Protocol and provider context provided to the WorkingSet Manager for protocol-safe reduction.
struct WorkingSetProtocolContext: Sendable, Equatable {
    let apiFormat: ProviderAPIFormat?
    let providerID: UUID?
    let modelID: String?
    let preserveReasoningHistory: Bool

    init(
        apiFormat: ProviderAPIFormat? = nil,
        providerID: UUID? = nil,
        modelID: String? = nil,
        preserveReasoningHistory: Bool = false
    ) {
        self.apiFormat = apiFormat
        self.providerID = providerID
        self.modelID = modelID
        self.preserveReasoningHistory = preserveReasoningHistory
    }
}

/// Structured report of actions taken during WorkingSet reduction.
struct ContextReductionReport: Sendable, Equatable {
    let beforeTokens: Int
    let afterTokens: Int
    let beforeEstimate: TokenEstimate
    let afterEstimate: TokenEstimate
    let reasoningItemsReduced: Int
    let attachmentsReduced: Int
    let toolResultsReduced: Int
    let protectedMessageCount: Int
    let reachedTargetBudget: Bool
    let reachedSoftBudget: Bool
    let reachedHardBudget: Bool
    let fingerprint: String?
    let pinnedReduction: ContextWorkingSetManager.PinnedReductionSet

    var didReduce: Bool {
        reasoningItemsReduced > 0 || attachmentsReduced > 0 || toolResultsReduced > 0
    }

    init(
        beforeTokens: Int,
        afterTokens: Int,
        reasoningItemsReduced: Int,
        attachmentsReduced: Int,
        toolResultsReduced: Int,
        protectedMessageCount: Int,
        reachedSoftBudget: Bool,
        reachedHardBudget: Bool,
        fingerprint: String? = nil,
        beforeEstimate: TokenEstimate? = nil,
        afterEstimate: TokenEstimate? = nil,
        reachedTargetBudget: Bool = false,
        pinnedReduction: ContextWorkingSetManager.PinnedReductionSet = .init()
    ) {
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.beforeEstimate = beforeEstimate ?? TokenEstimate(count: beforeTokens)
        self.afterEstimate = afterEstimate ?? TokenEstimate(count: afterTokens)
        self.reasoningItemsReduced = reasoningItemsReduced
        self.attachmentsReduced = attachmentsReduced
        self.toolResultsReduced = toolResultsReduced
        self.protectedMessageCount = protectedMessageCount
        self.reachedTargetBudget = reachedTargetBudget
        self.reachedSoftBudget = reachedSoftBudget
        self.reachedHardBudget = reachedHardBudget
        self.fingerprint = fingerprint
        self.pinnedReduction = pinnedReduction
    }
}

/// Pure-logic coordinator for slimming the active Working Context projection
/// without modifying durable conversation history.
enum ContextWorkingSetManager {
    /// Previously applied WorkingSet reductions pinned across turns so prefixes stay cache-stable.
    struct PinnedReductionSet: Sendable, Equatable {
        var strippedReasoningMessageIDs: Set<UUID> = []
        var strippedAttachmentMessageIDs: Set<UUID> = []
        var offloadedToolCallIDs: Set<String> = []
        var isEmpty: Bool {
            strippedReasoningMessageIDs.isEmpty && strippedAttachmentMessageIDs.isEmpty && offloadedToolCallIDs.isEmpty
        }
    }
    /// Soft threshold ratio triggering reduction (85% of effective input budget).
    static let softThresholdRatio: Double = 0.85
    /// Configurable target headroom ratio when reduction is executed (75% of effective input budget).
    static let defaultTargetBudgetRatio: Double = 0.75
    /// Cap proactive working-set reduction trigger on 1M-window models to prevent Context Rot
    /// while keeping PinnedReductionSet cache-stable across ~60K-token bands.
    static let maximumSoftInputBudgetCeiling: Int = 180_000
    static let maximumTargetInputBudgetCeiling: Int = 120_000
    static let minimumIncrementalSoftBatchTokens: Int = 20_000
    static let ordinaryTailTokenCeiling = 20_000
    static let ordinaryTailBudgetFraction = 0.40
    /// Minimum original tokens required to consider a tool result for offloading.
    static let minimumToolResultTokensForOffload: Int = 50

    static func softInputBudget(for effectiveInputBudget: Int) -> Int {
        min(maximumSoftInputBudgetCeiling, max(1, Int(Double(effectiveInputBudget) * softThresholdRatio)))
    }

    static func targetInputBudget(
        for effectiveInputBudget: Int,
        targetBudgetRatio: Double = defaultTargetBudgetRatio
    ) -> Int {
        min(maximumTargetInputBudgetCeiling, max(1, Int(Double(effectiveInputBudget) * min(softThresholdRatio, targetBudgetRatio))))
    }

    // MARK: - Mutation Tools Recognition

    /// Identifies whether a tool changes external state and must be preserved from offloading.
    static func isMutationSensitiveTool(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch lower {
        case "file_write", "file_edit", "shell_execute", "write_file", "edit_file", "bash", "execute_command":
            return true
        case "save", "update", "delete", "move", "rename", "git_commit", "git_checkout":
            return true
        default:
            if lower.hasPrefix("git_") || lower.hasPrefix("file_write") || lower.hasPrefix("file_edit") {
                return true
            }
            return false
        }
    }

    // MARK: - Token Estimation (Delegated to ContextTokenEstimator)

    static func estimatedTokens(bytes: Int) -> Int {
        ContextTokenEstimator.rawEstimatedTokens(bytes: bytes)
    }

    static func estimatedTokens(text: String) -> Int {
        ContextTokenEstimator.rawEstimatedTokens(text: text)
    }

    static func estimate(message: ChatMessage, factor: Double = 1.0) -> TokenEstimate {
        ContextTokenEstimator.estimate(message: message, factor: factor)
    }

    static func estimateTotal(systemPrompt: String, messages: [ChatMessage], factor: Double = 1.0) -> TokenEstimate {
        ContextTokenEstimator.estimateTotal(systemPrompt: systemPrompt, messages: messages, factor: factor)
    }

    // MARK: - Protected Indices Calculation

    /// Finds the starting index of the protected tail (last N user turns + subsequent messages).
    static func findProtectedTailStartIndex(
        in messages: [ChatMessage],
        recentUserTurns: Int = 3
    ) -> Int {
        var userTurnCount = 0
        for index in messages.indices.reversed() {
            let msg = messages[index]
            if msg.role == .user && !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                userTurnCount += 1
                if userTurnCount == recentUserTurns {
                    return index
                }
            }
        }
        // If there are fewer than `recentUserTurns` user turns, all messages are in protected tail
        return 0
    }

    /// Identifies all message indices that are protected from WorkingSet reduction.
    ///
    /// Protected Region =
    /// - Last 3 user turns and all intervening/trailing messages (Protected Tail)
    /// - Current active / in-flight tool interactions
    /// - The most recent mutation-sensitive tool interaction across history
    static func findProtectedIndices(
        in messages: [ChatMessage],
        recentUserTurns: Int = 3
    ) -> Set<Int> {
        let tailStart = findProtectedTailStartIndex(in: messages, recentUserTurns: recentUserTurns)
        var protected = Set(tailStart..<messages.count)

        // Find the latest mutation-sensitive tool interaction across all messages
        var latestMutationIndex: Int?
        for idx in messages.indices.reversed() {
            let msg = messages[idx]
            let hasMutationTool = msg.toolCalls.contains { isMutationSensitiveTool($0.name) }
            if hasMutationTool {
                latestMutationIndex = idx
                break
            }
        }
        if let mutIdx = latestMutationIndex {
            protected.insert(mutIdx)
        }

        // Active / in-flight tool calls (actively running or awaiting execution without output)
        for idx in messages.indices {
            let msg = messages[idx]
            if msg.toolCalls.contains(where: { ($0.state == .running || $0.state == .awaitingApproval || $0.state == .queued) && $0.output.isEmpty }) {
                protected.insert(idx)
            }
        }

        return protected
    }

    static func ordinaryTailAllowance(effectiveInputBudget: Int) -> Int {
        min(ordinaryTailTokenCeiling, Int((Double(effectiveInputBudget) * ordinaryTailBudgetFraction).rounded(.down)))
    }

    /// Whole ChatMessage units preserve their tool-call/result envelope. The suffix stops at
    /// the first older unit that cannot fit; mandatory units are selected separately.
    static func ordinaryTailStartIndex(in messages: [ChatMessage], effectiveInputBudget: Int, calibrationFactor: Double) -> Int {
        let allowance = ordinaryTailAllowance(effectiveInputBudget: effectiveInputBudget)
        var used = 0
        var start = messages.count
        for index in messages.indices.reversed() {
            let cost = estimate(message: messages[index], factor: calibrationFactor).count
            guard cost <= allowance - used else { break }
            used += cost
            start = index
        }
        return start
    }

    static func hasLaterProviderTurn(after messageIndex: Int, in messages: [ChatMessage]) -> Bool {
        guard messageIndex + 1 < messages.count else { return false }
        return messages[(messageIndex + 1)...].contains {
            $0.role == .assistant && $0.state == .complete && $0.resolvedProviderID != nil
        }
    }

    static func acknowledgedToolCallIDs(in messages: [ChatMessage]) -> Set<UUID> {
        var ids = Set<UUID>()
        for index in messages.indices where hasLaterProviderTurn(after: index, in: messages) {
            for call in messages[index].toolCalls where call.state.isTerminal { ids.insert(call.id) }
        }
        return ids
    }

    private static func isActive(_ call: ToolCallRecord) -> Bool {
        call.state == .queued || call.state == .awaitingApproval || call.state == .running
    }

    /// Raw output is retained when the structured record cannot independently carry the
    /// latest mutation's operation, target, terminal state and mechanical outcome.
    static func hasSufficientMutationFacts(_ call: ToolCallRecord) -> Bool {
        guard call.state.isTerminal, !call.name.isEmpty, !call.input.isEmpty else { return false }
        let name = call.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "file_write" || name == "file_edit" {
            return ToolCallFileTargetResolver.extractPath(from: call) != nil
        }
        // Shell exit status cannot establish all external side effects of an arbitrary command.
        if name == "shell_execute" || name == "bash" || name == "execute_command" { return false }
        if call.mechanicalTerminalFact?.representationArtifact != nil { return true }
        return false
    }

    static func latestMutationCallID(in messages: [ChatMessage]) -> UUID? {
        for message in messages.reversed() {
            if let call = message.toolCalls.last(where: { isMutationSensitiveTool($0.name) }) { return call.id }
        }
        return nil
    }

    /// First message of the run in progress: the earliest user message the coordinator admitted
    /// for it. Without run hints nothing counts as the current run.
    static func currentRunStartIndex(in messages: [ChatMessage], protectionHints: ContextProtectionHints) -> Int {
        guard !protectionHints.mandatoryUserMessageIDs.isEmpty else { return messages.count }
        return messages.firstIndex {
            $0.role == .user && protectionHints.mandatoryUserMessageIDs.contains($0.id)
        } ?? messages.count
    }

    /// The same indices are used by WorkingSet and Lifecycle's hard-pressure footprint.
    static func mandatoryFloorIndices(in messages: [ChatMessage], protectionHints: ContextProtectionHints) -> Set<Int> {
        let latestMutationID = latestMutationCallID(in: messages)
        var result = Set<Int>()
        for index in messages.indices {
            let message = messages[index]
            if message.role == .user && protectionHints.mandatoryUserMessageIDs.contains(message.id) { result.insert(index) }
            if message.toolCalls.contains(where: isActive) { result.insert(index) }
            if message.toolCalls.contains(where: { $0.state.isTerminal }) && !hasLaterProviderTurn(after: index, in: messages) { result.insert(index) }
            if let latestMutationID, message.toolCalls.contains(where: { $0.id == latestMutationID }) { result.insert(index) }
        }
        return result
    }

    // MARK: - WorkingSet Reduction

    /// Projects and slims durable messages into working inference messages according to the Reduction Ladder.
    ///
    /// Ladder:
    /// - Level 1: Strip older historical reasoningContent & mismatched/stale responsesReasoningEcho
    /// - Level 2: Downgrade older heavy attachments to recoverable textual references
    /// - Level 3: Offload older/large non-mutation tool results into structured stubs
    ///
    /// Never modifies durable conversation history.
    static func reduceWorkingSet(
        messages: [ChatMessage],
        systemPrompt: String,
        effectiveInputBudget: Int,
        toolReserve: Int = 0,
        protocolContext: WorkingSetProtocolContext? = nil,
        calibrationFactor: Double = 1.0,
        targetBudgetRatio: Double = defaultTargetBudgetRatio,
        protectionHints: ContextProtectionHints = ContextProtectionHints(),
        pinnedReduction: PinnedReductionSet = PinnedReductionSet()
    ) -> (workingMessages: [ChatMessage], report: ContextReductionReport) {
        let softInputBudget = Self.softInputBudget(for: effectiveInputBudget)
        let targetInputBudget = Self.targetInputBudget(for: effectiveInputBudget, targetBudgetRatio: targetBudgetRatio)
        let hardInputBudget = effectiveInputBudget

        func evaluateEstimate(_ currentMsgs: [ChatMessage]) -> (estimate: TokenEstimate, tokens: Int) {
            let res = ContextTokenEstimator.calibratedContentForBudget(
                systemPrompt: systemPrompt,
                messages: currentMsgs,
                toolReserve: toolReserve,
                factor: calibrationFactor
            )
            return (res.estimate, res.calibratedContentForBudget)
        }

        let initialEval = evaluateEstimate(messages)
        let initialEstimate = initialEval.estimate
        let initialTokens = initialEval.tokens

        let tailStart = ordinaryTailStartIndex(in: messages, effectiveInputBudget: effectiveInputBudget, calibrationFactor: calibrationFactor)
        let mandatoryIndices = mandatoryFloorIndices(in: messages, protectionHints: protectionHints)
        let protectedIndices = Set(tailStart..<messages.count).union(mandatoryIndices)
        let protectedCount = protectedIndices.count
        let reducibleIndices = messages.indices.filter { !protectedIndices.contains($0) }.sorted()

        var working = messages
        var reasoningCount = 0
        var attachmentsCount = 0
        var toolResultsCount = 0

        var strippedReasoningMessageIDs: [UUID] = []
        var strippedAttachmentMessageIDs: [UUID] = []
        var stubbedToolCallIDs: [String] = []

        var currentEstimate = initialEstimate
        var currentTokens = initialTokens

        func makeReport(currEstimate: TokenEstimate) -> ContextReductionReport {
            let currTokens = currEstimate.count
            let didReduce = reasoningCount > 0 || attachmentsCount > 0 || toolResultsCount > 0
            let fp: String?
            if didReduce {
                let rIDs = strippedReasoningMessageIDs.map(\.uuidString).joined(separator: ",")
                let aIDs = strippedAttachmentMessageIDs.map(\.uuidString).joined(separator: ",")
                let tIDs = stubbedToolCallIDs.joined(separator: ",")
                fp = "r:[\(rIDs)]|a:[\(aIDs)]|t:[\(tIDs)]"
            } else {
                fp = nil
            }
            let pinned = didReduce ? PinnedReductionSet(
                strippedReasoningMessageIDs: Set(strippedReasoningMessageIDs),
                strippedAttachmentMessageIDs: Set(strippedAttachmentMessageIDs),
                offloadedToolCallIDs: Set(stubbedToolCallIDs)
            ) : PinnedReductionSet()
            return ContextReductionReport(
                beforeTokens: initialTokens,
                afterTokens: currTokens,
                reasoningItemsReduced: reasoningCount,
                attachmentsReduced: attachmentsCount,
                toolResultsReduced: toolResultsCount,
                protectedMessageCount: protectedCount,
                reachedSoftBudget: currTokens <= softInputBudget,
                reachedHardBudget: currTokens <= hardInputBudget,
                fingerprint: fp,
                beforeEstimate: initialEstimate,
                afterEstimate: currEstimate,
                reachedTargetBudget: currTokens <= targetInputBudget,
                pinnedReduction: pinned
            )
        }

        func applyLevel1Strip(at idx: Int) -> Bool {
            var modified = false
            if protocolContext?.preserveReasoningHistory != true, working[idx].reasoningContent != nil {
                working[idx].reasoningContent = nil
                reasoningCount += 1
                strippedReasoningMessageIDs.append(working[idx].id)
                modified = true
            }

            // Responses reasoning echo protocol safety
            if let echo = working[idx].responsesReasoningEcho {
                let canStripEcho: Bool
                if let proto = protocolContext {
                    switch proto.apiFormat {
                    case .chatCompletions, .anthropicMessages, .geminiNative:
                        // Chat Completions cannot use Responses echo -> safe to strip
                        canStripEcho = true
                    case .responses:
                        // Responses API: keep echo if provider & model match; strip only if BOTH are known and mismatched
                        if let currProviderID = proto.providerID, let currModelID = proto.modelID {
                            canStripEcho = (echo.providerID != currProviderID || echo.modelID != currModelID)
                        } else {
                            // If either provider or model is unknown, cannot determine -> retain
                            canStripEcho = false
                        }
                    case .none:
                        canStripEcho = false
                    }
                } else {
                    // Unknown protocol context: retain
                    canStripEcho = false
                }

                if canStripEcho {
                    working[idx].responsesReasoningEcho = nil
                    reasoningCount += 1
                    if !strippedReasoningMessageIDs.contains(working[idx].id) {
                        strippedReasoningMessageIDs.append(working[idx].id)
                    }
                    modified = true
                }
            }
            return modified
        }

        func applyLevel2Downgrade(at idx: Int) -> Bool {
            guard !working[idx].attachments.isEmpty else { return false }
            let count = working[idx].attachments.count
            attachmentsCount += count
            strippedAttachmentMessageIDs.append(working[idx].id)

            var notes: [String] = []
            for att in working[idx].attachments {
                var lines: [String] = [
                    "[Earlier attachment omitted from active context.",
                    "File: \(att.filename)",
                    "Type: \(att.mimeType.isEmpty ? att.kind.rawValue : att.mimeType)"
                ]
                if !att.relativePath.isEmpty {
                    lines.append("Stored reference: \(att.relativePath)")
                }
                lines.append("Original attachment remains available in conversation history.]")
                notes.append(lines.joined(separator: "\n"))
            }
            let combinedNote = "\n" + notes.joined(separator: "\n\n")

            working[idx].attachments = []
            if !working[idx].content.contains("[Earlier attachment omitted from active context.") {
                working[idx].content += combinedNote
            }
            return true
        }

        struct ToolCandidate {
            let messageIndex: Int
            let toolIndex: Int
            let toolCallID: String
            let toolName: String
            let toolInput: String
            let originalOutput: String
            let hasAliasedErrorMessage: Bool
            let tokens: Int
        }

        let latestMutationID = latestMutationCallID(in: messages)
        func eligibleToolCandidate(messageIndex msgIdx: Int, toolIndex toolIdx: Int) -> ToolCandidate? {
            let call = working[msgIdx].toolCalls[toolIdx]
            guard call.state.isTerminal,
                  (hasLaterProviderTurn(after: msgIdx, in: messages) || protectionHints.acknowledgedToolCallIDs.contains(call.id)),
                  !isActive(call),
                  !containsArtifactResultPart(call.resultParts),
                  (!isMutationSensitiveTool(call.name) || hasSufficientMutationFacts(call)),
                  (call.id != latestMutationID || hasSufficientMutationFacts(call)) else { return nil }
            // An independent error description may contain facts absent from output. Keep it
            // raw until Context has a separately authorized way to summarize those facts.
            if let error = call.errorMessage, !error.isEmpty, error != call.output { return nil }
            guard !call.output.isEmpty, !call.output.hasPrefix("[TOOL RESULT OFFLOADED]") else { return nil }
            let outputTokens = estimatedTokens(text: call.output)
            guard outputTokens >= minimumToolResultTokensForOffload else { return nil }
            let durableCallID = !call.providerCallID.isEmpty ? call.providerCallID : call.id.uuidString
            return ToolCandidate(
                messageIndex: msgIdx,
                toolIndex: toolIdx,
                toolCallID: durableCallID,
                toolName: call.name,
                toolInput: call.input,
                originalOutput: call.output,
                hasAliasedErrorMessage: call.errorMessage == call.output,
                tokens: outputTokens
            )
        }

        func offloadCandidate(_ cand: ToolCandidate) {
            let preview = previewSnippet(cand.originalOutput)
            let stub = """
            [TOOL RESULT OFFLOADED]
            Tool: \(cand.toolName)
            Call ID: \(cand.toolCallID)
            Original result: ~\(cand.tokens) tokens
            Preview: \(preview)
            Full result remains available.
            Use tool_result_read with this Call ID to retrieve it.
            """

            working[cand.messageIndex].toolCalls[cand.toolIndex].output = stub
            if cand.hasAliasedErrorMessage {
                working[cand.messageIndex].toolCalls[cand.toolIndex].errorMessage = stub
            }
            toolResultsCount += 1
            stubbedToolCallIDs.append(cand.toolCallID)
        }

        let currentRunStart = currentRunStartIndex(in: messages, protectionHints: protectionHints)

        // Replay previously pinned reductions first so already-sent prefixes remain cache-stable
        // across turns until the soft threshold is crossed again.
        if !pinnedReduction.isEmpty {
            var replayedAny = false
            for idx in reducibleIndices where idx < currentRunStart {
                if pinnedReduction.strippedReasoningMessageIDs.contains(working[idx].id),
                   applyLevel1Strip(at: idx) {
                    replayedAny = true
                }
            }
            for idx in reducibleIndices {
                if pinnedReduction.strippedAttachmentMessageIDs.contains(working[idx].id),
                   applyLevel2Downgrade(at: idx) {
                    replayedAny = true
                }
            }
            if !pinnedReduction.offloadedToolCallIDs.isEmpty {
                for msgIdx in working.indices {
                    for toolIdx in working[msgIdx].toolCalls.indices {
                        if let cand = eligibleToolCandidate(messageIndex: msgIdx, toolIndex: toolIdx),
                           pinnedReduction.offloadedToolCallIDs.contains(cand.toolCallID) {
                            offloadCandidate(cand)
                            replayedAny = true
                        }
                    }
                }
            }
            if replayedAny {
                let eval = evaluateEstimate(working)
                currentEstimate = eval.estimate
                currentTokens = eval.tokens
            }
        }

        // If already (or still, after replaying pinned reductions) within soft budget, no new reduction needed.
        if currentTokens <= softInputBudget {
            return (working, makeReport(currEstimate: currentEstimate))
        }

        // On 1M+ models capped at 180K, avoid thrashing prompt cache every turn when irreducible
        // context exceeds 180K; wait until at least 20K incremental tokens can be batched cleanly.
        let enforceMinimumSoftBatch = !pinnedReduction.isEmpty
            && currentTokens <= hardInputBudget
            && softInputBudget == Self.maximumSoftInputBudgetCeiling
        let pinnedOnlyWorking = working
        let pinnedOnlyEstimate = currentEstimate
        let pinnedOnlyTokens = currentTokens
        let pinnedOnlyReasoningCount = reasoningCount
        let pinnedOnlyAttachmentsCount = attachmentsCount
        let pinnedOnlyToolResultsCount = toolResultsCount
        let pinnedOnlyStrippedReasoning = strippedReasoningMessageIDs
        let pinnedOnlyStrippedAttachments = strippedAttachmentMessageIDs
        let pinnedOnlyStubbedTools = stubbedToolCallIDs

        // Level 1: Reasoning & transient metadata reduction in reducible region.
        // Reasoning inside the current run is the model's interleaved thinking between tool
        // calls; providers require it back intact (DeepSeek returns 400 without it, Anthropic
        // keeps thinking blocks through a tool loop). Pressure from it goes to Levels 2-3 and
        // compaction instead.
        for idx in reducibleIndices where idx < currentRunStart {
            if applyLevel1Strip(at: idx) {
                let eval = evaluateEstimate(working)
                currentEstimate = eval.estimate
                currentTokens = eval.tokens
                if currentTokens <= targetInputBudget {
                    return (working, makeReport(currEstimate: currentEstimate))
                }
            }
        }

        // Level 2: Older attachments downgraded to recoverable textual references
        for idx in reducibleIndices {
            if applyLevel2Downgrade(at: idx) {
                let eval = evaluateEstimate(working)
                currentEstimate = eval.estimate
                currentTokens = eval.tokens
                if currentTokens <= targetInputBudget {
                    return (working, makeReport(currEstimate: currentEstimate))
                }
            }
        }

        // Level 3: Tool Result Offload in reducible region (chronological, oldest-first).
        // The ordinary tail receives full-fidelity preference. Under hard pressure, eligible
        // acknowledged/fact-safe payloads there can still be offloaded after older candidates.
        var candidates: [ToolCandidate] = []
        for msgIdx in messages.indices {
            for toolIdx in working[msgIdx].toolCalls.indices {
                if let cand = eligibleToolCandidate(messageIndex: msgIdx, toolIndex: toolIdx) {
                    candidates.append(cand)
                }
            }
        }

        // Exhaust historical candidates chronologically before breaching the ordinary full-fidelity
        // suffix so already-sent prefixes remain cache-stable across turns.
        candidates.sort { (a, b) -> Bool in
            let aInTail = a.messageIndex >= tailStart
            let bInTail = b.messageIndex >= tailStart
            if aInTail != bInTail { return !aInTail }
            if a.messageIndex != b.messageIndex {
                return a.messageIndex < b.messageIndex
            }
            return a.toolIndex < b.toolIndex
        }

        for cand in candidates {
            // Ordinary suffix is only breached to avoid a known-over-hard request.
            if cand.messageIndex >= tailStart && currentTokens <= hardInputBudget { continue }
            offloadCandidate(cand)

            let eval = evaluateEstimate(working)
            currentEstimate = eval.estimate
            currentTokens = eval.tokens
            if currentTokens <= targetInputBudget {
                break
            }
        }

        if enforceMinimumSoftBatch,
           currentTokens > targetInputBudget,
           (pinnedOnlyTokens - currentTokens) < Self.minimumIncrementalSoftBatchTokens {
            working = pinnedOnlyWorking
            reasoningCount = pinnedOnlyReasoningCount
            attachmentsCount = pinnedOnlyAttachmentsCount
            toolResultsCount = pinnedOnlyToolResultsCount
            strippedReasoningMessageIDs = pinnedOnlyStrippedReasoning
            strippedAttachmentMessageIDs = pinnedOnlyStrippedAttachments
            stubbedToolCallIDs = pinnedOnlyStubbedTools
            return (pinnedOnlyWorking, makeReport(currEstimate: pinnedOnlyEstimate))
        }

        return (working, makeReport(currEstimate: currentEstimate))
    }

    private static func containsArtifactResultPart(_ parts: [ToolResultPart]?) -> Bool {
        parts?.contains(where: { if case .artifact = $0 { return true }; return false }) ?? false
    }

    private static func previewSnippet(_ text: String, maxLength: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength {
            return trimmed
        }
        let headCount = maxLength / 2
        let tailCount = maxLength - headCount
        let omitted = trimmed.count - maxLength
        return "\(trimmed.prefix(headCount))\n[... \(omitted) characters omitted ...]\n\(trimmed.suffix(tailCount))"
    }
}
