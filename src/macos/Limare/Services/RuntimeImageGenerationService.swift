import Foundation

@MainActor
final class RuntimeImageGenerationService {
    private let registry: RuntimeModelRegistry
    private let providers: ProviderStore
    private let attachmentStore: AttachmentStore
    private let artifactStore: ArtifactStore?
    private let client: OpenAIImageGenerationClient
    private let logs: DebugLogStore

    init(
        registry: RuntimeModelRegistry,
        providers: ProviderStore,
        attachmentStore: AttachmentStore,
        artifactStore: ArtifactStore? = nil,
        client: OpenAIImageGenerationClient = OpenAIImageGenerationClient(),
        logs: DebugLogStore
    ) {
        self.registry = registry
        self.providers = providers
        self.attachmentStore = attachmentStore
        self.artifactStore = artifactStore
        self.client = client
        self.logs = logs
    }

    func generate(
        entryID: String,
        prompt: String,
        size: String? = nil,
        quality: String? = nil,
        conversationID: UUID? = nil
    ) async throws -> RuntimeImageGenerationResult {
        guard let entry = registry.resolveAllowed(entryID: entryID) else {
            throw RuntimeModelUseError.unavailable
        }
        guard RuntimeModelRegistry.isImageGeneratable(entry.model) else {
            throw RuntimeModelUseError.unsupported
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw RuntimeModelUseError.emptyPrompt
        }
        guard prompt.count <= 50_000 else {
            throw RuntimeModelUseError.promptTooLarge
        }
        if let size = size?.trimmingCharacters(in: .whitespacesAndNewlines), !size.isEmpty {
            guard size.count <= 64, !size.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw ToolExecutorError.invalidArguments("size must be <= 64 characters and contain no newlines.")
            }
        }
        if let quality = quality?.trimmingCharacters(in: .whitespacesAndNewlines), !quality.isEmpty {
            guard quality.count <= 64, !quality.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw ToolExecutorError.invalidArguments("quality must be <= 64 characters and contain no newlines.")
            }
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

        logs.info("ImageGen", "Generating image with \(entry.provider.name) / \(entry.model.displayName) (prompt: \(prompt.count) chars, size: \(size ?? "default"), quality: \(quality ?? "default")).")

        let clientResponse = try await client.generateImage(
            provider: entry.provider,
            apiKey: apiKey,
            modelID: entry.model.id,
            prompt: prompt,
            size: size,
            quality: quality
        )

        try Task.checkCancellation()

        var savedAttachment: ChatAttachment? = nil
        do {
            let attachment = try attachmentStore.saveGeneratedImage(
                data: clientResponse.imageData,
                mimeType: clientResponse.mimeType,
                suggestedFilename: nil
            )
            savedAttachment = attachment

            guard let store = artifactStore else {
                throw RuntimeModelUseError.executionFailed("ArtifactStore is unavailable for generated image artifactization.")
            }
            guard let convID = conversationID else {
                throw RuntimeModelUseError.executionFailed("Active conversation scope is required for generated image artifactization.")
            }

            let mimeType = clientResponse.mimeType ?? "image/png"
            let ext = mimeType.contains("jpeg") || mimeType.contains("jpg") ? "jpg" : "png"
            let filename = "GeneratedImage_\(UUID().uuidString.prefix(8)).\(ext)"

            let artifactDescriptor: ArtifactDescriptor
            do {
                artifactDescriptor = try store.save(
                    data: clientResponse.imageData,
                    conversationID: convID,
                    filename: filename,
                    mimeType: mimeType,
                    producerProvenance: .generatedImage,
                    retentionClass: .conversationRetained
                )
            } catch {
                logs.error("ImageGen", "Failed to save generated image artifact: \(error.localizedDescription)")
                throw RuntimeModelUseError.executionFailed("Failed to save generated image artifact: \(error.localizedDescription)")
            }

            try Task.checkCancellation()

            logs.info("ImageGen", "Saved generated image '\(attachment.filename)' (\(attachment.byteCount) bytes, \(attachment.mimeType)) -> \(artifactDescriptor.artifactID.uuidString).")

            return RuntimeImageGenerationResult(
                attachments: [attachment],
                artifactDescriptor: artifactDescriptor,
                providerName: entry.provider.name,
                modelName: entry.model.displayName,
                revisedPrompt: clientResponse.revisedPrompt
            )
        } catch is CancellationError {
            if let savedAttachment {
                attachmentStore.deleteAttachment(savedAttachment)
            }
            throw CancellationError()
        } catch {
            if let savedAttachment {
                attachmentStore.deleteAttachment(savedAttachment)
            }
            throw error
        }
    }
}
