import Foundation

protocol ProviderClient: Sendable {
    func fetchModelDiscovery(provider: ProviderConfiguration, apiKey: String?) async throws -> ModelDiscoveryResult
    func streamChat(
        provider: ProviderConfiguration,
        apiKey: String?,
        modelID: String,
        messages: [ChatRequestMessage],
        tools: [ChatToolDefinition],
        options: ChatInferenceOptions,
        attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)?,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))?,
        cancellationHandle: ProviderStreamCancellationHandle?,
        onDiagnostics: (@Sendable (ProviderStreamDiagnostics) -> Void)?,
        onRequestToolNames: (@Sendable ([String]) async -> Void)?,
        onAttemptStarted: (@Sendable (Int) async -> Void)?,
        onRetry: (@Sendable (Int, String) async -> Void)?,
        onTransportFailure: (@Sendable (String) async -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

extension ProviderClient {
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
        streamChat(provider: provider, apiKey: apiKey, modelID: modelID, messages: messages, tools: tools, options: options, attachmentResolver: attachmentResolver, artifactResolver: artifactResolver, cancellationHandle: cancellationHandle, onDiagnostics: onDiagnostics, onRequestToolNames: onRequestToolNames, onAttemptStarted: onAttemptStarted, onRetry: onRetry, onTransportFailure: onTransportFailure)
    }
}
