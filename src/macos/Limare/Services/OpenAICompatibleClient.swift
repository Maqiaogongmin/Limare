import Foundation
#if canImport(OpenMinisProviders)
import OpenMinisProviders
#endif

final class ProviderStreamCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

enum ProviderClientError: LocalizedError, Equatable {
    case invalidResponse
    case http(status: Int, message: String)
    case invalidModelsPayload
    case emptyStream
    case incompleteToolCall(String)
    case responsesFailed(code: String, message: String)
    case responsesIncomplete(reason: String)
    /// An error object sent inside an accepted (HTTP 2xx) stream. It carries no HTTP status:
    /// the request was taken and the stream broke, so only `code` says whether a retry can help.
    case streamError(code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "The provider returned an invalid HTTP response.")
        case .http(let status, let message):
            message.isEmpty ? String(localized: "Provider request failed with HTTP \(status).") : String(localized: "HTTP \(status): \(message)")
        case .invalidModelsPayload:
            String(localized: "The provider response did not contain a models data array.")
        case .emptyStream:
            String(localized: "The provider completed the stream without returning text.")
        case .incompleteToolCall(let message):
            String(localized: "Provider stream returned an incomplete tool call: \(message)")
        case .responsesFailed(let code, let message):
            message.isEmpty ? String(localized: "Responses API request failed with code \(code).") : String(localized: "Responses API error [\(code)]: \(message)")
        case .responsesIncomplete(let reason):
            String(localized: "Responses stream incomplete: \(reason)")
        case .streamError(let code, let message):
            code.map { String(localized: "Provider stream error [\($0)]: \(message)") } ?? String(localized: "Provider stream error: \(message)")
        }
    }
}

enum ProviderHTTPRetrySignal {
    // Some gateways report temporary admission failures as HTTP 400 and put
    // the retry interval in the error body instead of the Retry-After header.
    static func delayFromMessage(_ message: String) -> Double? {
        let pattern = #"\bretry\s+after\s+([0-9]{1,3})\s+seconds?\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message),
              let seconds = Double(message[range]), seconds <= 120 else { return nil }
        return max(1, seconds)
    }
}

final class StreamUsageCompatibility: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected: [UUID: String] = [:]
    private var generations: [UUID: Int] = [:]
    private func signature(_ provider: ProviderConfiguration) -> String {
        "\(provider.baseURL)|\(provider.apiFormat.rawValue)|\(provider.requestStreamUsage ?? true)"
    }
    func isRejected(_ provider: ProviderConfiguration) -> Bool { lock.withLock { rejected[provider.id] == signature(provider) } }
    func generation(_ id: UUID) -> Int { lock.withLock { generations[id, default: 0] } }
    func markRejected(_ provider: ProviderConfiguration, generation: Int) {
        let changed = lock.withLock {
            guard generations[provider.id, default: 0] == generation else { return false }
            rejected[provider.id] = signature(provider)
            return true
        }
        if changed { NotificationCenter.default.post(name: .streamUsageCompatibilityChanged, object: nil) }
    }
    func invalidate(_ id: UUID) {
        let changed = lock.withLock {
            let removed = rejected.removeValue(forKey: id) != nil
            generations[id, default: 0] += 1
            return removed
        }
        if changed { NotificationCenter.default.post(name: .streamUsageCompatibilityChanged, object: nil) }
    }
}

extension Notification.Name {
    static let streamUsageCompatibilityChanged = Notification.Name("LimareStreamUsageCompatibilityChanged")
}

struct OpenAICompatibleClient: ProviderClient {
    private let session: URLSession
    private var credentialResolver: (@Sendable (ProviderConfiguration) async throws -> String)?
    private var usageRecorder: UsageRecorder?
    private let streamUsageCompatibility: StreamUsageCompatibility

    private static let productionSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Allow slow provider responses and long streams while keeping both waits bounded.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    init(session: URLSession = OpenAICompatibleClient.productionSession) {
        self.session = session
        self.credentialResolver = nil
        self.usageRecorder = nil
        self.streamUsageCompatibility = StreamUsageCompatibility()
    }

    func recordingUsage(_ recorder: UsageRecorder?) -> Self {
        var copy = self
        copy.usageRecorder = recorder
        return copy
    }

    func streamUsageWasRejected(_ provider: ProviderConfiguration) -> Bool { streamUsageCompatibility.isRejected(provider) }
    func invalidateStreamUsageCompatibility(_ id: UUID) { streamUsageCompatibility.invalidate(id) }

    func resolvingCredentials(_ resolver: @escaping @Sendable (ProviderConfiguration) async throws -> String) -> Self {
        var copy = self
        copy.credentialResolver = resolver
        return copy
    }

    func fetchModels(provider: ProviderConfiguration, apiKey: String? = nil) async throws -> [ProviderModel] {
        try await fetchModelDiscovery(provider: provider, apiKey: apiKey).models
    }

    func fetchModelDiscovery(
        provider: ProviderConfiguration,
        apiKey: String? = nil
    ) async throws -> ModelDiscoveryResult {
        try ProviderProductPolicy.validate(provider)
        let apiKey = provider.authenticationSelection.credentialKind == .oauthAccessToken
            ? try await credentialResolver?(provider) ?? apiKey : apiKey
        let url = try ProviderRequestConfigurator.modelsEndpoint(provider)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: false
        )

        let redirectGuard = TransportMetricsRecorder(restrictOAuthResource: provider.authenticationSelection.credentialKind == .oauthAccessToken)
        var items: [[String: Any]] = []
        var root: [String: Any] = [:]
        var seenCursors: Set<String> = []
        var remainingPages = false
        for page in 0..<16 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            try validate(response: response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProviderClientError.invalidModelsPayload }
            root = object
            if let rows = root["data"] as? [[String: Any]] { items += rows }
            else if let rows = root["models"] as? [[String: Any]] { items += rows }
            else { throw ProviderClientError.invalidModelsPayload }
            let cursor: String?
            let cursorKey: String
            if provider.protocolAdapter == .geminiNative {
                cursor = root["nextPageToken"] as? String; cursorKey = "pageToken"
            } else if provider.protocolAdapter == .anthropicMessages, root["has_more"] as? Bool == true {
                cursor = root["last_id"] as? String; cursorKey = "after_id"
            } else { cursor = nil; cursorKey = "" }
            guard let cursor, !cursor.isEmpty else { break }
            remainingPages = true
            guard page < 15, seenCursors.insert(cursor).inserted,
                  var components = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { break }
            var query = components.queryItems ?? []
            query.removeAll { $0.name == cursorKey }
            query.append(URLQueryItem(name: cursorKey, value: cursor))
            components.queryItems = query
            request.url = components.url
            remainingPages = false
        }
        let visible = items.filter { row in
            if provider.authenticationSelection.credentialKind == .oauthAccessToken { return row["visibility"] as? String == "list" }
            if provider.protocolAdapter == .geminiNative, let methods = row["supportedGenerationMethods"] as? [String] {
                return methods.contains("generateContent")
            }
            return true
        }
        let models = visible.compactMap { item -> ProviderModel? in
            let rawID = item["id"] as? String ?? item["slug"] as? String
                ?? (provider.apiFormat == .geminiNative ? item["name"] as? String : nil)
            guard let rawID, !rawID.isEmpty else { return nil }
            let id = provider.apiFormat == .geminiNative && rawID.hasPrefix("models/") ? String(rawID.dropFirst(7)) : rawID
            let name = item["display_name"] as? String ?? item["displayName"] as? String
                ?? (provider.apiFormat == .geminiNative ? nil : item["name"] as? String) ?? id
            let top = item["top_provider"] as? [String: Any]
            let ctx = item["context_length"] as? Int ?? item["inputTokenLimit"] as? Int
            let maxOut = item["outputTokenLimit"] as? Int ?? top?["max_completion_tokens"] as? Int
            let reasoning = item["supports_reasoning"] as? Bool
            let effort = item["reasoning_effort_values"] as? [String]

            let prov = ModelCapabilityProvenance(
                modality: .unknown,
                contextWindow: ctx != nil ? .providerDeclaration : .unknown,
                maxOutputTokens: maxOut != nil ? .providerDeclaration : .unknown,
                reasoning: reasoning != nil ? .providerDeclaration : .unknown,
                reasoningEffort: effort != nil ? .providerDeclaration : .unknown
            )

            var modelObj = ProviderModel(
                id: id,
                displayName: name,
                baseContextWindow: ctx,
                baseMaxOutputTokens: maxOut,
                baseSupportsReasoning: reasoning,
                reasoningEffortValues: effort,
                baseMetadataSource: nil
            )
            modelObj.baseCapabilityProvenance = prov
            return modelObj
        }
        let paginated = remainingPages || (root["has_more"] as? Bool == true) || ["next", "nextPageToken", "next_page_token"].contains {
            guard let value = root[$0], !(value is NSNull) else { return false }
            if let str = value as? String { return !str.isEmpty }
            return true
        }
        let completeness: ModelDiscoveryCompleteness = models.count != visible.count ? .decodeTruncated : paginated ? .pagination : .complete
        return ModelDiscoveryResult(models: models, completeness: completeness, fetchedAt: Date())

    }

    func streamChat(
        provider: ProviderConfiguration,
        apiKey: String? = nil,
        modelID: String,
        messages: [ChatRequestMessage],
        tools: [ChatToolDefinition] = [],
        options: ChatInferenceOptions = ChatInferenceOptions(),
        attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)? = nil,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = nil,
        cancellationHandle: ProviderStreamCancellationHandle? = nil,
        onDiagnostics: (@Sendable (ProviderStreamDiagnostics) -> Void)? = nil,
        onRequestToolNames: (@Sendable ([String]) async -> Void)? = nil,
        onAttemptStarted: (@Sendable (Int) async -> Void)? = nil,
        onRetry: (@Sendable (Int, String) async -> Void)? = nil,
        onTransportFailure: (@Sendable (String) async -> Void)? = nil
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var options = options
                options.model = options.model ?? provider.models.first(where: { $0.id == modelID })
                let modelName = provider.models.first(where: { $0.id == modelID })?.displayName
                    ?? (options.model?.id == modelID ? options.model?.displayName : nil) ?? modelID
                var record = UsageRequestRecord(providerID: provider.id, providerName: provider.name,
                    modelID: modelID, modelName: modelName, format: provider.apiFormat, kind: options.usageKind)
                var omitUsageOption = streamUsageCompatibility.isRejected(provider)
                let compatibilityGeneration = streamUsageCompatibility.generation(provider.id)
                var fallbackPending = false
                var fallbackAttempted = false
                func finishRecord(_ outcome: UsageOutcome) async {
                    guard record.attemptCount > 0, let usageRecorder else { return }
                    record.endedAt = Date(); record.outcome = outcome
                    await usageRecorder.append(record)
                }
                for attempt in 1...Self.maximumRequestAttempts {
                    let metrics = TransportMetricsRecorder(restrictOAuthResource: provider.authenticationSelection.credentialKind == .oauthAccessToken)
                    var semanticOutput = false
                    var retryResponse: HTTPURLResponse?
                    var usageOptionRejected = false
                    var dispatched = false
                    let capture = UsageAttemptCapture()
                    let callback: @Sendable (ProviderStreamDiagnostics) -> Void = { diagnostics in
                        capture.update(diagnostics)
                        onDiagnostics?(diagnostics)
                    }
                    func finishAttempt(finished: Bool, excluded: Bool = false) {
                        guard dispatched else { return }
                        let diagnostics = capture.diagnostics
                        record.addAttempt(diagnostics?.usage, finished: finished && diagnostics?.completedReceived == true, excluded: excluded)
                        dispatched = false
                    }
                    do {
                        try Task.checkCancellation()
                        try ProviderProductPolicy.validate(provider)
                        let apiKey = provider.authenticationSelection.credentialKind == .oauthAccessToken
            ? try await credentialResolver?(provider) ?? apiKey : apiKey
                        guard options.thinkingLevel != .ultra else {
                            throw ProviderConnectionError.invalidThinking(String(localized: "Ultra requires a separate harness orchestration feature. Select a supported reasoning tier."))
                        }
                        switch provider.apiFormat {
                        case .anthropicMessages, .geminiNative:
                            #if canImport(OpenMinisProviders)
                            try ProviderProductPolicy.validate(provider)
                            var projectionOptions = options
                            projectionOptions.thinkingLevel = .off
                            let projected = try OpenAIChatRequestBuilder.buildPayload(provider: provider, modelID: modelID,
                                messages: messages, tools: tools, options: projectionOptions,
                                attachmentResolver: attachmentResolver, artifactResolver: artifactResolver)
                            let messageData = try JSONSerialization.data(withJSONObject: projected["messages"] ?? [])
                            let toolData = try JSONEncoder().encode(tools)
                            let matching = messages.compactMap { $0.nativeProtocolMetadata }.filter {
                                $0.providerID == provider.id && $0.modelID == modelID
                                    && $0.authenticationIdentityID == provider.authenticationSelection.authenticationIdentityID
                                    && $0.protocolAdapter == provider.apiFormat
                            }
                            var signatures: [String: String] = [:]
                            var thinking: [String: [[String: Any]]] = [:]
                            for prior in matching {
                                guard let object = try JSONSerialization.jsonObject(with: prior.payload) as? [String: Any] else { continue }
                                if let values = object["toolSignatures"] as? [String: String] { signatures.merge(values) { _, new in new } }
                                if let ids = object["toolCallIDs"] as? [String], let blocks = object["thinkingBlocks"] as? [[String: Any]] {
                                    for id in ids { thinking[id] = blocks }
                                }
                            }
                            let continuationData = try JSONSerialization.data(withJSONObject: ["toolSignatures": signatures, "thinkingByToolCallID": thinking])
                            let resolution = try ProviderThinkingResolution.resolve(requested: options.thinkingLevel, model: options.model, provider: provider, maxTokens: options.resolvedMaxOutputTokens())
                            let wire: NativeWireProtocol = provider.apiFormat == .anthropicMessages ? .anthropicMessages : .geminiNative
                            var request = try NativeWireCodec.request(protocol: wire, baseURL: provider.baseURL,
                                appendV1: provider.appendV1Suffix, apiKey: apiKey ?? "", modelID: modelID,
                                messagesJSON: messageData, toolsJSON: toolData,
                                maxTokens: options.resolvedMaxOutputTokens(for: options.model),
                                thinking: resolution.effective.rawValue,
                                supportsReasoning: options.model?.supportsReasoning,
                                effortValues: options.model?.reasoningEffortValues,
                                continuationJSON: continuationData, kimiCodeProfile: provider.providerIdentity == .kimiCode)
                            ProviderRequestConfigurator.configureHeaders(request: &request, provider: provider, apiKey: apiKey, isChat: true)
                            await onRequestToolNames?(tools.map(\.function.name))
                            let reportDiagnostics = Self.diagnosticsReporter(callback, provider: provider, modelID: modelID, options: options, request: request)
                            reportDiagnostics?(ProviderStreamDiagnostics())
                            let scope = provider.id.uuidString + ":" + (request.url?.host ?? "")
                            try await ProviderRequestCooldown.shared.wait(scope: scope)
                            try Task.checkCancellation()
                            await onAttemptStarted?(attempt)
                            dispatched = true; record.attemptCount += 1
                            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
                            guard let http = response as? HTTPURLResponse else { throw ProviderClientError.invalidResponse }
                            retryResponse = http
                            guard (200..<300).contains(http.statusCode) else {
                                let body = try await readLimitedBody(bytes: bytes)
                                throw ProviderClientError.http(status: http.statusCode, message: Self.httpErrorMessage(from: body, status: http.statusCode))
                            }
                            let decoder = NativeStreamDecoder(protocol: wire)
                            var nativeDiagnostics = ProviderStreamDiagnostics(streamOpened: true)
                            for try await line in bytes.lines {
                                try Task.checkCancellation()
                                let decoded: [NativeDecodedEvent]
                                do { decoded = try decoder.parseLine(line) }
                                catch {
                                    if let raw = decoder.latestUsage {
                                        let usage = ProviderUsageTelemetry(inputTokens: raw.input, outputTokens: raw.output,
                                            totalTokens: raw.total, cacheReadTokens: raw.cacheRead, cacheWriteTokens: raw.cacheWrite,
                                            reasoningTokens: raw.reasoning, toolUsePromptTokens: raw.toolUsePrompt)
                                        if usage.hasAnyValue {
                                            nativeDiagnostics.usage = nativeDiagnostics.usage?.merged(with: usage) ?? usage
                                            reportDiagnostics?(nativeDiagnostics)
                                        }
                                    }
                                    if case NativeWireError.streamError(let code, let message) = error {
                                        throw ProviderClientError.streamError(code: code, message: message)
                                    }
                                    throw error
                                }
                                for event in decoded {
                                    let projectedEvent: AgentStreamEvent?
                                    switch event {
                                    case .text(let t):
                                        nativeDiagnostics.textCharacters += t.count
                                        projectedEvent = .textDelta(t)
                                    case .thinking(let t):
                                        nativeDiagnostics.reasoningCharacters += t.count
                                        projectedEvent = .reasoningDelta(t)
                                    case .tool(let i, let id, let name, let args):
                                        nativeDiagnostics.toolCallEvents += 1
                                        projectedEvent = .toolCallDelta(index: i, id: id, name: name, arguments: args)
                                    case .metadata(let data): projectedEvent = .nativeProtocolMetadata(NativeProtocolMetadata(
                                        providerID: provider.id, modelID: modelID,
                                        authenticationIdentityID: provider.authenticationSelection.authenticationIdentityID,
                                        protocolAdapter: provider.apiFormat, payload: data))
                                    case .completed(let reason):
                                        nativeDiagnostics.completedReceived = true
                                        nativeDiagnostics.finishReason = reason
                                        projectedEvent = .completed(finishReason: reason)
                                    case .usage(let raw):
                                        let usage = ProviderUsageTelemetry(inputTokens: raw.input, outputTokens: raw.output,
                                            totalTokens: raw.total, cacheReadTokens: raw.cacheRead, cacheWriteTokens: raw.cacheWrite,
                                            reasoningTokens: raw.reasoning, toolUsePromptTokens: raw.toolUsePrompt)
                                        if usage.hasAnyValue { nativeDiagnostics.usage = nativeDiagnostics.usage?.merged(with: usage) ?? usage }
                                        projectedEvent = nil
                                    }
                                    reportDiagnostics?(nativeDiagnostics)
                                    if let projectedEvent {
                                        semanticOutput = semanticOutput || Self.isSemanticOutput(projectedEvent)
                                        continuation.yield(projectedEvent)
                                    }
                                }
                            }
                            try decoder.finish()
                            finishAttempt(finished: true)
                            await finishRecord(.completed)
                            continuation.finish()
                            return
                            #else
                            throw ProviderConnectionError.unsupportedProtocol
                            #endif
                        case .chatCompletions:
                            var wireProvider = provider
                            if omitUsageOption { wireProvider.requestStreamUsage = false }
                            let request = try OpenAIChatRequestBuilder.buildURLRequest(
                                provider: wireProvider,
                                apiKey: apiKey,
                                modelID: modelID,
                                messages: messages,
                                tools: tools,
                                options: options,
                                attachmentResolver: attachmentResolver,
                                artifactResolver: artifactResolver
                            )

                            // Inspect only tool names from the serialized body actually dispatched.
                            if let body = request.httpBody,
                               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                                let wireTools = object["tools"] as? [[String: Any]] ?? []
                                let names = wireTools.compactMap { tool in
                                    (tool["function"] as? [String: Any])?["name"] as? String ?? tool["name"] as? String
                                }
                                await onRequestToolNames?(names)
                            }
                            let reportDiagnostics = Self.diagnosticsReporter(callback, provider: provider, modelID: modelID, options: options, request: request)
                            reportDiagnostics?(ProviderStreamDiagnostics())
                            let scope = provider.id.uuidString + ":" + (request.url?.host ?? "")
                            try await ProviderRequestCooldown.shared.wait(scope: scope)
                            try Task.checkCancellation()
                            await onAttemptStarted?(attempt)
                            dispatched = true; record.attemptCount += 1
                            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
                            guard let http = response as? HTTPURLResponse else {
                                throw ProviderClientError.invalidResponse
                            }
                            retryResponse = http
                            guard (200..<300).contains(http.statusCode) else {
                                let body = try await readLimitedBody(bytes: bytes)
                                var message = Self.httpErrorMessage(from: body, status: http.statusCode)
                                usageOptionRejected = Self.rejectsStreamUsage(status: http.statusCode, message: String(decoding: body, as: UTF8.self))
                                if [400, 422].contains(http.statusCode), !omitUsageOption, (provider.requestStreamUsage ?? true),
                                   !usageOptionRejected {
                                    message += " " + String(localized: "You can try turning off Request streaming usage in advanced provider settings.")
                                }
                                throw ProviderClientError.http(
                                    status: http.statusCode,
                                    message: message
                                )
                            }
                            if fallbackPending {
                                streamUsageCompatibility.markRejected(provider, generation: compatibilityGeneration)
                                fallbackPending = false
                            }

                            var parser = OpenAIStreamParser(model: options.model)
                            for try await rawLine in bytes.lines {
                                try Task.checkCancellation()
                                let events: [AgentStreamEvent]
                                do { events = try parser.parseLine(rawLine) }
                                catch { reportDiagnostics?(parser.diagnostics); throw error }
                                reportDiagnostics?(parser.diagnostics)
                                for event in events {
                                    semanticOutput = semanticOutput || Self.isSemanticOutput(event)
                                    continuation.yield(event)
                                }
                                if parser.isDone {
                                    break
                                }
                            }

                            let trailing = parser.finish()
                            reportDiagnostics?(parser.diagnostics)
                            for event in trailing {
                                semanticOutput = semanticOutput || Self.isSemanticOutput(event)
                                continuation.yield(event)
                            }

                            guard parser.hasEmittedAnyOutput || parser.diagnostics.streamOpened || parser.diagnostics.completedReceived else { throw ProviderClientError.emptyStream }
                            finishAttempt(finished: true)
                            await finishRecord(.completed)
                            continuation.finish()
                            return

                        case .responses:
                            let request = try OpenAIResponsesRequestBuilder.buildURLRequest(
                                provider: provider,
                                apiKey: apiKey,
                                modelID: modelID,
                                messages: messages,
                                tools: tools,
                                options: options,
                                attachmentResolver: attachmentResolver,
                                artifactResolver: artifactResolver
                            )

                            // Inspect only tool names from the serialized body actually dispatched.
                            if let body = request.httpBody,
                               let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                                let wireTools = object["tools"] as? [[String: Any]] ?? []
                                let names = wireTools.compactMap { tool in
                                    (tool["function"] as? [String: Any])?["name"] as? String ?? tool["name"] as? String
                                }
                                await onRequestToolNames?(names)
                            }
                            let reportDiagnostics = Self.diagnosticsReporter(callback, provider: provider, modelID: modelID, options: options, request: request)
                            reportDiagnostics?(ProviderStreamDiagnostics())
                            let scope = provider.id.uuidString + ":" + (request.url?.host ?? "")
                            try await ProviderRequestCooldown.shared.wait(scope: scope)
                            try Task.checkCancellation()
                            await onAttemptStarted?(attempt)
                            dispatched = true; record.attemptCount += 1
                            let (bytes, response) = try await session.bytes(for: request, delegate: metrics)
                            guard let http = response as? HTTPURLResponse else {
                                throw ProviderClientError.invalidResponse
                            }
                            retryResponse = http
                            guard (200..<300).contains(http.statusCode) else {
                                let body = try await readLimitedBody(bytes: bytes)
                                throw ProviderClientError.http(
                                    status: http.statusCode,
                                    message: Self.httpErrorMessage(from: body, status: http.statusCode)
                                )
                            }

                            var parser = OpenAIResponsesStreamParser(providerID: provider.id, modelID: modelID)
                            for try await rawLine in bytes.lines {
                                try Task.checkCancellation()
                                let events: [AgentStreamEvent]
                                do { events = try parser.parseLine(rawLine) }
                                catch { reportDiagnostics?(parser.diagnostics); throw error }
                                reportDiagnostics?(parser.diagnostics)
                                for event in events {
                                    semanticOutput = semanticOutput || Self.isSemanticOutput(event)
                                    continuation.yield(event)
                                }
                                if parser.isDone {
                                    break
                                }
                            }

                            let trailing = parser.finish()
                            reportDiagnostics?(parser.diagnostics)
                            for event in trailing {
                                semanticOutput = semanticOutput || Self.isSemanticOutput(event)
                                continuation.yield(event)
                            }

                            guard parser.hasEmittedAnyOutput || parser.diagnostics.streamOpened || parser.diagnostics.completedReceived else { throw ProviderClientError.emptyStream }
                            finishAttempt(finished: true)
                            await finishRecord(.completed)
                            continuation.finish()
                            return
                        }
                    } catch {
                        let rejectedUsage: Bool
                        if provider.apiFormat == .chatCompletions, !omitUsageOption, (provider.requestStreamUsage ?? true),
                           case .http(let status, let message) = error as? ProviderClientError {
                            rejectedUsage = usageOptionRejected || Self.rejectsStreamUsage(status: status, message: message)
                        } else { rejectedUsage = false }
                        finishAttempt(finished: false, excluded: rejectedUsage)
                        if rejectedUsage, !fallbackAttempted, !Task.isCancelled, attempt < Self.maximumRequestAttempts {
                            fallbackAttempted = true; fallbackPending = true; omitUsageOption = true
                            await onRetry?(attempt + 1, "stream_usage_unsupported")
                            continue
                        }
                        if let urlError = error as? URLError, urlError.code != .cancelled {
                            await onTransportFailure?(TransportMetricsRecorder.summary(urlError, metrics.value))
                        }
                        guard !Task.isCancelled, !(error is CancellationError),
                              attempt < Self.maximumRequestAttempts, !semanticOutput,
                              RateLimitFallback.current?.available != true,
                              Self.isTransient(error, response: retryResponse) else {
                            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                            await finishRecord(cancelled ? .cancelled : .failed)
                            continuation.finish(throwing: error)
                            return
                        }
                        let delay: Double
                        if let http = retryResponse, http.value(forHTTPHeaderField: "Retry-After") != nil || http.statusCode == 429 {
                            guard let value = Self.rateLimitDelay(http: http, attempt: attempt - 1) else {
                                await finishRecord(.failed)
                                continuation.finish(throwing: error)
                                return
                            }
                            delay = value
                        } else if case .http(400, let message) = error as? ProviderClientError,
                                  let value = ProviderHTTPRetrySignal.delayFromMessage(message) {
                            delay = value
                        } else {
                            delay = 0.5 * pow(2, Double(attempt - 1))
                        }
                        do {
                            try Task.checkCancellation()
                            await onRetry?(attempt + 1, Self.retryReason(error))
                            if retryResponse?.statusCode == 429 {
                                let scope = provider.id.uuidString + ":" + (retryResponse?.url?.host ?? "")
                                await ProviderRequestCooldown.shared.deferRequests(scope: scope, seconds: delay)
                            } else {
                                try await Task.sleep(for: .seconds(delay))
                            }
                        } catch {
                            await finishRecord(.cancelled)
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
            }
            cancellationHandle?.register(task)
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                cancellationHandle?.cancel()
            }
        }
    }


    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderClientError.http(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
    }

    /// While a model group can still fall back (another candidate, no tool run yet in this attempt),
    /// a 429 goes straight back to the router, which falls back at once, instead of waiting out the
    /// rate limit here. A direct model, or a group with nowhere to go, keeps the retry.
    final class RateLimitFallback: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(available: Bool) { value = available }
        var available: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        @TaskLocal static var current: RateLimitFallback?
    }

    private static func httpErrorMessage(from body: Data, status: Int) -> String {
        let message = errorMessage(from: body)
        let lower = String(decoding: body, as: UTF8.self).lowercased()
        if status == 429, ["insufficient_quota", "enforced_spend_limit", "billing", "monthly", "余额", "额度耗尽"].contains(where: { lower.contains($0) }) {
            return message + " [insufficient_quota]"
        }
        return message
    }

    private static func isSemanticOutput(_ event: AgentStreamEvent) -> Bool {
        switch event {
        case .textDelta(let text), .reasoningDelta(let text): return !text.isEmpty
        case .toolCallDelta, .responsesReasoningEcho: return true
        case .nativeProtocolMetadata: return false
        case .completed: return false
        }
    }

    /// Request attempts for one provider call before its error reaches the run: Codex's default
    /// of four retries, backing off 0.5 s, 1 s, 2 s, 4 s.
    static let maximumRequestAttempts = 5

    static func rejectsStreamUsage(status: Int, message: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        func mentionsParameter(_ value: String) -> Bool {
            let lower = value.lowercased()
            return lower.contains("stream_options") || lower.contains("include_usage")
        }
        func mentionsRejection(_ value: String) -> Bool {
            let lower = value.lowercased()
            return ["unsupported", "not supported", "does not support", "unknown", "unrecognized", "unrecognised",
                    "not allowed", "not permitted", "invalid", "unexpected", "extra inputs", "禁止", "不支持", "未知"].contains { lower.contains($0) }
        }
        if let data = message.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any] {
                let detail = error["message"] as? String ?? ""
                let param = error["param"] as? String ?? ""
                if (mentionsParameter(detail) || mentionsParameter(param)) && mentionsRejection(detail) { return true }
            }
            if let details = root["detail"] as? [[String: Any]] {
                for detail in details {
                    let location = (detail["loc"] as? [String] ?? []).joined(separator: ".")
                    let explanation = detail["msg"] as? String ?? ""
                    if (mentionsParameter(location) || mentionsParameter(explanation)) && mentionsRejection(explanation) { return true }
                }
            }
            let topLevel = root["message"] as? String ?? ""
            return mentionsParameter(topLevel) && mentionsRejection(topLevel)
        }
        return mentionsParameter(message) && mentionsRejection(message)
    }

    private static let permanentURLErrors: Set<URLError.Code> = [
        .cancelled, .badURL, .unsupportedURL, .userCancelledAuthentication, .userAuthenticationRequired,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .fileDoesNotExist, .fileIsDirectory, .noPermissionsToReadFile,
    ]

    private static func isTransient(_ error: Error, response: HTTPURLResponse? = nil) -> Bool {
        // Like Codex and the Anthropic SDK, any failure to reach the server is retried (a TLS
        // handshake cut by a proxy, a DNS hiccup, a dropped connection); only errors a second
        // try cannot change are not: a bad URL, a rejected or untrusted certificate.
        if let url = error as? URLError {
            return !Self.permanentURLErrors.contains(url.code)
        }
        if case .streamError? = error as? ProviderClientError {
            if case .providerInvocation(_, true, _) = ModelRoutingClassifier.classify(error) { return true }
            return false
        }
        guard case .http(let status, let message) = error as? ProviderClientError else { return false }
        if status == 400 {
            if let response, response.value(forHTTPHeaderField: "Retry-After") != nil {
                return rateLimitDelay(http: response, attempt: 0) != nil
            }
            return ProviderHTTPRetrySignal.delayFromMessage(message) != nil
        }
        if status == 429 {
            let lower = message.lowercased()
            return !["insufficient_quota", "enforced_spend_limit", "billing", "monthly", "余额", "额度耗尽"].contains { lower.contains($0) }
        }
        return status == 408 || (500...599).contains(status)
    }

    private static func diagnosticsReporter(_ callback: (@Sendable (ProviderStreamDiagnostics) -> Void)?,
        provider: ProviderConfiguration, modelID: String, options: ChatInferenceOptions, request: URLRequest
    ) -> (@Sendable (ProviderStreamDiagnostics) -> Void)? {
        guard let callback else { return nil }
        let model = options.model ?? provider.models.first(where: { $0.id == modelID })
        let resolution = try? ProviderThinkingResolution.resolve(requested: options.thinkingLevel, model: model,
            provider: provider, maxTokens: options.resolvedMaxOutputTokens(for: model))
        var control: [String: Any] = [:]
        if let body = request.httpBody, let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["reasoning", "reasoning_effort", "thinking", "enable_thinking", "thinking_budget", "output_config"] {
                if let value = payload[key] { control[key] = value }
            }
            if let config = payload["generationConfig"] as? [String: Any], let thinking = config["thinkingConfig"] {
                control["thinkingConfig"] = thinking
            }
        }
        let controlData = (try? JSONSerialization.data(withJSONObject: control, options: [.sortedKeys])) ?? Data("{}".utf8)
        var metadata = ["providerID": provider.id.uuidString, "model": modelID,
            "protocol": provider.protocolAdapter.rawValue, "authRoute": provider.authenticationSelection.acquisitionMethod.rawValue,
            "thinkingRequested": options.thinkingLevel.rawValue,
            "thinkingEffective": resolution?.effective.rawValue ?? options.thinkingLevel.rawValue,
            "thinkingControl": String(decoding: controlData, as: UTF8.self),
            "thinkingSource": model?.baseMetadataSource?.rawValue ?? "Unknown",
            "thinkingOffBehavior": ProviderThinkingResolution.offLabel(model: model, provider: provider)]
        if let reason = resolution?.reason { metadata["thinkingClampReason"] = reason }
        if let unknown = resolution?.unsupportedRawTiers, !unknown.isEmpty { metadata["thinkingUnsupportedRaw"] = unknown.joined(separator: ",") }
        let immutableMetadata = metadata
        return { diagnostics in
            var diagnostics = diagnostics
            diagnostics.thinkingMetadata = immutableMetadata
            diagnostics.usage = diagnostics.usage?.withContextInput(for: provider.apiFormat)
            callback(diagnostics)
        }
    }

    private static func retryReason(_ error: Error) -> String {
        if let url = error as? URLError { return "urlError:\(url.code.rawValue)" }
        if case .http(let status, _) = error as? ProviderClientError { return "http:\(status)" }
        return String(describing: type(of: error))
    }

    static func rateLimitDelay(http: HTTPURLResponse, attempt: Int, now: Date = Date()) -> Double? {
        if let value = http.value(forHTTPHeaderField: "Retry-After") {
            let seconds: Double?
            if let number = Double(value) {
                seconds = number
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                seconds = formatter.date(from: value).map { $0.timeIntervalSince(now) }
            }
            guard let seconds, seconds.isFinite, seconds <= 120 else { return nil }
            return max(1, seconds)
        }
        return min(120, 60 * pow(2, Double(attempt)))
    }

    private func readLimitedBody(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        data.reserveCapacity(4_096)
        for try await byte in bytes {
            if data.count >= 16_384 { break }
            data.append(byte)
        }
        return data
    }

    private static func reasoningDelta(from root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }

        if let delta = first["delta"] as? [String: Any] {
            if let reasoning = delta["reasoning_content"] as? String { return reasoning }
            if let reasoning = delta["reasoning"] as? String { return reasoning }
            if let reasoning = delta["reasoning_text"] as? String { return reasoning }
            if let parts = delta["reasoning_content"] as? [[String: Any]] {
                return parts.compactMap { part in
                    (part["text"] as? String) ?? ((part["text"] as? [String: Any])?["value"] as? String)
                }.joined()
            }
        }
        return nil
    }

    private static func textDelta(from root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }

        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String { return content }
            if let parts = delta["content"] as? [[String: Any]] {
                return parts.compactMap { part in
                    (part["text"] as? String) ?? ((part["text"] as? [String: Any])?["value"] as? String)
                }.joined()
            }
        }
        return first["text"] as? String
    }

    private static func isFinished(_ root: [String: Any]) -> Bool {
        OpenAIStreamParser.isFinished(root)
    }

    private static func toolCallDeltas(from root: [String: Any]) -> [AgentStreamEvent] {
        guard let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { call in
            guard let index = call["index"] as? Int else { return nil }
            let function = call["function"] as? [String: Any]
            return .toolCallDelta(
                index: index,
                id: call["id"] as? String,
                name: function?["name"] as? String,
                arguments: function?["arguments"] as? String ?? ""
            )
        }
    }

    private static func providerErrorMessage(from root: [String: Any]) -> String? {
        guard let error = root["error"] as? [String: Any] else { return nil }
        let message = error["message"] as? String
        if error["code"] as? String == "model_not_found" { return "[model_not_found] " + (message ?? "Model not found") }
        return message
    }

    private static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providerMessage = providerErrorMessage(from: root) {
            return String(providerMessage.prefix(1_000))
        }
        let text = String(data: data.prefix(1_000), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


/// All chat and research clients sharing a provider observe the same cooldown.
/// Wakeups reserve staggered slots so a child fan-out does not cause another burst.
/// The URLSession metrics of one request attempt, so a transport failure (a timeout, a lost
/// connection) can say where the time went: a new or reused connection, when the request was
/// sent, whether a response started.
final class TransportMetricsRecorder: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?
    private let restrictOAuthResource: Bool
    private let restrictToOriginalOrigin: Bool

    init(restrictOAuthResource: Bool = false, restrictToOriginalOrigin: Bool = false) {
        self.restrictOAuthResource = restrictOAuthResource
        self.restrictToOriginalOrigin = restrictToOriginalOrigin
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if restrictOAuthResource && request.url.map(ProviderProductPolicy.allowsOAuthResource) != true {
            completionHandler(nil)
        } else if restrictToOriginalOrigin && !Self.sameOrigin(task.originalRequest?.url, request.url) {
            completionHandler(nil)
        } else { completionHandler(request) }
    }

    static func sameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second, let a = URLComponents(url: first, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: second, resolvingAgainstBaseURL: false),
              let scheme = a.scheme?.lowercased(), let host = a.host?.lowercased(),
              scheme == b.scheme?.lowercased(), host == b.host?.lowercased() else { return false }
        func port(_ c: URLComponents) -> Int? { c.port ?? (c.scheme?.lowercased() == "https" ? 443 : c.scheme?.lowercased() == "http" ? 80 : nil) }
        return port(a) == port(b)
    }

    var value: URLSessionTaskMetrics? { lock.withLock { metrics } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { self.metrics = metrics }
    }

    static func summary(_ error: URLError, _ metrics: URLSessionTaskMetrics?) -> String {
        var parts = ["URLError \(error.code.rawValue)"]
        guard let transaction = metrics?.transactionMetrics.last, let start = transaction.fetchStartDate else {
            return parts.joined(separator: ", ")
        }
        func at(_ date: Date?) -> String { date.map { String(format: "%.1fs", $0.timeIntervalSince(start)) } ?? "never" }
        parts.append(transaction.networkProtocolName ?? "protocol unknown")
        parts.append(transaction.isReusedConnection ? "reused connection" : "new connection (connected \(at(transaction.connectEndDate)))")
        parts.append("sent \(at(transaction.requestEndDate))")
        parts.append("response \(at(transaction.responseStartDate))")
        return parts.joined(separator: ", ")
    }
}

actor ProviderRequestCooldown {
    static let shared = ProviderRequestCooldown()
    private(set) var deadlines: [String: Date] = [:]

    func deferRequests(scope: String, seconds: Double) {
        deadlines[scope] = max(deadlines[scope] ?? .distantPast, Date().addingTimeInterval(seconds))
    }

    func wait(scope: String) async throws {
        while let deadline = deadlines[scope] {
            try Task.checkCancellation()
            let seconds = deadline.timeIntervalSinceNow
            if seconds > 0 {
                try await Task.sleep(for: .seconds(seconds))
                continue
            }
            deadlines[scope] = Date().addingTimeInterval(1 + Double.random(in: 0...0.25))
            return
        }
        try Task.checkCancellation()
    }
}
