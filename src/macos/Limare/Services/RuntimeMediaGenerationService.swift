import Foundation

public struct RuntimeMediaGenerationResult: Sendable {
    public let artifactDescriptor: ArtifactDescriptor
    public let fileURL: URL
    public let providerName: String
    public let modelName: String
    public let mimeType: String
    public let text: String?

    public init(
        artifactDescriptor: ArtifactDescriptor,
        fileURL: URL,
        providerName: String,
        modelName: String,
        mimeType: String,
        text: String? = nil
    ) {
        self.artifactDescriptor = artifactDescriptor
        self.fileURL = fileURL
        self.providerName = providerName
        self.modelName = modelName
        self.mimeType = mimeType
        self.text = text
    }
}

@MainActor
final class RuntimeMediaGenerationService {
    private let registry: RuntimeModelRegistry
    private let providers: ProviderStore
    private let artifactStore: ArtifactStore?
    private let client: GeminiMediaGenerationClient
    private let logs: DebugLogStore

    init(
        registry: RuntimeModelRegistry,
        providers: ProviderStore,
        artifactStore: ArtifactStore?,
        client: GeminiMediaGenerationClient = GeminiMediaGenerationClient(),
        logs: DebugLogStore
    ) {
        self.registry = registry
        self.providers = providers
        self.artifactStore = artifactStore
        self.client = client
        self.logs = logs
    }

    func generateVideo(
        entryID: String,
        prompt: String,
        aspectRatio: String? = nil,
        durationSeconds: Int? = nil,
        conversationID: UUID?
    ) async throws -> RuntimeMediaGenerationResult {
        let (entry, apiKey, store, convID) = try prepareExecution(
            entryID: entryID,
            prompt: prompt,
            conversationID: conversationID,
            capabilityCheck: RuntimeModelRegistry.isVideoGeneratable
        )
        logs.info("MediaGen", "Generating video with \(entry.provider.name) / \(entry.model.displayName) (prompt: \(prompt.count) chars).")

        let response = try await client.generateVideo(
            provider: entry.provider,
            apiKey: apiKey,
            modelID: entry.model.id,
            prompt: prompt,
            aspectRatio: aspectRatio,
            durationSeconds: durationSeconds
        )
        try Task.checkCancellation()

        let ext = response.mimeType.lowercased().contains("webm") ? "webm" : "mp4"
        let filename = "GeneratedVideo_\(UUID().uuidString.prefix(8)).\(ext)"
        let descriptor = try store.save(
            data: response.data,
            conversationID: convID,
            filename: filename,
            mimeType: response.mimeType,
            producerProvenance: .generatedVideo,
            retentionClass: .conversationRetained
        )
        let fileURL = try store.resolveFileURL(artifactID: descriptor.artifactID, conversationID: convID)
        logs.info("MediaGen", "Saved generated video '\(descriptor.filename)' (\(descriptor.byteCount) bytes, \(descriptor.mimeType)) -> \(descriptor.artifactID.uuidString).")

        return RuntimeMediaGenerationResult(
            artifactDescriptor: descriptor,
            fileURL: fileURL,
            providerName: entry.provider.name,
            modelName: entry.model.displayName,
            mimeType: response.mimeType,
            text: response.text
        )
    }

    func generateAudio(
        entryID: String,
        prompt: String,
        voice: String? = nil,
        conversationID: UUID?
    ) async throws -> RuntimeMediaGenerationResult {
        let (entry, apiKey, store, convID) = try prepareExecution(
            entryID: entryID,
            prompt: prompt,
            conversationID: conversationID,
            capabilityCheck: RuntimeModelRegistry.isAudioGeneratable
        )
        logs.info("MediaGen", "Generating audio with \(entry.provider.name) / \(entry.model.displayName) (prompt: \(prompt.count) chars).")

        let response = try await client.generateAudio(
            provider: entry.provider,
            apiKey: apiKey,
            modelID: entry.model.id,
            prompt: prompt,
            voice: voice
        )
        try Task.checkCancellation()

        let lowerMime = response.mimeType.lowercased()
        let ext = lowerMime.contains("wav") ? "wav" : (lowerMime.contains("mp4") || lowerMime.contains("m4a") ? "m4a" : "mp3")
        let filename = "GeneratedAudio_\(UUID().uuidString.prefix(8)).\(ext)"
        let descriptor = try store.save(
            data: response.data,
            conversationID: convID,
            filename: filename,
            mimeType: response.mimeType,
            producerProvenance: .generatedAudio,
            retentionClass: .conversationRetained
        )
        let fileURL = try store.resolveFileURL(artifactID: descriptor.artifactID, conversationID: convID)
        logs.info("MediaGen", "Saved generated audio '\(descriptor.filename)' (\(descriptor.byteCount) bytes, \(descriptor.mimeType)) -> \(descriptor.artifactID.uuidString).")

        return RuntimeMediaGenerationResult(
            artifactDescriptor: descriptor,
            fileURL: fileURL,
            providerName: entry.provider.name,
            modelName: entry.model.displayName,
            mimeType: response.mimeType,
            text: response.text
        )
    }

    private func prepareExecution(
        entryID: String,
        prompt: String,
        conversationID: UUID?,
        capabilityCheck: (ProviderModel) -> Bool
    ) throws -> (entry: RuntimeModelEntry, apiKey: String?, store: ArtifactStore, convID: UUID) {
        guard let entry = registry.resolveAllowed(entryID: entryID) else {
            throw RuntimeModelUseError.unavailable
        }
        guard capabilityCheck(entry.model) else {
            throw RuntimeModelUseError.unsupported
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw RuntimeModelUseError.emptyPrompt
        }
        guard prompt.count <= 50_000 else {
            throw RuntimeModelUseError.promptTooLarge
        }

        let apiKey: String?
        if entry.provider.authenticationMode == .none {
            apiKey = nil
        } else {
            do {
                guard entry.provider.authenticationSelection.credentialKind != .oauthAccessToken else {
                    throw ProviderConnectionError.invalidCredentialRoute
                }
                let resolvedKey = try providers.apiKey(providerID: entry.provider.id)
                guard !resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RuntimeModelUseError.missingCredential("API key is empty.")
                }
                apiKey = resolvedKey
            } catch {
                throw RuntimeModelUseError.missingCredential(error.localizedDescription)
            }
        }

        guard let store = artifactStore else {
            throw RuntimeModelUseError.executionFailed("ArtifactStore is unavailable for generated media artifactization.")
        }
        guard let convID = conversationID else {
            throw RuntimeModelUseError.executionFailed("Active conversation scope is required for generated media artifactization.")
        }

        return (entry, apiKey, store, convID)
    }
}
