import Foundation

public struct OpenAIImageGenerationResponse: Sendable {
    public let imageData: Data
    public let mimeType: String?
    public let revisedPrompt: String?

    public init(imageData: Data, mimeType: String? = nil, revisedPrompt: String? = nil) {
        self.imageData = imageData
        self.mimeType = mimeType
        self.revisedPrompt = revisedPrompt
    }
}

public struct RuntimeImageGenerationResult: Sendable {
    public let attachments: [ChatAttachment]
    public let artifactDescriptor: ArtifactDescriptor?
    public let providerName: String
    public let modelName: String
    public let revisedPrompt: String?

    public init(
        attachments: [ChatAttachment],
        artifactDescriptor: ArtifactDescriptor? = nil,
        providerName: String,
        modelName: String,
        revisedPrompt: String? = nil
    ) {
        self.attachments = attachments
        self.artifactDescriptor = artifactDescriptor
        self.providerName = providerName
        self.modelName = modelName
        self.revisedPrompt = revisedPrompt
    }
}
