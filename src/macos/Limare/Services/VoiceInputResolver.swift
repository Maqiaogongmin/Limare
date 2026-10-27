import Foundation

@MainActor
final class VoiceInputResolver {
    private let modelGroups: ModelGroupStore?
    private let providers: ProviderStore
    private let transcriptionClient: OpenAIAudioTranscriptionClient
    private let systemSpeechTranscriber: any SystemSpeechTranscribing
    private let logs: DebugLogStore

    init(
        modelGroups: ModelGroupStore?,
        providers: ProviderStore,
        transcriptionClient: OpenAIAudioTranscriptionClient = OpenAIAudioTranscriptionClient(),
        systemSpeechTranscriber: any SystemSpeechTranscribing = SystemSpeechTranscriber(),
        logs: DebugLogStore
    ) {
        self.modelGroups = modelGroups
        self.providers = providers
        self.transcriptionClient = transcriptionClient
        self.systemSpeechTranscriber = systemSpeechTranscriber
        self.logs = logs
    }

    func transcribe(audioFileURL: URL, duration: Double, sessionSeed: Int = 0) async throws -> VoiceTranscriptionResult {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw VoiceInputError.recordingFailed(String(localized: "Failed to read recorded audio file: \(error.localizedDescription)"))
        }

        // 1. Check Voice Input Group candidates
        var candidates: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        if let modelGroups,
           let groupID = modelGroups.voiceInputGroupId,
           let group = modelGroups.group(for: groupID) {
            candidates = modelGroups.voiceInputCandidates(for: group, providers: providers.providers, sessionSeed: sessionSeed)
        }

        // 2. Try cloud candidates in order
        var candidateErrors: [String] = []
        for candidate in candidates {
            let provider = candidate.provider
            let modelID = candidate.modelID
            let apiKey: String?
            switch provider.authenticationMode {
            case .oauth:
                continue // ChatGPT plan inference does not authorize speech endpoints.
            case .none:
                apiKey = nil
            case .bearer, .azureAPIKey:
                do {
                    apiKey = try providers.apiKey(providerID: provider.id)
                } catch {
                    let errMsg = "\(provider.name)/\(modelID): Credential resolution failed"
                    logs.info("VoiceInput", "\(errMsg). Trying next candidate or fallback...")
                    candidateErrors.append(errMsg)
                    continue
                }
            }

            logs.info("VoiceInput", "Attempting cloud ASR with \(provider.name) / \(modelID)...")
            do {
                let text = try await transcriptionClient.transcribeAudio(
                    provider: provider,
                    apiKey: apiKey,
                    modelID: modelID,
                    audioData: audioData,
                    filename: "voice.wav"
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    let errMsg = "\(provider.name)/\(modelID): Empty transcription returned"
                    logs.info("VoiceInput", "\(errMsg). Trying next candidate or fallback...")
                    candidateErrors.append(errMsg)
                    continue
                }
                logs.info("VoiceInput", "Cloud ASR succeeded with \(provider.name) / \(modelID) (\(trimmed.count) chars, \(String(format: "%.1f", duration))s)")
                return VoiceTranscriptionResult(
                    text: trimmed,
                    providerID: provider.id,
                    modelID: modelID,
                    source: "cloud",
                    durationSeconds: duration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let errMsg = "\(provider.name)/\(modelID): \(error.localizedDescription)"
                logs.info("VoiceInput", "Cloud ASR failed: \(errMsg). Trying next candidate or fallback...")
                candidateErrors.append(errMsg)
            }
        }

        // 3. Fallback to System Speech
        logs.info("VoiceInput", "Falling back to macOS System Speech recognition...")
        do {
            let text = try await systemSpeechTranscriber.transcribe(audioFileURL: audioFileURL)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw VoiceInputError.emptyTranscription
            }
            logs.info("VoiceInput", "System Speech succeeded (\(trimmed.count) chars, \(String(format: "%.1f", duration))s)")
            return VoiceTranscriptionResult(
                text: trimmed,
                providerID: nil,
                modelID: nil,
                source: "system_speech",
                durationSeconds: duration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let sysErr = error.localizedDescription
            logs.error("VoiceInput", "System Speech failed: \(sysErr)")
            if candidateErrors.isEmpty {
                throw error
            } else {
                throw VoiceInputError.transcriptionFailed(String(localized: "All ASR attempts failed. Cloud: [\(candidateErrors.joined(separator: ", "))]; System Speech: \(sysErr)"))
            }
        }
    }
}
