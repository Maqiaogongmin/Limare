import Foundation

@MainActor
protocol AgentLoopObserver: AnyObject, Sendable {
    func onTurnStarted(turnIndex: Int)
    func onAssistantTurnDiscarded()
    func onReasoningDelta(_ delta: String)
    func onTextDelta(_ delta: String)
    func onToolCallAccumulated(toolIndex: Int, accumulator: ToolCallAccumulator)
    func onNativeProtocolMetadata(_ metadata: NativeProtocolMetadata)
    func onResponsesReasoningEcho(_ echo: ResponsesReasoningEcho)
    func onAssistantMessageCompleted(content: String, reasoningContent: String?, toolCalls: [ProviderToolCall], responsesReasoningEcho: ResponsesReasoningEcho?)
    func onToolExecutionStarted(call: ProviderToolCall)
    func onToolExecutionCompleted(call: ProviderToolCall, outcome: ToolExecutionOutcome)
    func onUsageTelemetryReceived(usage: ProviderUsageTelemetry, providerID: UUID?, modelID: String)
    func onProviderRequestStarted(providerID: UUID, modelID: String, requestAttempt: Int)
    func onProviderRequestRetry(providerID: UUID, modelID: String, requestAttempt: Int, reason: String)
    func onProviderThinkingResolved(_ metadata: [String: String])
    func onProviderRequestToolNames(_ names: [String])
    func onProviderTransportFailure(_ summary: String)
}

extension AgentLoopObserver {
    func onTurnStarted(turnIndex: Int) {}
    func onAssistantTurnDiscarded() {}
    func onReasoningDelta(_ delta: String) {}
    func onTextDelta(_ delta: String) {}
    func onToolCallAccumulated(toolIndex: Int, accumulator: ToolCallAccumulator) {}
    func onResponsesReasoningEcho(_ echo: ResponsesReasoningEcho) {}
    func onNativeProtocolMetadata(_ metadata: NativeProtocolMetadata) {}
    func onAssistantMessageCompleted(content: String, reasoningContent: String?, toolCalls: [ProviderToolCall], responsesReasoningEcho: ResponsesReasoningEcho?) {}
    func onToolExecutionStarted(call: ProviderToolCall) {}
    func onToolExecutionCompleted(call: ProviderToolCall, outcome: ToolExecutionOutcome) {}
    func onUsageTelemetryReceived(usage: ProviderUsageTelemetry, providerID: UUID?, modelID: String) {}
    func onProviderRequestStarted(providerID: UUID, modelID: String, requestAttempt: Int) {}
    func onProviderRequestRetry(providerID: UUID, modelID: String, requestAttempt: Int, reason: String) {}
    func onProviderThinkingResolved(_ metadata: [String: String]) {}
    func onProviderRequestToolNames(_ names: [String]) {}
    func onProviderTransportFailure(_ summary: String) {}
}

struct ToolCallAccumulator: Sendable {
    var id: String
    var name: String
    var arguments: String

    init(id: String = "", name: String = "", arguments: String = "") {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

struct AgentLoopResult: Sendable {
    let finalText: String
    let conversation: [ChatRequestMessage]
}

@MainActor
final class AgentLoopEngine {
    typealias ToolExecutorHandler = @MainActor (ProviderToolCall, @escaping @MainActor (ToolExecutionUpdate) -> Void) async -> ToolExecutionOutcome
    typealias SystemPromptProvider = @MainActor () -> String
    typealias ToolsProvider = @MainActor () -> [ChatToolDefinition]
    /// Where the loop takes in messages that arrived while it worked (`PendingUserMessagesProvider`).
    enum SteeringBoundary: Sendable {
        /// Before a model request: every waiting message goes into it.
        case beforeRequest
        /// Among a turn's tool calls: only a message the user wrote is taken, and it supersedes
        /// the calls not yet run. A system notice (a subagent's final turn, finished subagents'
        /// results) waits for the next request, so the calls the model asked for still run.
        case amongToolCalls
    }
    typealias PendingUserMessagesProvider = @MainActor (SteeringBoundary) async -> [ChatRequestMessage]
    typealias SafeBoundaryHandler = @MainActor () async throws -> Void
    typealias ToolCallCanceller = @MainActor ([ProviderToolCall]) async throws -> Void
    typealias WorkingContextProvider = @MainActor (String) async throws -> [ChatRequestMessage]

    private let client: any ProviderClient
    private let logs: DebugLogStore

    init(client: any ProviderClient = OpenAICompatibleClient(), logs: DebugLogStore? = nil) {
        self.client = client
        self.logs = logs ?? DebugLogStore()
    }

    func run(
        provider: ProviderConfiguration,
        apiKey: String,
        modelID: String,
        options: ChatInferenceOptions = ChatInferenceOptions(),
        tools: [ChatToolDefinition],
        toolsProvider: ToolsProvider? = nil,
        configuration: AgentLoopConfiguration,
        initialMessages: [ChatRequestMessage],
        systemPromptProvider: SystemPromptProvider? = nil,
        pendingUserMessagesProvider: PendingUserMessagesProvider? = nil,
        workingContextProvider: WorkingContextProvider? = nil,
        attachmentResolver: @escaping @Sendable (ChatAttachment) throws -> Data = { _ in Data() },
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = nil,
        providerRequestAdmission: (@MainActor (UUID, String) async throws -> Void)? = nil,
        providerRequestReturned: (@MainActor () throws -> Void)? = nil,
        safeBoundary: SafeBoundaryHandler? = nil,
        toolCallCanceller: ToolCallCanceller? = nil,
        toolExecutor: ToolExecutorHandler,
        observer: AgentLoopObserver? = nil
    ) async throws -> AgentLoopResult {
        var conversation = initialMessages
        var lastToolSignature: String?
        var consecutiveIdenticalToolCount = 0
        var totalTurnsExecuted = 0
        var turnsSinceLastUserPrompt = 0

        while true {
            try Task.checkCancellation()
            try await safeBoundary?()
            try Task.checkCancellation()
            if let pendingUserMessagesProvider {
                let pending = await pendingUserMessagesProvider(.beforeRequest)
                if !pending.isEmpty {
                    observer?.onAssistantTurnDiscarded()
                    conversation.append(contentsOf: pending)
                    turnsSinceLastUserPrompt = 0
                    lastToolSignature = nil
                    consecutiveIdenticalToolCount = 0
                }
            }
            // Turn budget is enforced only for explicitly bounded Runs. A
            // Primary Run carries `.unbounded` and therefore never dies on a
            // turn count alone: it stops only for a real terminal cause (final
            // answer, cancellation, provider failure, context exhaustion, fatal
            // persistence error, policy boundary, or the duplicate-call guard).
            if case .bounded(let maximumTurns) = configuration.turnBudget,
               turnsSinceLastUserPrompt >= maximumTurns {
                let error = AgentLoopTerminationReason.turnLimitReached(limit: maximumTurns)
                logs.error("AgentLoop", error.localizedDescription)
                throw error
            }

            let currentTurnIndex = totalTurnsExecuted
            observer?.onTurnStarted(turnIndex: currentTurnIndex)
            totalTurnsExecuted += 1
            turnsSinceLastUserPrompt += 1

            if let systemPromptProvider {
                let updatedSysPrompt = systemPromptProvider()
                let currentSysMessage = ChatRequestMessage(role: "system", content: updatedSysPrompt)
                if conversation.isEmpty {
                    conversation.append(currentSysMessage)
                } else if conversation[0].role == "system" {
                    conversation[0] = currentSysMessage
                } else {
                    conversation.insert(currentSysMessage, at: 0)
                }
            }

            // This runs immediately before every real provider request, after pending
            // steering is admitted and at a protocol-safe boundary.
            if let workingContextProvider {
                let systemPrompt = conversation.first(where: { $0.role == "system" })?.content?.textValue ?? ""
                conversation = try await workingContextProvider(systemPrompt)
            }

            var accumulators: [Int: ToolCallAccumulator] = [:]
            var currentContent = ""
            var currentReasoning: String?
            var currentNativeMetadata: NativeProtocolMetadata?
            var currentEcho: ResponsesReasoningEcho?
            var currentFinishReason: String? = nil

            let activeTools = toolsProvider?() ?? tools

            final class DiagnosticsBox: @unchecked Sendable {
                private let lock = NSLock()
                private var _diagnostics: ProviderStreamDiagnostics?
                var diagnostics: ProviderStreamDiagnostics? {
                    get { lock.lock(); defer { lock.unlock() }; return _diagnostics }
                    set { lock.lock(); _diagnostics = newValue; lock.unlock() }
                }
            }
            let diagBox = DiagnosticsBox()

            let streamCancellation = ProviderStreamCancellationHandle()
            // This is the candidate-attempt boundary: context planning has succeeded
            // and the next operation is the real provider wire request.
            try await providerRequestAdmission?(provider.id, modelID)
            try Task.checkCancellation()
            let stream = client.streamChat(
                provider: provider,
                apiKey: apiKey,
                modelID: modelID,
                messages: conversation,
                tools: activeTools,
                options: options,
                attachmentResolver: attachmentResolver,
                artifactResolver: artifactResolver,
                cancellationHandle: streamCancellation,
                onDiagnostics: { diag in
                    diagBox.diagnostics = diag
                },
                onRequestToolNames: { names in
                    await observer?.onProviderRequestToolNames(names)
                },
                onAttemptStarted: { attempt in
                    await observer?.onProviderRequestStarted(providerID: provider.id, modelID: modelID, requestAttempt: attempt)
                    if var metadata = diagBox.diagnostics?.thinkingMetadata, !metadata.isEmpty {
                        metadata["requestAttempt"] = String(attempt)
                        await observer?.onProviderThinkingResolved(metadata)
                    }
                },
                onRetry: { attempt, reason in
                    await observer?.onProviderRequestRetry(providerID: provider.id, modelID: modelID, requestAttempt: attempt, reason: reason)
                },
                onTransportFailure: { summary in
                    await observer?.onProviderTransportFailure(summary)
                }
            )

            do {
            try await withTaskCancellationHandler {
                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                case .reasoningDelta(let delta):
                    if currentReasoning == nil { currentReasoning = "" }
                    currentReasoning? += delta
                    observer?.onReasoningDelta(delta)
                case .textDelta(let delta):
                    currentContent += delta
                    observer?.onTextDelta(delta)
                case .toolCallDelta(let index, let id, let name, let arguments):
                    var accumulator = accumulators[index] ?? ToolCallAccumulator()
                    if let id, !id.isEmpty { accumulator.id = merged(current: accumulator.id, delta: id) }
                    if let name, !name.isEmpty { accumulator.name = merged(current: accumulator.name, delta: name) }
                    accumulator.arguments += arguments
                    accumulators[index] = accumulator
                    observer?.onToolCallAccumulated(toolIndex: index, accumulator: accumulator)
                case .nativeProtocolMetadata(let metadata):
                    currentNativeMetadata = metadata
                    observer?.onNativeProtocolMetadata(metadata)
                case .responsesReasoningEcho(let echo):
                    currentEcho = echo
                    observer?.onResponsesReasoningEcho(echo)
                case .completed(let reason):
                    if let reason {
                        currentFinishReason = reason
                    }
                    }
                }
            } onCancel: {
                streamCancellation.cancel()
            }
            } catch let ProviderClientError.responsesIncomplete(reason) {
                try Task.checkCancellation()
                currentFinishReason = reason
                if let usage = diagBox.diagnostics?.usage, usage.hasAuthoritativeInputTokens {
                    observer?.onUsageTelemetryReceived(usage: usage, providerID: provider.id, modelID: modelID)
                }
                let outcome = AssistantTurnOutcome.classify(text: currentContent, reasoning: currentReasoning,
                    hasToolCalls: false, diagnostics: diagBox.diagnostics, finishReason: reason)
                throw AssistantTurnError(outcome: outcome, partialText: currentContent, reasoning: currentReasoning,
                    diagnostics: diagBox.diagnostics, finishReason: reason)
            }
            // AsyncThrowingStream may terminate normally when its producer is
            // cancelled. Preserve the consumer task's cancellation as the
            // authoritative result instead of treating an empty stream as a
            // successful assistant turn.
            try Task.checkCancellation()

            if currentFinishReason == nil {
                currentFinishReason = diagBox.diagnostics?.finishReason
            }

            if let usage = diagBox.diagnostics?.usage, usage.hasAuthoritativeInputTokens {
                observer?.onUsageTelemetryReceived(
                    usage: usage,
                    providerID: provider.id,
                    modelID: modelID
                )
            }

            let isOutputTruncated = currentFinishReason == "length" || currentFinishReason == "max_tokens" || currentFinishReason == "max_output_tokens"
            var orderedToolCalls = try accumulators.keys.sorted().map { index -> (Int, ProviderToolCall) in
                guard let accumulator = accumulators[index],
                      !accumulator.id.isEmpty,
                      !accumulator.name.isEmpty else {
                    if isOutputTruncated {
                        throw ProviderClientError.incompleteToolCall("Provider stream was truncated due to output token limit (finish_reason: \(currentFinishReason ?? "length")) before tool call header could be completed.")
                    }
                    throw ProviderClientError.incompleteToolCall("Provider returned an incomplete tool call.")
                }
                return (
                    index,
                    ProviderToolCall(
                        id: accumulator.id,
                        function: .init(name: accumulator.name, arguments: accumulator.arguments),
                        finishReason: currentFinishReason
                    )
                )
            }
            // opencode's tool-call repair: a known name in the wrong case is fixed.
            let advertised = Set(activeTools.map(\.function.name))
            for (position, item) in orderedToolCalls.enumerated() where !advertised.contains(item.1.function.name)
                && advertised.contains(item.1.function.name.lowercased()) {
                orderedToolCalls[position].1 = ProviderToolCall(id: item.1.id,
                    function: .init(name: item.1.function.name.lowercased(), arguments: item.1.function.arguments),
                    finishReason: item.1.finishReason)
            }
            let toolCalls = orderedToolCalls.map(\.1)

            try providerRequestReturned?()
            let outcome = AssistantTurnOutcome.classify(
                text: currentContent, reasoning: currentReasoning, hasToolCalls: !toolCalls.isEmpty,
                diagnostics: diagBox.diagnostics, finishReason: currentFinishReason
            )
            if outcome != .answer && outcome != .toolCalls {
                if (outcome == .noOutput || outcome == .reasoningOnly),
                   let pending = await pendingUserMessagesProvider?(.beforeRequest), !pending.isEmpty {
                    observer?.onAssistantTurnDiscarded()
                    conversation.append(contentsOf: pending)
                    turnsSinceLastUserPrompt = 0
                    lastToolSignature = nil
                    consecutiveIdenticalToolCount = 0
                    continue
                }
                throw AssistantTurnError(outcome: outcome, partialText: currentContent,
                    reasoning: currentReasoning, diagnostics: diagBox.diagnostics, finishReason: currentFinishReason)
            }
            observer?.onAssistantMessageCompleted(
                content: currentContent,
                reasoningContent: currentReasoning,
                toolCalls: toolCalls,
                responsesReasoningEcho: currentEcho
            )

            conversation.append(.assistant(
                content: currentContent,
                reasoningContent: currentReasoning,
                toolCalls: toolCalls,
                responsesReasoningEcho: currentEcho, nativeProtocolMetadata: currentNativeMetadata
            ))

            if toolCalls.isEmpty {
                if let pendingUserMessagesProvider {
                    let pending = await pendingUserMessagesProvider(.beforeRequest)
                    if !pending.isEmpty {
                        conversation.append(contentsOf: pending)
                        turnsSinceLastUserPrompt = 0
                        lastToolSignature = nil
                        consecutiveIdenticalToolCount = 0
                        continue
                    }
                }
                return AgentLoopResult(finalText: currentContent, conversation: conversation)
            }

            try Task.checkCancellation()
            try await safeBoundary?()
            try Task.checkCancellation()

            if let pendingUserMessagesProvider {
                let pending = await pendingUserMessagesProvider(.amongToolCalls)
                if !pending.isEmpty {
                    let callsToCancel = orderedToolCalls.map(\.1)
                    try await toolCallCanceller?(callsToCancel)
                    for (_, call) in orderedToolCalls {
                        conversation.append(.tool(callID: call.id, content: "Not executed: superseded by user instruction."))
                    }
                    conversation.append(contentsOf: pending)
                    turnsSinceLastUserPrompt = 0
                    lastToolSignature = nil
                    consecutiveIdenticalToolCount = 0
                    continue
                }
            }

            for (index, (_, call)) in orderedToolCalls.enumerated() {
                try Task.checkCancellation()
                let signature = "\(call.function.name):\(call.function.arguments)"
                if signature == lastToolSignature {
                    consecutiveIdenticalToolCount += 1
                    if consecutiveIdenticalToolCount >= configuration.consecutiveDuplicateCallLimit {
                        let error = AgentLoopTerminationReason.repeatedToolCall(
                            name: call.function.name,
                            count: consecutiveIdenticalToolCount
                        )
                        logs.error("AgentLoop", error.localizedDescription)
                        throw error
                    }
                } else {
                    lastToolSignature = signature
                    consecutiveIdenticalToolCount = 1
                }

                observer?.onToolExecutionStarted(call: call)
                let outcome = await toolExecutor(call) { _ in }
                observer?.onToolExecutionCompleted(call: call, outcome: outcome)

                conversation.append(.tool(callID: call.id, content: outcome.content, resultParts: outcome.resultParts))

                try Task.checkCancellation()
                try await safeBoundary?()
                try Task.checkCancellation()

                if let pendingUserMessagesProvider {
                    let pending = await pendingUserMessagesProvider(.amongToolCalls)
                    if !pending.isEmpty {
                        let remaining = orderedToolCalls.dropFirst(index + 1).map(\.1)
                        if !remaining.isEmpty {
                            try await toolCallCanceller?(remaining)
                            for remCall in remaining {
                                conversation.append(.tool(callID: remCall.id, content: "Not executed: superseded by user instruction."))
                            }
                        }
                        conversation.append(contentsOf: pending)
                        turnsSinceLastUserPrompt = 0
                        lastToolSignature = nil
                        consecutiveIdenticalToolCount = 0
                        break
                    }
                }
            }
        }
    }

    private func merged(current: String, delta: String) -> String {
        if current.isEmpty { return delta }
        if current == delta { return current }
        if delta.hasPrefix(current) { return delta }
        return current + delta
    }
}
