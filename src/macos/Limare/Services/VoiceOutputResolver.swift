import Foundation

@MainActor
final class VoiceOutputResolver {
    private let modelGroups: ModelGroupStore?
    private let providers: ProviderStore
    private let speechClient: OpenAIAudioSpeechClient
    private let geminiClient: GeminiTTSClient
    private let audioValidator: AudioDataValidating
    private let logs: DebugLogStore

    init(
        modelGroups: ModelGroupStore?,
        providers: ProviderStore,
        speechClient: OpenAIAudioSpeechClient = OpenAIAudioSpeechClient(),
        geminiClient: GeminiTTSClient = GeminiTTSClient(),
        audioValidator: AudioDataValidating = AVAudioDataValidator(),
        logs: DebugLogStore
    ) {
        self.modelGroups = modelGroups
        self.providers = providers
        self.speechClient = speechClient
        self.geminiClient = geminiClient
        self.audioValidator = audioValidator
        self.logs = logs
    }

    func prepare(text: String, sessionSeed: Int = 0) async throws -> PreparedVoiceOutput {
        let sanitized = VoiceTextSanitizer.sanitize(text)
        guard !sanitized.isEmpty else {
            throw VoiceOutputError.noSpeakableText
        }

        // 1. Resolve Voice Output Group candidates
        var candidates: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        var candidateErrors: [String] = []

        if let modelGroups,
           let groupID = modelGroups.voiceOutputGroupId,
           let group = modelGroups.group(for: groupID) {
            candidates = modelGroups.voiceOutputCandidates(for: group, providers: providers.providers, sessionSeed: sessionSeed)
            if candidates.isEmpty && !group.memberEntryIds.isEmpty {
                for entryId in group.memberEntryIds {
                    let taskEval = ModelGroupStore.evaluateMemberTaskEligibility(
                        entryId: entryId,
                        task: .voiceOutputTTS,
                        providers: providers.providers
                    )
                    let pName = taskEval.provider?.name ?? "Provider"
                    let mId = taskEval.model?.id ?? (ModelGroup.parseEntryId(entryId)?.modelID ?? "Model")
                    let reason = taskEval.readiness.diagnosticReason
                    candidateErrors.append("\(pName)/\(mId): \(reason)")
                }
            }
        }

        // 2. Try cloud candidates in order
        for candidate in candidates {
            try Task.checkCancellation()
            let provider = candidate.provider
            let modelID = candidate.modelID
            let apiKey: String?

            let route = VoiceOutputRouting.route(provider: provider, modelID: modelID)
            switch route {
            case .protocolUnsupported(let reason):
                let errMsg = "\(provider.name)/\(modelID): \(reason)"
                logs.info("VoiceOutput", "\(errMsg). Trying next candidate or fallback...")
                candidateErrors.append(errMsg)
                continue
            case .geminiNativeInteractions, .openAIAudioSpeech:
                break
            }

            switch provider.authenticationMode {
            case .oauth:
                let errMsg = "\(provider.name)/\(modelID): OAuth does not authorize speech synthesis (API Key required)"
                logs.info("VoiceOutput", "\(errMsg). Trying next candidate or fallback...")
                candidateErrors.append(errMsg)
                continue
            case .none:
                apiKey = nil
            case .bearer, .azureAPIKey:
                do {
                    apiKey = try providers.apiKey(providerID: provider.id)
                } catch {
                    let errMsg = "\(provider.name)/\(modelID): Credential resolution failed"
                    logs.info("VoiceOutput", "\(errMsg). Trying next candidate or fallback...")
                    candidateErrors.append(errMsg)
                    continue
                }
            }

            let (maxChars, maxBytes): (Int, Int?) = {
                switch route {
                case .geminiNativeInteractions:
                    return (GeminiTTSClient.maxChunkCharacters, GeminiTTSClient.maxChunkBytes)
                case .openAIAudioSpeech, .protocolUnsupported:
                    return (VoiceOutputDefaults.maxChunkCharacters, nil)
                }
            }()
            let chunks = VoiceTextChunker.chunk(sanitized, maxCharacters: maxChars, maxBytes: maxBytes)
            guard !chunks.isEmpty else {
                throw VoiceOutputError.noSpeakableText
            }

            logs.info("VoiceOutput", "Attempting cloud TTS with \(provider.name) / \(modelID) (\(sanitized.count) chars, \(chunks.count) chunks)...")

            var candidateSegments: [Data] = []
            var candidateFailed = false

            for (idx, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                do {
                    let data: Data
                    switch route {
                    case .geminiNativeInteractions:
                        data = try await geminiClient.synthesizeSpeech(
                            provider: provider,
                            apiKey: apiKey,
                            modelID: modelID,
                            text: chunk,
                            voice: GeminiTTSClient.defaultVoice
                        )
                    case .openAIAudioSpeech:
                        data = try await speechClient.synthesizeSpeech(
                            provider: provider,
                            apiKey: apiKey,
                            modelID: modelID,
                            text: chunk
                        )
                    case .protocolUnsupported:
                        throw VoiceOutputError.synthesisFailed("Protocol unsupported")
                    }
                    try audioValidator.validate(data)
                    candidateSegments.append(data)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let urlError as URLError where urlError.code == .cancelled {
                    throw CancellationError()
                } catch let nsError as NSError where nsError.domain == "Swift.CancellationError" || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    let errMsg = "\(provider.name)/\(modelID) chunk \(idx + 1)/\(chunks.count): \(error.localizedDescription)"
                    logs.info("VoiceOutput", "Cloud TTS failed: \(errMsg). Trying next candidate or fallback...")
                    candidateErrors.append(errMsg)
                    candidateFailed = true
                    break
                }
            }

            if !candidateFailed && candidateSegments.count == chunks.count {
                let modelDisplayName = provider.models.first(where: { $0.id == modelID })?.displayName ?? modelID
                let totalBytes = candidateSegments.reduce(0) { $0 + $1.count }
                logs.info("VoiceOutput", "Cloud TTS succeeded with \(provider.name) / \(modelID) (\(sanitized.count) chars, \(chunks.count) chunks, \(totalBytes) bytes)")
                return .cloud(
                    segments: candidateSegments,
                    providerID: provider.id,
                    modelID: modelID,
                    label: "\(provider.name) · \(modelDisplayName)"
                )
            }
        }

        // 3. Fallback to System Speech
        let fallbackReason = candidateErrors.isEmpty ? nil : candidateErrors.joined(separator: "; ")
        if let fallbackReason {
            logs.info("VoiceOutput", "Falling back to macOS System Voice due to: \(fallbackReason)")
        } else {
            logs.info("VoiceOutput", "Falling back to macOS System Voice (\(sanitized.count) chars)...")
        }
        return .system(text: sanitized, fallbackReason: fallbackReason)
    }
}
