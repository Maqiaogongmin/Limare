import Foundation

public enum MaxTokenWireField: Sendable {
    case maxTokens
    case maxCompletionTokens
    case omit
}

/// Pure-function builder for OpenAI-compatible Chat Completions HTTP requests and JSON payloads.
enum OpenAIChatRequestBuilder {
    public static func resolveMaxTokenWireField(
        baseURL: String,
        modelID: String = "",
        model: ProviderModel? = nil
    ) -> MaxTokenWireField {
        let base = baseURL.lowercased()
        if base.contains("api.openai.com") {
            return .maxCompletionTokens
        }
        return .maxTokens
    }

    /// Builds the raw JSON dictionary payload for an OpenAI-compatible Chat Completions request.
    static func buildPayload(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        tools: [ChatToolDefinition] = [],
        options: ChatInferenceOptions = ChatInferenceOptions(),
        attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)? = nil,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = nil
    ) throws -> [String: Any] {
        let targetModel = options.model ?? provider.models.first(where: { $0.id == modelID })
        let resolution = try ProviderThinkingResolution.resolve(requested: options.thinkingLevel, model: targetModel, provider: provider, maxTokens: options.resolvedMaxOutputTokens(for: targetModel))

        // Determine unified request max token limit for wire emission and budget calculation
        let requestMaxTokens = options.resolvedMaxOutputTokens(for: targetModel)

        let ctx = thinkingContext(provider: provider, modelID: modelID, model: targetModel,
                                  level: resolution.effective, maxTokens: requestMaxTokens)

        // Resolve active rule for reasoning echo policy
        let builtIn = ThinkingRuleResolver.builtInRules(for: ctx)
        let activeRule = builtIn.first(where: { $0.scope.matches(modelID) })
        let echoTiming = activeRule?.reasoningEcho?.timing

        // Build sanitized messages array
        let encoder = JSONEncoder()
        var messagesJSON: [[String: Any]] = []

        // Tool call identity -> tool name, so a projected tool image can name its cause.
        // Read-only bookkeeping over the already-projected request messages.
        var toolNamesByCallID: [String: String] = [:]
        for msg in messages where msg.role == "assistant" {
            for call in msg.toolCalls ?? [] {
                toolNamesByCallID[call.id] = call.function.name
            }
        }

        let hasReadImageTool = tools.contains(where: { $0.function.name == "read_image" })

        // Group-level media buffer for the synthetic image projection.
        //
        // Mother invariant (Cline `splitToolImagesMiddleware`): media is stripped from every
        // tool-result part, and ONE synthetic multimodal user message is emitted after the
        // complete tool message. Limare canonical shape adaptation: one assistant turn with N
        // tool calls becomes N independent role:"tool" messages, so the same invariant means
        // every role:"tool" message of one assistant tool-call group must be projected
        // contiguously and the single synthetic user message must follow the WHOLE group.
        // Emitting it after each individual tool response would break the
        // assistant(tool_calls) -> all matching role:"tool" protocol sequence.
        var pendingToolMediaParts: [[String: Any]] = []

        for msg in messages {
            // History reconstruction normally prevents this, but make the wire
            // boundary authoritative: an assistant message needs text or one
            // or more tool calls. Sending content: null without tool_calls is
            // rejected by strict OpenAI-compatible gateways.
            guard hasValidAssistantPayload(msg) else { continue }
            var msgDict: [String: Any] = ["role": msg.role]

            // OpenAI Chat Completions does not accept multimodal content inside a
            // role:"tool" message. Canonical tool truth stays a typed
            // ToolResultPart; this projection keeps the tool message text-only and
            // defers image artifact bytes into one synthetic role:"user" multimodal
            // message emitted after the group. That synthetic message is a
            // provider-turn projection only: it is never persisted and never becomes
            // canonical conversation truth.
            if msg.role == "tool" {
                let projection = try projectToolMessage(
                    msg,
                    provider: provider,
                    targetModel: targetModel,
                    options: options,
                    artifactResolver: artifactResolver,
                    hasReadImageTool: hasReadImageTool,
                    toolName: msg.toolCallID.flatMap { toolNamesByCallID[$0] }
                )
                msgDict["content"] = projection.content
                if let toolCallID = msg.toolCallID {
                    msgDict["tool_call_id"] = toolCallID
                }
                messagesJSON.append(msgDict)
                if let adjacentUserMessage = projection.adjacentUserMessage,
                   let mediaParts = adjacentUserMessage["content"] as? [[String: Any]] {
                    pendingToolMediaParts.append(contentsOf: mediaParts)
                }
                continue
            }

            // Any non-tool message closes the current tool-response group: flush the
            // accumulated media projection before projecting this message.
            if !pendingToolMediaParts.isEmpty {
                messagesJSON.append(["role": "user", "content": pendingToolMediaParts])
                pendingToolMediaParts = []
            }

            if let content = msg.content {
                switch content {
                case .text(let text):
                    msgDict["content"] = text
                case .parts(let parts):
                    var partsJSON: [[String: Any]] = []
                    for part in parts {
                        switch part {
                        case .text(let text):
                            partsJSON.append(["type": "text", "text": text])
                        case .imageUrl(let url):
                            partsJSON.append(["type": "image_url", "image_url": ["url": url]])
                        case .imageAttachment(let att):
                            try appendAttachment(att, provider: provider, targetModel: options.model ?? provider.models.first(where: { $0.id == modelID }), resolver: attachmentResolver, hasReadImageTool: hasReadImageTool, options: options, to: &partsJSON)
                        case .attachment(let att):
                            try appendAttachment(att, provider: provider, targetModel: options.model ?? provider.models.first(where: { $0.id == modelID }), resolver: attachmentResolver, hasReadImageTool: hasReadImageTool, options: options, to: &partsJSON)
                        case .artifact(let id, let semanticRole, let mimeType):
                            try appendArtifact(id: id, semanticRole: semanticRole, mimeType: mimeType, provider: provider, targetModel: options.model ?? provider.models.first(where: { $0.id == modelID }), resolver: artifactResolver, hasReadImageTool: hasReadImageTool, options: options, to: &partsJSON)
                        }
                    }
                    msgDict["content"] = partsJSON
                }
            } else {
                msgDict["content"] = NSNull()
            }
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let toolsData = try encoder.encode(toolCalls)
                if let toolsJSON = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]] {
                    msgDict["tool_calls"] = toolsJSON
                }
            }
            if let toolCallID = msg.toolCallID {
                msgDict["tool_call_id"] = toolCallID
            }

            if msg.role == "assistant" {
                let allowEcho: Bool
                if options.model?.supportsReasoning == false || echoTiming == .never {
                    allowEcho = false
                } else if echoTiming == .afterToolUseOnly {
                    allowEcho = (msg.toolCalls != nil && !msg.toolCalls!.isEmpty)
                } else {
                    allowEcho = true
                }

                if allowEcho, let reasoning = msg.reasoningContent {
                    msgDict["reasoning_content"] = reasoning
                }
            }

            messagesJSON.append(msgDict)
        }

        // The final tool-response group is closed by the end of the history.
        if !pendingToolMediaParts.isEmpty {
            messagesJSON.append(["role": "user", "content": pendingToolMediaParts])
            pendingToolMediaParts = []
        }

        var body: [String: Any] = [
            "model": modelID,
            "messages": messagesJSON,
            "stream": true,
        ]

        let field = resolveMaxTokenWireField(baseURL: provider.baseURL, modelID: modelID, model: options.model)
        switch field {
        case .maxCompletionTokens:
            body["max_completion_tokens"] = requestMaxTokens
        case .maxTokens:
            body["max_tokens"] = requestMaxTokens
        case .omit:
            break
        }

        if !tools.isEmpty {
            let toolsData = try encoder.encode(tools)
            if let toolsJSON = try JSONSerialization.jsonObject(with: toolsData) as? [[String: Any]] {
                body["tools"] = toolsJSON
            }
        }

        body.merge(thinkingControl(provider: provider, modelID: modelID, model: targetModel,
                                   level: resolution.effective, maxTokens: requestMaxTokens)) { _, control in control }
        return body
    }

    /// Resolve context with authoritative defaulting to false.
    static func thinkingContext(provider: ProviderConfiguration, modelID: String, model: ProviderModel?,
                                level: ThinkingLevel, maxTokens: Int) -> ThinkingResolveContext {
        let base = provider.baseURL.lowercased()
        return ThinkingResolveContext(
            modelId: modelID,
            supportsReasoning: model?.supportsReasoning,
            declaredEffortValues: model?.reasoningEffortValues,
            declaresNoEffortTiers: model?.declaresNoEffortTiers ?? false,
            effortDeclarationIsAuthoritative: model?.effortDeclarationIsAuthoritative ?? false,
            isXAI: base.contains("api.x.ai"),
            level: level,
            maxTokens: maxTokens,
            isOpenRouter: base.contains("openrouter.ai"),
            usesUnifiedReasoningEffort: base.contains("volces") || base.contains("ark.") || base.contains("api.venice.ai"),
            isMistral: base.contains("mistral.ai"),
            isDashScope: base.contains("dashscope"),
            offEffort: ThinkingRuleResolver.explicitOffEffort(baseURL: provider.baseURL, modelID: modelID, level: level),
            userRules: []
        )
    }

    /// The thinking keys a request sends for one level. Thinking menus admit and dedupe on this same projection.
    static func thinkingControl(provider: ProviderConfiguration, modelID: String, model: ProviderModel?,
                                level: ThinkingLevel, maxTokens: Int) -> [String: Any] {
        var control: [String: Any] = [:]
        if model?.supportsReasoning == true {
            ThinkingRuleResolver.apply(to: &control, ctx: thinkingContext(
                provider: provider, modelID: modelID, model: model, level: level, maxTokens: maxTokens))
        }
        if provider.providerIdentity == .kimiCode, model?.declaresNoEffortTiers != true, level == .off {
            control["thinking"] = ["type": "disabled"]
            control.removeValue(forKey: "reasoning_effort")
        }
        return control
    }

    private static func hasValidAssistantPayload(_ message: ChatRequestMessage) -> Bool {
        guard message.role == "assistant" else { return true }
        if let toolCalls = message.toolCalls, !toolCalls.isEmpty { return true }
        guard let content = message.content else { return false }
        switch content {
        case .text(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .parts(let parts):
            return !parts.isEmpty
        }
    }

    /// Minimal, bounded, byte-free placeholder for a tool result whose only content is
    /// projected image bytes. It deliberately carries no base64 and no invented summary.
    static let toolImagePlaceholder = "Image result available in the following user message."

    struct ToolMessageProjection {
        /// Legal Chat Completions tool-message content: text only (never an image part).
        let content: Any
        /// Present only when image bytes were actually projected for this turn.
        let adjacentUserMessage: [String: Any]?
    }

    /// Projects one canonical tool message into (1) a text-only Chat Completions tool message
    /// and (2) at most one adjacent synthetic user message carrying the image bytes.
    ///
    /// Canonical truth is not changed: the tool message keeps its exact `tool_call_id`, and
    /// the images are read back through Artifact Authority at projection time.
    static func projectToolMessage(
        _ msg: ChatRequestMessage,
        provider: ProviderConfiguration?,
        targetModel: ProviderModel?,
        options: ChatInferenceOptions,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))?,
        hasReadImageTool: Bool,
        toolName: String?
    ) throws -> ToolMessageProjection {
        var textLines: [String] = []
        var imageArtifacts: [(id: UUID, semanticRole: ArtifactSemanticRole, mimeType: String)] = []

        if let content = msg.content {
            switch content {
            case .text(let text):
                if !text.isEmpty { textLines.append(text) }
            case .parts(let parts):
                for part in parts {
                    switch part {
                    case .text(let text):
                        if !text.isEmpty { textLines.append(text) }
                    case .artifact(let id, let semanticRole, let mimeType):
                        if mimeType.hasPrefix("image/") {
                            imageArtifacts.append((id, semanticRole, mimeType))
                        } else {
                            // Only image artifacts change wire shape in this round. Every
                            // other artifact kind keeps its existing bounded text reference.
                            textLines.append(ChatContentPart.artifactReferenceText(id: id, semanticRole: semanticRole, mimeType: mimeType))
                        }
                    case .imageUrl, .imageAttachment, .attachment:
                        // A tool result never carries user-authored attachment parts.
                        break
                    }
                }
            }
        }

        let projection = executableVisualProjection(
            provider: provider,
            targetModel: targetModel,
            options: options,
            hasReadImageTool: hasReadImageTool,
            canMaterialize: artifactResolver != nil
        )
        let inlineImages = projection.effectiveNativeVision && !imageArtifacts.isEmpty

        // When image bytes are not projected for this turn, the artifacts must still be
        // truthfully reported inside the tool message so the model can reach them through the
        // existing read_image / Vision Group route. Nothing is silently dropped.
        if !inlineImages {
            for image in imageArtifacts {
                textLines.append(ChatContentPart.artifactReferenceText(id: image.id, semanticRole: image.semanticRole, mimeType: image.mimeType))
            }
        }

        let text = textLines.joined(separator: "\n")
        let content: Any
        if !text.isEmpty {
            content = text
        } else if inlineImages {
            content = Self.toolImagePlaceholder
        } else {
            content = NSNull()
        }

        guard inlineImages else {
            return ToolMessageProjection(content: content, adjacentUserMessage: nil)
        }

        var parts: [[String: Any]] = [[
            "type": "text",
            "text": Self.toolImageProvenanceText(callID: msg.toolCallID, toolName: toolName, imageCount: imageArtifacts.count)
        ]]
        for image in imageArtifacts {
            guard let artifactResolver else {
                throw ArtifactStoreError.artifactNotFound(image.id)
            }
            let resolved = try artifactResolver(image.id)
            let actualMime = resolved.mimeType.isEmpty ? image.mimeType : resolved.mimeType
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:\(actualMime);base64,\(resolved.data.base64EncodedString())"]
            ])
        }

        return ToolMessageProjection(
            content: content,
            adjacentUserMessage: ["role": "user", "content": parts]
        )
    }

    /// Bounded provenance text for one tool result's images inside the synthetic group message:
    /// exact call id, optional exact tool name, and count only.
    ///
    /// It never carries bytes, a filename, or an interpretation of the image, and it is
    /// deliberately group-safe: it does not claim the images are the immediately following
    /// content, because one synthetic message can carry the provenance of several tool calls.
    static func toolImageProvenanceText(callID: String?, toolName: String?, imageCount: Int) -> String {
        var text = imageCount == 1 ? "Image result" : "Image results"
        if let callID, !callID.isEmpty {
            text += " from tool call \(callID)"
            if let toolName, !toolName.isEmpty {
                text += " (\(toolName))"
            }
        }
        text += ": \(imageCount) image\(imageCount == 1 ? "" : "s")."
        return text
    }

    private static func appendAttachment(
        _ attachment: ChatAttachment,
        provider: ProviderConfiguration? = nil,
        targetModel: ProviderModel?,
        resolver: (@Sendable (ChatAttachment) throws -> Data)?,
        hasReadImageTool: Bool,
        options: ChatInferenceOptions = ChatInferenceOptions(),
        to parts: inout [[String: Any]]
    ) throws {
        let projection = executableVisualProjection(
            provider: provider,
            targetModel: targetModel,
            options: options,
            hasReadImageTool: hasReadImageTool,
            canMaterialize: resolver != nil
        )

        if attachment.kind == .image, projection.effectiveNativeVision {
            guard let resolver else { throw AttachmentStoreError.fileNotFound(attachment.filename) }
            let data = try resolver(attachment)
            parts.append(["type": "text", "text": AttachmentReferenceFormatter.reference(for: attachment, inspection: .nativeImageInput)])
            parts.append(["type": "image_url", "image_url": ["url": "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"]])
        } else {
            let inspection: AttachmentReferenceFormatter.InspectionCapability? = attachment.kind == .image
                ? (hasReadImageTool ? .readImage : .unavailableImageInspection)
                : nil
            parts.append(["type": "text", "text": AttachmentReferenceFormatter.reference(for: attachment, inspection: inspection)])
        }
    }

    private static func appendArtifact(
        id: UUID,
        semanticRole: ArtifactSemanticRole,
        mimeType: String,
        provider: ProviderConfiguration? = nil,
        targetModel: ProviderModel?,
        resolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))?,
        hasReadImageTool: Bool,
        options: ChatInferenceOptions = ChatInferenceOptions(),
        to parts: inout [[String: Any]]
    ) throws {
        let projection = executableVisualProjection(
            provider: provider,
            targetModel: targetModel,
            options: options,
            hasReadImageTool: hasReadImageTool,
            canMaterialize: resolver != nil
        )

        if mimeType.hasPrefix("image/"), projection.effectiveNativeVision {
            guard let resolver else {
                throw ArtifactStoreError.artifactNotFound(id)
            }
            let resolved = try resolver(id)
            let actualMime = resolved.mimeType.isEmpty ? mimeType : resolved.mimeType
            parts.append(["type": "image_url", "image_url": ["url": "data:\(actualMime);base64,\(resolved.data.base64EncodedString())"]])
        } else {
            parts.append(["type": "text", "text": ChatContentPart.artifactReferenceText(id: id, semanticRole: semanticRole, mimeType: mimeType)])
        }
    }

    /// Single pure decision point for whether this turn can project image bytes natively.
    ///
    /// It restates the existing inputs (declared modality, adapter compatibility, artifact
    /// materialization availability, specialist vision availability) and delegates the
    /// decision to the frozen `ExecutableModalityResolver`. It does not add capability truth.
    private static func executableVisualProjection(
        provider: ProviderConfiguration?,
        targetModel: ProviderModel?,
        options: ChatInferenceOptions,
        hasReadImageTool: Bool,
        canMaterialize: Bool
    ) -> ExecutableModalityProjection {
        let declaredImage = targetModel?.modality?.contains(.imageInput) == true
        let adapterSupportsImage = !options.adapterDisabledNativeVision
            && AdapterCompatibilityResolver.supportsImageProjection(provider: provider, apiFormat: .chatCompletions)
        return ExecutableModalityResolver.resolve(context: ExecutableModalityContext(
            declaredImageInput: declaredImage,
            adapterSupportsImageProjection: adapterSupportsImage,
            artifactMaterializationAvailable: canMaterialize,
            specialistVisionExecutable: hasReadImageTool
        ))
    }

    /// Builds a configured URLRequest for chat completions streaming.
    static func buildURLRequest(
        provider: ProviderConfiguration,
        apiKey: String? = nil,
        modelID: String,
        messages: [ChatRequestMessage],
        tools: [ChatToolDefinition] = [],
        options: ChatInferenceOptions = ChatInferenceOptions(),
        attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)? = nil,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = nil
    ) throws -> URLRequest {
        let url = try EndpointBuilder.endpoint(
            baseURL: provider.baseURL,
            appendV1Suffix: provider.appendV1Suffix,
            endpoint: "chat/completions"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        ProviderRequestConfigurator.configureHeaders(
            request: &request,
            provider: provider,
            apiKey: apiKey,
            isChat: true
        )

        let payload = try buildPayload(
            provider: provider,
            modelID: modelID,
            messages: messages,
            tools: tools,
            options: options,
            attachmentResolver: attachmentResolver,
            artifactResolver: artifactResolver
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        return request
    }
}
