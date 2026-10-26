import Foundation

enum OpenAIResponsesRequestBuilder {

    static func deterministicFunctionCallID(for callID: String) -> String {
        var hash: UInt64 = 5381
        for byte in callID.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        let hex = String(hash, radix: 16)
        return "fc_limare_\(hex)"
    }

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
            endpoint: "responses"
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

    static func buildPayload(
        provider: ProviderConfiguration,
        modelID: String,
        messages: [ChatRequestMessage],
        tools: [ChatToolDefinition] = [],
        options: ChatInferenceOptions = ChatInferenceOptions(),
        attachmentResolver: (@Sendable (ChatAttachment) throws -> Data)? = nil,
        artifactResolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = nil
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "model": modelID,
            "stream": true,
            "store": false,
            "parallel_tool_calls": true
        ]

        let targetModel = options.model ?? provider.models.first(where: { $0.id == modelID })
        let resolution = try ProviderThinkingResolution.resolve(requested: options.thinkingLevel, model: targetModel, provider: provider, maxTokens: options.resolvedMaxOutputTokens(for: targetModel))
        let declaredImage = targetModel?.modality?.contains(.imageInput) == true
        let adapterSupportsImage = !options.adapterDisabledNativeVision && AdapterCompatibilityResolver.supportsImageProjection(provider: provider, apiFormat: .responses)
        let canMaterialize = (artifactResolver != nil || attachmentResolver != nil)
        let hasReadImageTool = tools.contains(where: { $0.function.name == "read_image" })
        let context = ExecutableModalityContext(
            declaredImageInput: declaredImage,
            adapterSupportsImageProjection: adapterSupportsImage,
            artifactMaterializationAvailable: canMaterialize,
            specialistVisionExecutable: hasReadImageTool
        )
        let projection = ExecutableModalityResolver.resolve(context: context)
        let supportsImages = projection.effectiveNativeVision

        // 1. Extract System Messages -> instructions
        let systemMessages = messages.filter { $0.role == "system" }
        if !systemMessages.isEmpty {
            let systemTexts = systemMessages.compactMap { $0.content?.textValue }
            if !systemTexts.isEmpty {
                payload["instructions"] = systemTexts.joined(separator: "\n\n")
            }
        }

        // 2. Build input array
        var inputItems: [[String: Any]] = []

        for msg in messages {
            if msg.role == "system" {
                // System messages are mapped to `instructions` field only, not duplicated in input
                continue
            } else if msg.role == "user" {
                var contentParts: [[String: Any]] = []
                if let content = msg.content {
                    switch content {
                    case .text(let text):
                        if !text.isEmpty {
                            contentParts.append(["type": "input_text", "text": text])
                        }
                    case .parts(let parts):
                        for part in parts {
                            switch part {
                            case .text(let text):
                                if !text.isEmpty {
                                    contentParts.append(["type": "input_text", "text": text])
                                }
                            case .imageUrl(let url):
                                if supportsImages {
                                    contentParts.append(["type": "input_image", "image_url": url])
                                }
                            case .imageAttachment(let att):
                                if att.kind == .image, supportsImages {
                                    guard let resolver = attachmentResolver else {
                                        throw AttachmentStoreError.fileNotFound(att.filename)
                                    }
                                    let data = try resolver(att)
                                    let base64 = data.base64EncodedString()
                                    let mime = att.mimeType.isEmpty ? "image/png" : att.mimeType
                                    let dataURL = "data:\(mime);base64,\(base64)"
                                    contentParts.append(["type": "input_text", "text": AttachmentReferenceFormatter.reference(for: att, inspection: .nativeImageInput)])
                                    contentParts.append(["type": "input_image", "image_url": dataURL])
                                } else {
                                    contentParts.append([
                                        "type": "input_text",
                                        "text": AttachmentReferenceFormatter.reference(for: att, inspection: att.kind == .image ? (tools.contains(where: { $0.function.name == "read_image" }) ? .readImage : .unavailableImageInspection) : nil)
                                    ])
                                }
                            case .attachment(let att):
                                if att.kind == .image, supportsImages {
                                    guard let resolver = attachmentResolver else {
                                        throw AttachmentStoreError.fileNotFound(att.filename)
                                    }
                                    let data = try resolver(att)
                                    let mime = att.mimeType.isEmpty ? "image/png" : att.mimeType
                                    contentParts.append(["type": "input_text", "text": AttachmentReferenceFormatter.reference(for: att, inspection: .nativeImageInput)])
                                    contentParts.append(["type": "input_image", "image_url": "data:\(mime);base64,\(data.base64EncodedString())"])
                                } else {
                                    contentParts.append([
                                        "type": "input_text",
                                        "text": AttachmentReferenceFormatter.reference(for: att, inspection: att.kind == .image ? (tools.contains(where: { $0.function.name == "read_image" }) ? .readImage : .unavailableImageInspection) : nil)
                                    ])
                                }
                            case .artifact(let id, let semanticRole, let mimeType):
                                if mimeType.hasPrefix("image/"), supportsImages {
                                    guard let resolver = artifactResolver else {
                                        throw ArtifactStoreError.artifactNotFound(id)
                                    }
                                    let resolved = try resolver(id)
                                    let actualMime = resolved.mimeType.isEmpty ? mimeType : resolved.mimeType
                                    let dataURL = "data:\(actualMime);base64,\(resolved.data.base64EncodedString())"
                                    contentParts.append(["type": "input_image", "image_url": dataURL])
                                } else {
                                    contentParts.append([
                                        "type": "input_text",
                                        "text": ChatContentPart.artifactReferenceText(id: id, semanticRole: semanticRole, mimeType: mimeType)
                                    ])
                                }
                            }
                        }
                    }
                }
                if !contentParts.isEmpty {
                    inputItems.append([
                        "role": "user",
                        "content": contentParts
                    ])
                }
            } else if msg.role == "assistant" {
                // Replay reasoning echo if exact providerID and modelID match
                if let echo = msg.responsesReasoningEcho,
                   echo.providerID == provider.id,
                   echo.modelID == modelID {
                    for item in echo.items {
                        var reasoningDict: [String: Any] = [
                            "type": "reasoning",
                            "id": item.id,
                            "summary": item.summary.map { ["type": "summary_text", "text": $0] }
                        ]
                        if let enc = item.encryptedContent, !enc.isEmpty {
                            reasoningDict["encrypted_content"] = enc
                        }
                        inputItems.append(reasoningDict)
                    }
                }

                // Responses only accepts output_text/refusal parts on assistant-role input.
                if let text = msg.content?.textValue, !text.isEmpty {
                    inputItems.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": text]]
                    ])
                }

                if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                    for call in toolCalls {
                        let fcID = deterministicFunctionCallID(for: call.id)
                        var functionItem: [String: Any] = [
                            "type": "function_call",
                            "id": fcID,
                            "call_id": call.id,
                            "name": call.function.name,
                            "arguments": call.function.arguments
                        ]
                        if provider.authenticationSelection.credentialKind == .oauthAccessToken { functionItem["namespace"] = "limare" }
                        inputItems.append(functionItem)
                    }
                }
            } else if msg.role == "tool" {
                let callID = msg.toolCallID ?? ""
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
                                    // Only image artifacts change wire shape in this round.
                                    textLines.append(ChatContentPart.artifactReferenceText(id: id, semanticRole: semanticRole, mimeType: mimeType))
                                }
                            case .imageUrl, .imageAttachment, .attachment:
                                // A tool result never carries user-authored attachment parts.
                                break
                            }
                        }
                    }
                }

                // Image bytes are only projected when the effective visual route is
                // executable. Otherwise the artifact keeps a truthful text reference so the
                // model can still reach it through read_image / the Vision Group.
                let projectedImages = supportsImages ? imageArtifacts : []
                if !supportsImages {
                    for image in imageArtifacts {
                        textLines.append(ChatContentPart.artifactReferenceText(id: image.id, semanticRole: image.semanticRole, mimeType: image.mimeType))
                    }
                }

                // Responses carries typed content items INSIDE function_call_output, keeping
                // the function-call causality intact. A bare top-level input_image item is
                // never emitted for tool-produced images.
                let output: Any
                if projectedImages.isEmpty {
                    output = textLines.isEmpty ? "Success" : textLines.joined(separator: "\n")
                } else {
                    var outputItems: [[String: Any]] = textLines.map { ["type": "input_text", "text": $0] }
                    for image in projectedImages {
                        guard let resolver = artifactResolver else {
                            throw ArtifactStoreError.artifactNotFound(image.id)
                        }
                        let resolved = try resolver(image.id)
                        let actualMime = resolved.mimeType.isEmpty ? image.mimeType : resolved.mimeType
                        let dataURL = "data:\(actualMime);base64,\(resolved.data.base64EncodedString())"
                        outputItems.append(["type": "input_image", "image_url": dataURL])
                    }
                    output = outputItems
                }

                inputItems.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": output
                ])
            }
        }

        payload["input"] = inputItems

        // 3. Convert Tools
        if !tools.isEmpty {
            let encoder = JSONEncoder()
            var convertedTools: [[String: Any]] = []
            for tool in tools {
                let paramsData = try encoder.encode(tool.function.parameters)
                let paramsJSON = try JSONSerialization.jsonObject(with: paramsData)
                convertedTools.append([
                    "type": "function",
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": paramsJSON
                ])
            }
            if provider.authenticationSelection.credentialKind == .oauthAccessToken {
                payload["tools"] = [["type": "namespace", "name": "limare", "description": "Limare local tools", "tools": convertedTools]]
            } else { payload["tools"] = convertedTools }
            payload["tool_choice"] = "auto"
        }

        // 4. max_output_tokens
        let maxTokens = options.resolvedMaxOutputTokens(for: targetModel)
        if provider.authenticationSelection.credentialKind != .oauthAccessToken { payload["max_output_tokens"] = maxTokens }

        // 5. Reasoning / Thinking
        payload.merge(thinkingControl(provider: provider, modelID: modelID, model: targetModel,
                                      level: resolution.effective)) { _, control in control }

        return payload
    }

    /// The thinking keys a request sends for one level. Thinking menus admit and dedupe on this same projection.
    static func thinkingControl(provider: ProviderConfiguration, modelID: String, model: ProviderModel?,
                                level: ThinkingLevel) -> [String: Any] {
        let isMistral = provider.baseURL.lowercased().contains("mistral.ai") || modelID.lowercased().contains("mistral")
        guard !isMistral, model?.supportsReasoning == true else { return [:] }
        if level != .off {
            return [
                "reasoning": ["effort": resolveResponsesEffort(model: model, level: level), "summary": "auto"],
                "include": ["reasoning.encrypted_content"],
            ]
        }
        guard let offEffort = resolveResponsesOffEffort(provider: provider, model: model) else { return [:] }
        return ["reasoning": ["effort": offEffort]]
    }

    private static func resolveResponsesEffort(model: ProviderModel?, level: ThinkingLevel) -> String {
        let requestedStr: String
        switch level {
        case .minimal: requestedStr = "minimal"
        case .low: requestedStr = "low"
        case .medium: requestedStr = "medium"
        case .high: requestedStr = "high"
        case .xhigh: requestedStr = "xhigh"
        case .max: requestedStr = "max"
        case .ultra: requestedStr = "unsupported-harness-intent"
        case .off: requestedStr = "none"
        }

        if let declaredTiers = model?.reasoningEffortValues, !declaredTiers.isEmpty {
            return ThinkingRuleResolver.clampEffort(requestedStr, to: declaredTiers)
        }
        return requestedStr
    }

    private static func resolveResponsesOffEffort(provider: ProviderConfiguration, model: ProviderModel?) -> String? {
        if let tiers = model?.reasoningEffortValues, !tiers.isEmpty {
            if tiers.contains("none") { return "none" }
            if tiers.contains("off") { return "off" }
            return nil
        }
        // If official OpenAI or Ark/Doubao
        let lowerBase = provider.baseURL.lowercased()
        if lowerBase.contains("api.openai.com") {
            return "none"
        }
        if lowerBase.contains("volces.com") || lowerBase.contains("volcengine") {
            return nil // Minimal is a positive tier, not an off action.
        }
        return nil
    }
}
