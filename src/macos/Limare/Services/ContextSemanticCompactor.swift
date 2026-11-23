import Foundation

struct SemanticCompactorConfiguration: Sendable, Equatable {
    var timeoutSeconds: TimeInterval = 120.0
    var summaryOutputBudget: Int = 4000
    var maxStages: Int = 3
    var localCharacterCeiling: Int = 12000
}

struct SemanticCompactorWireRequest: Sendable {
    let providerID: String
    let modelID: String
    let systemPrompt: String
    let userPrompt: String
    let maxOutputTokens: Int
    let thinkingLevel: ThinkingLevel
    let tools: [ChatToolDefinition]
    let secretsToRedact: [String]
    let extraHeaders: [String: String]
    let apiKey: String?
    let apiFormat: ProviderAPIFormat
    let localCharacterCeiling: Int

    init(
        providerID: String,
        modelID: String,
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int,
        thinkingLevel: ThinkingLevel = .off,
        tools: [ChatToolDefinition] = [],
        secretsToRedact: [String] = [],
        extraHeaders: [String: String] = [:],
        apiKey: String? = nil,
        apiFormat: ProviderAPIFormat = .chatCompletions,
        localCharacterCeiling: Int = 12000
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxOutputTokens = maxOutputTokens
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.secretsToRedact = secretsToRedact
        self.extraHeaders = extraHeaders
        self.apiKey = apiKey
        self.apiFormat = apiFormat
        self.localCharacterCeiling = localCharacterCeiling
    }
}

struct SemanticCompactorWireResponse: Sendable {
    let text: String
    let rawToolCallDeltasReceived: Bool

    init(text: String, rawToolCallDeltasReceived: Bool = false) {
        self.text = text
        self.rawToolCallDeltasReceived = rawToolCallDeltasReceived
    }
}

enum SemanticCompactionError: LocalizedError, Equatable {
    case timedOut
    case emptyOutput
    case toolCallEmitted
    case outputCeilingExceeded
    case epistemicValidationFailed(String)
    case transportFailure(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "Semantic compaction timed out."
        case .emptyOutput: return "Semantic compaction returned empty output."
        case .toolCallEmitted: return "Semantic compactor emitted invalid tool calls."
        case .outputCeilingExceeded: return "Semantic compaction exceeded local output character ceiling."
        case .epistemicValidationFailed(let marker): return "Semantic summary omitted required tool epistemic marker: \(marker)."
        case .transportFailure(let message): return "Semantic compaction transport failure: \(message)."
        }
    }
}

protocol ContextSemanticCompactionTransport: Sendable {
    func executeCompaction(
        request: SemanticCompactorWireRequest,
        cancellationHandle: ProviderStreamCancellationHandle?
    ) async throws -> SemanticCompactorWireResponse
}

protocol ContextSemanticCompacting: Sendable {
    func compact(
        previousSummary: String?,
        messages: [ChatMessage],
        candidateOptions: ChatInferenceOptions,
        candidateProviderID: String,
        candidateModelID: String,
        apiKey: String?,
        extraHeaders: [String: String],
        secrets: [String]
    ) async throws -> String
}

@MainActor
final class ContextSemanticCompactor: ContextSemanticCompacting {
    let config: SemanticCompactorConfiguration
    let transport: ContextSemanticCompactionTransport
    let logs: DebugLogStore

    init(
        config: SemanticCompactorConfiguration = SemanticCompactorConfiguration(),
        transport: ContextSemanticCompactionTransport,
        logs: DebugLogStore
    ) {
        self.config = config
        self.transport = transport
        self.logs = logs
    }

    func compact(
        previousSummary: String?,
        messages: [ChatMessage],
        candidateOptions: ChatInferenceOptions,
        candidateProviderID: String,
        candidateModelID: String,
        apiKey: String?,
        extraHeaders: [String: String],
        secrets: [String]
    ) async throws -> String {
        try Task.checkCancellation()

        let rawUserMessage = ContextCompactionSourceBuilder.buildUserSourceMessage(
            previousSummary: previousSummary,
            messages: messages
        )
        let rawSystemPrompt = ContextCompactionSourceBuilder.systemPrompt

        // 1. Pre-wire credential redaction
        var allSecrets = secrets
        if let apiKey, !apiKey.isEmpty { allSecrets.append(apiKey) }
        for (_, headerVal) in extraHeaders where !headerVal.isEmpty {
            allSecrets.append(headerVal)
        }

        let redactedSystem = SecretMasker.redactCredentials(rawSystemPrompt, secrets: allSecrets)
        let redactedUser = SecretMasker.redactCredentials(rawUserMessage, secrets: allSecrets)

        let wireRequest = SemanticCompactorWireRequest(
            providerID: candidateProviderID,
            modelID: candidateModelID,
            systemPrompt: redactedSystem,
            userPrompt: redactedUser,
            maxOutputTokens: config.summaryOutputBudget,
            thinkingLevel: .off,
            tools: [],
            secretsToRedact: allSecrets,
            extraHeaders: extraHeaders,
            apiKey: apiKey,
            apiFormat: candidateOptions.apiFormat ?? .chatCompletions,
            localCharacterCeiling: config.localCharacterCeiling
        )

        let cancellationHandle = ProviderStreamCancellationHandle()

        // Structured timeout / cancellation race
        let rawResponse: SemanticCompactorWireResponse
        do {
            rawResponse = try await withThrowingTaskGroup(of: SemanticCompactorWireResponse.self) { group in
                group.addTask {
                    try await self.transport.executeCompaction(request: wireRequest, cancellationHandle: cancellationHandle)
                }
                group.addTask {
                    let duration = UInt64(self.config.timeoutSeconds * 1_000_000_000)
                    try await Task.sleep(nanoseconds: duration)
                    try Task.checkCancellation()
                    cancellationHandle.cancel()
                    throw SemanticCompactionError.timedOut
                }

                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            cancellationHandle.cancel()
            throw CancellationError()
        } catch {
            cancellationHandle.cancel()
            throw error
        }

        try Task.checkCancellation()

        // 2. Reject tool calls if provider ignored tools: []
        if rawResponse.rawToolCallDeltasReceived {
            throw SemanticCompactionError.toolCallEmitted
        }

        // 3. Strip optional <analysis> scratchpad and redact credentials post-output
        let strippedResponse = Self.stripAnalysisScratchpad(rawResponse.text)
        let redactedSummary = SecretMasker.redactCredentials(strippedResponse, secrets: allSecrets)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !redactedSummary.isEmpty else {
            throw SemanticCompactionError.emptyOutput
        }

        if redactedSummary.count > config.localCharacterCeiling {
            throw SemanticCompactionError.outputCeilingExceeded
        }

        func containsAny(_ text: String, _ needles: [String]) -> Bool {
            needles.contains { text.localizedCaseInsensitiveContains($0) }
        }

        // 4. Semantic Epistemic Tool Outcome Validation (bilingual)
        let requiredMarkers = ContextCompactionSourceBuilder.requiredEpistemicMarkers(in: messages, previousSummary: previousSummary)
        for marker in requiredMarkers {
            if marker == "[failed]" {
                if !containsAny(redactedSummary, ["[failed]", "failed", "失败", "报错"]) {
                    throw SemanticCompactionError.epistemicValidationFailed("[failed]")
                }
            } else if marker == "[denied]" {
                if !containsAny(redactedSummary, ["[denied]", "denied", "拒绝", "未获批"]) {
                    throw SemanticCompactionError.epistemicValidationFailed("[denied]")
                }
            } else if marker == "[timed out]" {
                if !containsAny(redactedSummary, ["[timed out]", "timed out", "超时"]) {
                    throw SemanticCompactionError.epistemicValidationFailed("[timed out]")
                }
            } else if marker == "[interrupted" {
                if !containsAny(redactedSummary, ["[interrupted", "outcome unknown", "interrupted", "中断", "结果未知"]) {
                    throw SemanticCompactionError.epistemicValidationFailed("[interrupted / outcome unknown]")
                }
            }
        }

        // 5. Semantic Completed Mutation Tool Validation (CTX-I10, bilingual)
        let requiredMutationTools = ContextCompactionSourceBuilder.requiredCompletedMutationTools(in: messages, previousSummary: previousSummary)
        for toolName in requiredMutationTools {
            var targetBasenames: [String] = []
            for message in messages {
                for call in message.toolCalls where call.name == toolName && call.state == .completed {
                    if let path = ToolCallFileTargetResolver.extractPath(from: call) {
                        let base = (path as NSString).lastPathComponent
                        if !base.isEmpty { targetBasenames.append(base) }
                    }
                }
            }
            let hasToolName = redactedSummary.localizedCaseInsensitiveContains(toolName)
                || targetBasenames.contains { redactedSummary.localizedCaseInsensitiveContains($0) }
            let hasCompletedMarker = containsAny(redactedSummary, [
                "[completed]", "completed", "success", "modified", "wrote", "created", "saved",
                "已完成", "已修改", "修改了", "已写入", "写入了", "已创建", "创建了", "已编辑", "已保存"
            ])
            if !hasToolName || !hasCompletedMarker {
                throw SemanticCompactionError.epistemicValidationFailed("Completed mutation tool fact missing for: \(toolName)")
            }
        }

        return redactedSummary
    }

    /// Strips optional `<analysis>...</analysis>` scratchpad blocks while preserving inner content
    /// if a model places the entire response inside `<analysis>`.
    nonisolated static func stripAnalysisScratchpad(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(of: #"<analysis>[\s\S]*?</analysis>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stripped.isEmpty {
            return stripped
        }
        return text
            .replacingOccurrences(of: #"</?analysis>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class DefaultSemanticCompactionTransport: ContextSemanticCompactionTransport {
    private let client: any ProviderClient
    private let provider: ProviderConfiguration?
    private let conversationID: UUID?
    private let requestAdmission: (@MainActor @Sendable (UUID, String) async throws -> Void)?
    private let requestReturned: (@MainActor @Sendable () throws -> Void)?

    init(client: any ProviderClient, provider: ProviderConfiguration? = nil,
         conversationID: UUID? = nil,
         requestAdmission: (@MainActor @Sendable (UUID, String) async throws -> Void)? = nil,
         requestReturned: (@MainActor @Sendable () throws -> Void)? = nil) {
        self.client = client
        self.provider = provider
        self.conversationID = conversationID
        self.requestAdmission = requestAdmission
        self.requestReturned = requestReturned
    }

    func executeCompaction(
        request: SemanticCompactorWireRequest,
        cancellationHandle: ProviderStreamCancellationHandle?
    ) async throws -> SemanticCompactorWireResponse {
        let messages: [ChatRequestMessage] = [
            ChatRequestMessage(role: "system", content: request.systemPrompt),
            ChatRequestMessage(role: "user", content: request.userPrompt)
        ]

        let resolvedModel = self.provider?.models.first(where: { $0.id == request.modelID })
            ?? ProviderModel(id: request.modelID, displayName: request.modelID, baseContextWindow: nil, baseMaxOutputTokens: request.maxOutputTokens)
        var options = ChatInferenceOptions(
            thinkingLevel: .off,
            maxOutputTokens: request.maxOutputTokens,
            model: resolvedModel,
            providerID: UUID(uuidString: request.providerID),
            apiFormat: request.apiFormat,
            usageKind: .compaction
        )
        options.conversationID = self.conversationID

        var activeProvider = self.provider ?? ProviderConfiguration(
            id: UUID(uuidString: request.providerID) ?? UUID(),
            name: "CompactorProvider",
            baseURL: "https://api.openai.com",
            appendV1Suffix: true,
            authenticationMode: .bearer,
            apiFormat: request.apiFormat,
            extraHeaders: request.extraHeaders
        )
        activeProvider.extraHeaders = request.extraHeaders

        var accumulatedText = ""
        var toolCallsReceived = false

        try await requestAdmission?(activeProvider.id, request.modelID)
        let stream = client.streamChat(
            provider: activeProvider,
            apiKey: request.apiKey,
            modelID: request.modelID,
            messages: messages,
            tools: [],
            options: options,
            attachmentResolver: nil,
            cancellationHandle: cancellationHandle
        )

        do {
        for try await event in stream {
            switch event {
            case .textDelta(let text):
                accumulatedText += text
                // Allow headroom for <analysis> scratchpad tokens during streaming;
                // post-strip validation in compact() still enforces localCharacterCeiling.
                if accumulatedText.count > request.localCharacterCeiling * 2 {
                    cancellationHandle?.cancel()
                    throw SemanticCompactionError.outputCeilingExceeded
                }
            case .toolCallDelta:
                toolCallsReceived = true
            case .reasoningDelta, .responsesReasoningEcho, .nativeProtocolMetadata, .completed:
                break
            }
        }
        try await requestReturned?()
        } catch {
            try? await requestReturned?()
            throw error
        }

        return SemanticCompactorWireResponse(
            text: accumulatedText,
            rawToolCallDeltasReceived: toolCallsReceived
        )
    }
}
