import Foundation

public enum QuickTestKind: String, CaseIterable, Identifiable, Sendable {
    case text
    case vision
    case voiceOutput

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: return String(localized: "Text")
        case .vision: return String(localized: "Vision")
        case .voiceOutput: return String(localized: "Voice Output")
        }
    }

    public var icon: String {
        switch self {
        case .text: return "text.bubble"
        case .vision: return "photo"
        case .voiceOutput: return "waveform"
        }
    }
}

public enum QuickTestStatus: Equatable, Sendable {
    case idle
    case running
    case passed(duration: TimeInterval, output: String)
    case inconclusive(duration: TimeInterval, diagnostic: String)
    case failed(duration: TimeInterval, error: String)
    case cancelled(duration: TimeInterval)

    public var isTerminal: Bool {
        switch self {
        case .idle, .running: return false
        case .passed, .inconclusive, .failed, .cancelled: return true
        }
    }

    public var isSuccess: Bool {
        if case .passed = self { return true }
        return false
    }
}

public struct QuickTestObservation: Sendable, Equatable {
    public var textCharacters: Int
    public var reasoningCharacters: Int
    public var toolCallEvents: Int
    public var reasoningEchoEvents: Int
    public var completedReceived: Bool
    public var streamOpened: Bool
    public var unrecognizedEventCount: Int
    public var isProbe: Bool

    public init(
        textCharacters: Int = 0,
        reasoningCharacters: Int = 0,
        toolCallEvents: Int = 0,
        reasoningEchoEvents: Int = 0,
        completedReceived: Bool = false,
        streamOpened: Bool = false,
        unrecognizedEventCount: Int = 0,
        isProbe: Bool = false
    ) {
        self.textCharacters = textCharacters
        self.reasoningCharacters = reasoningCharacters
        self.toolCallEvents = toolCallEvents
        self.reasoningEchoEvents = reasoningEchoEvents
        self.completedReceived = completedReceived
        self.streamOpened = streamOpened
        self.unrecognizedEventCount = unrecognizedEventCount
        self.isProbe = isProbe
    }
}

public struct QuickTestResult: Sendable, Equatable {
    public let kind: QuickTestKind
    public let status: QuickTestStatus
    public let output: String?
    public let errorMessage: String?
    public let diagnosticMessage: String?
    public let observation: QuickTestObservation
    public let duration: TimeInterval
    public let isProbe: Bool

    public init(
        kind: QuickTestKind,
        status: QuickTestStatus,
        output: String? = nil,
        errorMessage: String? = nil,
        diagnosticMessage: String? = nil,
        observation: QuickTestObservation = QuickTestObservation(),
        duration: TimeInterval = 0,
        isProbe: Bool = false
    ) {
        self.kind = kind
        self.status = status
        self.output = output
        self.errorMessage = errorMessage
        self.diagnosticMessage = diagnosticMessage
        self.observation = observation
        self.duration = duration
        self.isProbe = isProbe
    }
}

public enum QuickTestError: LocalizedError, Equatable {
    case unsupported(String)
    case missingCredential(String)
    case emptyResponse
    case timeout(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let msg): return msg
        case .missingCredential(let msg): return String(localized: "Provider credential unavailable: \(msg)")
        case .emptyResponse: return String(localized: "The provider returned an empty response.")
        case .timeout(let seconds): return String(localized: "Request timed out after \(seconds)s.")
        }
    }
}

@MainActor
final class ProviderQuickTestService: ObservableObject {
    final class StreamDiagnosticsHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _diagnostics = ProviderStreamDiagnostics()

        var diagnostics: ProviderStreamDiagnostics {
            lock.lock()
            defer { lock.unlock() }
            return _diagnostics
        }

        func update(_ diag: ProviderStreamDiagnostics) {
            lock.lock()
            defer { lock.unlock() }
            _diagnostics = diag
        }
    }

    typealias StreamFactory = @Sendable (
        ProviderConfiguration,
        String?,
        String,
        [ChatRequestMessage],
        [ChatToolDefinition],
        ChatInferenceOptions,
        (@Sendable (ChatAttachment) throws -> Data)?,
        (@Sendable (ProviderStreamDiagnostics) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    nonisolated static let samplePNGData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    static let textPrompt = "Reply with one short sentence confirming this model is working."
    static let visionPrompt = "Briefly describe the image."

    static let textTimeoutSeconds = 30
    static let visionTimeoutSeconds = 45

    @Published private(set) var results: [QuickTestKind: QuickTestResult] = [:]
    @Published private(set) var isRunning: Bool = false

    private let client: any ProviderClient
    private let geminiTTSClient: GeminiTTSClient
    private let openAISpeechClient: OpenAIAudioSpeechClient
    private let audioValidator: AudioDataValidating
    private let streamFactory: StreamFactory
    private let sleeper: Sleeper
    private var activeTasks: [QuickTestKind: Task<QuickTestResult, Never>] = [:]

    init(
        client: any ProviderClient = OpenAICompatibleClient(),
        geminiTTSClient: GeminiTTSClient = GeminiTTSClient(),
        openAISpeechClient: OpenAIAudioSpeechClient = OpenAIAudioSpeechClient(),
        audioValidator: AudioDataValidating = AVAudioDataValidator(),
        streamFactory: StreamFactory? = nil,
        sleeper: @escaping Sleeper = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.client = client
        self.geminiTTSClient = geminiTTSClient
        self.openAISpeechClient = openAISpeechClient
        self.audioValidator = audioValidator
        self.streamFactory = streamFactory ?? { provider, apiKey, modelID, messages, tools, options, attachmentResolver, onDiagnostics in
            client.streamChat(
                provider: provider,
                apiKey: apiKey,
                modelID: modelID,
                messages: messages,
                tools: tools,
                options: options,
                attachmentResolver: attachmentResolver,
                onDiagnostics: onDiagnostics
            )
        }
        self.sleeper = sleeper
    }

    static func applicableKinds(for model: ProviderModel, in provider: ProviderConfiguration? = nil) -> [QuickTestKind] {
        var kinds: [QuickTestKind] = []

        let effective = model.modality ?? model.baseModality
        if let modality = effective {
            if modality.contains(.textInput) && modality.contains(.textOutput) {
                kinds.append(.text)
            }
            if modality.contains(.imageInput) {
                kinds.append(.vision)
            }
        } else {
            // Modality unknown: test text and probe vision
            kinds.append(.text)
            kinds.append(.vision)
        }

        if let provider {
            let isTTS = isDedicatedTTS(model) && provider.authenticationMode != .oauth
            if isTTS {
                let route = VoiceOutputRouting.route(provider: provider, modelID: model.id)
                if case .protocolUnsupported = route {
                    // Protocol unsupported -> do not display voice test entry
                } else {
                    kinds.append(.voiceOutput)
                }
            }
        }

        return kinds
    }

    static func isProbe(for kind: QuickTestKind, in model: ProviderModel) -> Bool {
        switch kind {
        case .text:
            return (model.modality ?? model.baseModality) == nil
        case .vision:
            guard (model.modality ?? model.baseModality) != nil else {
                return true
            }
            if model.capabilityProvenance.modality == .inferred {
                return true
            }
            return false
        case .voiceOutput:
            return false
        }
    }

    static func evaluateResult(
        output: String,
        observation: QuickTestObservation,
        duration: TimeInterval,
        kind: QuickTestKind,
        isProbe: Bool = false
    ) -> QuickTestResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            // Case A: Model returned usable text
            return QuickTestResult(
                kind: kind,
                status: .passed(duration: duration, output: trimmed),
                output: trimmed,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        } else if observation.reasoningCharacters > 0 {
            // Case B: No text, but reasoning observed
            let diag = String(localized: "Response received, but no displayable text was produced. Observed reasoning content (\(observation.reasoningCharacters) chars).")
            return QuickTestResult(
                kind: kind,
                status: .inconclusive(duration: duration, diagnostic: diag),
                diagnosticMessage: diag,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        } else if observation.toolCallEvents > 0 {
            // Case C: Tool call observed instead of text
            let diag = String(localized: "Provider responded with a tool call (\(observation.toolCallEvents) events) instead of text.")
            return QuickTestResult(
                kind: kind,
                status: .inconclusive(duration: duration, diagnostic: diag),
                diagnosticMessage: diag,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        } else if observation.streamOpened && observation.unrecognizedEventCount > 0 {
            // Case E: Stream opened, but unrecognized payloads
            let diag = String(localized: "Provider responded, but Limare could not fully interpret the stream (\(observation.unrecognizedEventCount) unrecognized event(s)).")
            return QuickTestResult(
                kind: kind,
                status: .inconclusive(duration: duration, diagnostic: diag),
                diagnosticMessage: diag,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        } else if observation.completedReceived && observation.unrecognizedEventCount == 0 {
            // Case D: Completed successfully but returned no content
            let diag = String(localized: "Provider completed successfully but returned no content.")
            return QuickTestResult(
                kind: kind,
                status: .inconclusive(duration: duration, diagnostic: diag),
                diagnosticMessage: diag,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        } else {
            let diag = String(localized: "The provider completed without returning usable content.")
            return QuickTestResult(
                kind: kind,
                status: .inconclusive(duration: duration, diagnostic: diag),
                diagnosticMessage: diag,
                observation: observation,
                duration: duration,
                isProbe: isProbe
            )
        }
    }

    func result(for kind: QuickTestKind) -> QuickTestResult? {
        results[kind]
    }

    func cancel() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()

        for (kind, current) in results {
            if !current.status.isTerminal {
                let dur = current.duration
                results[kind] = QuickTestResult(
                    kind: kind,
                    status: .cancelled(duration: dur),
                    errorMessage: String(localized: "Test was cancelled."),
                    observation: current.observation,
                    duration: dur,
                    isProbe: current.isProbe
                )
            }
        }
        isRunning = false
    }

    func runAll(
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String?
    ) async {
        cancel()
        let kinds = Self.applicableKinds(for: model, in: provider)
        for kind in kinds {
            let isProbe = Self.isProbe(for: kind, in: model)
            results[kind] = QuickTestResult(
                kind: kind,
                status: .running,
                observation: QuickTestObservation(isProbe: isProbe),
                isProbe: isProbe
            )
        }
        isRunning = !kinds.isEmpty

        await withTaskGroup(of: QuickTestResult.self) { group in
            for kind in kinds {
                let task = Task { @MainActor in
                    await self.executeTest(kind: kind, provider: provider, model: model, apiKey: apiKey)
                }
                activeTasks[kind] = task
                group.addTask {
                    let res = await task.value
                    return res
                }
            }
            for await res in group {
                self.results[res.kind] = res
                self.activeTasks.removeValue(forKey: res.kind)
            }
        }
        isRunning = false
    }

    func runSingleTest(
        kind: QuickTestKind,
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String?
    ) async -> QuickTestResult {
        activeTasks[kind]?.cancel()
        let isProbe = Self.isProbe(for: kind, in: model)
        results[kind] = QuickTestResult(
            kind: kind,
            status: .running,
            observation: QuickTestObservation(isProbe: isProbe),
            isProbe: isProbe
        )
        isRunning = true
        let task = Task { @MainActor in
            await self.executeTest(kind: kind, provider: provider, model: model, apiKey: apiKey)
        }
        activeTasks[kind] = task
        let res = await task.value
        activeTasks.removeValue(forKey: kind)
        results[kind] = res
        isRunning = results.values.contains { $0.status == .running }
        return res
    }

    private func executeTest(
        kind: QuickTestKind,
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String?
    ) async -> QuickTestResult {
        let startTime = ContinuousClock.now
        let isProbe = Self.isProbe(for: kind, in: model)

        // 1. Guard against unsupported test kind for this model (Zero Network Call)
        let applicable = Self.applicableKinds(for: model, in: provider)
        guard applicable.contains(kind) else {
            let err = QuickTestError.unsupported(String(localized: "The model '\(model.displayName)' does not support \(kind.displayName) testing.")).localizedDescription
            return QuickTestResult(
                kind: kind,
                status: .failed(duration: 0, error: err),
                errorMessage: err,
                observation: QuickTestObservation(isProbe: isProbe),
                duration: 0,
                isProbe: isProbe
            )
        }

        // 2. Guard against missing credential (Zero Network Call)
        let effectiveKey: String? = {
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
            return nil
        }()

        if provider.authenticationMode != .none && effectiveKey == nil {
            let err = String(localized: "API key is required for \(provider.authenticationMode.displayName).")
            return QuickTestResult(
                kind: kind,
                status: .failed(duration: 0, error: err),
                errorMessage: err,
                observation: QuickTestObservation(isProbe: isProbe),
                duration: 0,
                isProbe: isProbe
            )
        }

        if kind == .voiceOutput {
            return await executeVoiceOutputTest(
                provider: provider,
                model: model,
                apiKey: effectiveKey,
                startTime: startTime
            )
        }

        let timeoutSeconds = (kind == .vision) ? Self.visionTimeoutSeconds : Self.textTimeoutSeconds

        do {
            let (output, observation) = try await runStreamRequest(
                kind: kind,
                provider: provider,
                model: model,
                apiKey: effectiveKey,
                isProbe: isProbe,
                timeoutSeconds: timeoutSeconds
            )

            let dur = Self.seconds(since: startTime)
            return Self.evaluateResult(
                output: output,
                observation: observation,
                duration: dur,
                kind: kind,
                isProbe: isProbe
            )
        } catch is CancellationError {
            let dur = Self.seconds(since: startTime)
            return QuickTestResult(
                kind: kind,
                status: .cancelled(duration: dur),
                errorMessage: String(localized: "Test was cancelled."),
                observation: QuickTestObservation(isProbe: isProbe),
                duration: dur,
                isProbe: isProbe
            )
        } catch let urlError as URLError where urlError.code == .cancelled {
            let dur = Self.seconds(since: startTime)
            return QuickTestResult(
                kind: kind,
                status: .cancelled(duration: dur),
                errorMessage: String(localized: "Test was cancelled."),
                observation: QuickTestObservation(isProbe: isProbe),
                duration: dur,
                isProbe: isProbe
            )
        } catch {
            let dur = Self.seconds(since: startTime)
            let rawMsg = error.localizedDescription
            var secretsToMask: [String] = []
            if let key = effectiveKey, !key.isEmpty {
                secretsToMask.append(key)
            }
            for headerVal in provider.extraHeaders.values {
                let trimmed = headerVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    secretsToMask.append(trimmed)
                }
            }
            let masked = SecretMasker.redact(rawMsg, secrets: secretsToMask)
            return QuickTestResult(
                kind: kind,
                status: .failed(duration: dur, error: masked),
                errorMessage: masked,
                observation: QuickTestObservation(isProbe: isProbe),
                duration: dur,
                isProbe: isProbe
            )
        }
    }

    private func executeVoiceOutputTest(
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String?,
        startTime: ContinuousClock.Instant
    ) async -> QuickTestResult {
        if provider.authenticationMode == .oauth {
            let dur = Self.seconds(since: startTime)
            let reason = String(localized: "OAuth does not authorize speech synthesis (API Key required)")
            return QuickTestResult(
                kind: .voiceOutput,
                status: .failed(duration: dur, error: reason),
                errorMessage: reason,
                duration: dur
            )
        }

        let route = VoiceOutputRouting.route(provider: provider, modelID: model.id)
        switch route {
        case .protocolUnsupported(let reason):
            let dur = Self.seconds(since: startTime)
            return QuickTestResult(
                kind: .voiceOutput,
                status: .failed(duration: dur, error: reason),
                errorMessage: reason,
                duration: dur
            )
        case .geminiNativeInteractions, .openAIAudioSpeech:
            break
        }

        let testPrompt = "Hello, this is a quick speech synthesis test."
        do {
            let audioData: Data
            switch route {
            case .geminiNativeInteractions:
                audioData = try await geminiTTSClient.synthesizeSpeech(
                    provider: provider,
                    apiKey: apiKey,
                    modelID: model.id,
                    text: testPrompt,
                    voice: GeminiTTSClient.defaultVoice
                )
            case .openAIAudioSpeech:
                audioData = try await openAISpeechClient.synthesizeSpeech(
                    provider: provider,
                    apiKey: apiKey,
                    modelID: model.id,
                    text: testPrompt
                )
            case .protocolUnsupported:
                throw VoiceOutputError.synthesisFailed(String(localized: "Protocol unsupported"))
            }

            guard !audioData.isEmpty else {
                throw VoiceOutputError.synthesisFailed(String(localized: "Empty audio response"))
            }

            try audioValidator.validate(audioData)

            let dur = Self.seconds(since: startTime)
            let out = String(localized: "Speech synthesis succeeded (\(audioData.count) bytes).")
            return QuickTestResult(
                kind: .voiceOutput,
                status: .passed(duration: dur, output: out),
                output: out,
                observation: QuickTestObservation(completedReceived: true),
                duration: dur
            )
        } catch is CancellationError {
            let dur = Self.seconds(since: startTime)
            return QuickTestResult(kind: .voiceOutput, status: .cancelled(duration: dur), duration: dur)
        } catch let urlError as URLError where urlError.code == .cancelled {
            let dur = Self.seconds(since: startTime)
            return QuickTestResult(kind: .voiceOutput, status: .cancelled(duration: dur), duration: dur)
        } catch {
            let dur = Self.seconds(since: startTime)
            let secrets = [apiKey].compactMap { $0 } + Array(provider.extraHeaders.values)
            let safeMsg = SecretMasker.redact(error.localizedDescription, secrets: secrets)
            return QuickTestResult(
                kind: .voiceOutput,
                status: .failed(duration: dur, error: safeMsg),
                errorMessage: safeMsg,
                duration: dur
            )
        }
    }

    private func runStreamRequest(
        kind: QuickTestKind,
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String?,
        isProbe: Bool,
        timeoutSeconds: Int
    ) async throws -> (output: String, observation: QuickTestObservation) {
        let messages: [ChatRequestMessage]
        let attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)?

        switch kind {
        case .text:
            messages = [ChatRequestMessage(role: "user", content: Self.textPrompt)]
            attachmentResolver = nil
        case .vision:
            let att = ChatAttachment(
                kind: .image,
                filename: "quicktest.png",
                relativePath: "quicktest.png",
                mimeType: "image/png",
                byteCount: Self.samplePNGData.count,
                width: 1,
                height: 1
            )
            messages = [
                ChatRequestMessage(
                    role: "user",
                    content: .parts([
                        .imageAttachment(att),
                        .text(Self.visionPrompt)
                    ])
                )
            ]
            attachmentResolver = { _ in Self.samplePNGData }
        case .voiceOutput:
            throw QuickTestError.unsupported(String(localized: "Voice output does not support stream chat."))
        }

        let options = ChatInferenceOptions(
            thinkingLevel: .off,
            maxOutputTokens: 128,
            model: model
        )

        let sleeper = self.sleeper
        let factory = self.streamFactory

        return try await withThrowingTaskGroup(of: (String, QuickTestObservation).self) { group in
            group.addTask {
                var collectedText = ""
                let diagHolder = StreamDiagnosticsHolder()
                let onDiagnostics: @Sendable (ProviderStreamDiagnostics) -> Void = { diag in
                    diagHolder.update(diag)
                }

                for try await event in factory(provider, apiKey, model.id, messages, [], options, attachmentResolver, onDiagnostics) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let delta):
                        collectedText += delta
                    case .reasoningDelta, .toolCallDelta, .responsesReasoningEcho, .nativeProtocolMetadata, .completed:
                        break
                    }
                }

                let d = diagHolder.diagnostics
                let obs = QuickTestObservation(
                    textCharacters: d.textCharacters > 0 ? d.textCharacters : collectedText.count,
                    reasoningCharacters: d.reasoningCharacters,
                    toolCallEvents: d.toolCallEvents,
                    reasoningEchoEvents: d.reasoningEchoEvents,
                    completedReceived: d.completedReceived,
                    streamOpened: d.streamOpened || !collectedText.isEmpty,
                    unrecognizedEventCount: d.unrecognizedEventCount,
                    isProbe: isProbe
                )
                return (collectedText, obs)
            }

            group.addTask {
                try await sleeper(UInt64(timeoutSeconds) * 1_000_000_000)
                throw QuickTestError.timeout(timeoutSeconds)
            }

            do {
                guard let firstResult = try await group.next() else {
                    throw QuickTestError.emptyResponse
                }
                group.cancelAll()
                return firstResult
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
