import Foundation
final class GeminiAgentProvider {
 let logger = AppLogger(category: "GeminiProjection")
 var toolCallMetadataMap: [String: ToolCallMetadata] = [:]
 let model: LLMModel
 init(model: LLMModel) { self.model = model }
    func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        // Pre-scan: build tool call ID → name map so functionResponse can always
        // include the required name (ToolResult loaded from DB may have name="").
        var toolNameMap: [String: String] = [:]
        for msg in messages {
            for part in msg.parts {
                if case .toolUse(let id, let name, _) = part {
                    toolNameMap[id] = name
                }
            }
        }

        // Gemini 3.x requires thoughtSignature on every functionCall when thinking
        // is enabled. Collect IDs of unsigned tool calls so we can convert them
        // (and their paired functionResponses) to text summaries instead.
        let requiresSig = model.id.lowercased().contains("gemini-3")
        var unsignedToolCallIds: Set<String> = []
        if requiresSig {
            for msg in messages {
                for part in msg.parts {
                    if case .toolUse(let id, _, _) = part {
                        if toolCallMetadataMap[id]?.thoughtSignature == nil {
                            unsignedToolCallIds.insert(id)
                        }
                    }
                }
            }
            if !unsignedToolCallIds.isEmpty {
                logger.info("[GeminiAgent] Converting \(unsignedToolCallIds.count) unsigned tool call(s) to text for Gemini 3.x compatibility")
            }
        }

        return messages.map { msg in
            let role = msg.role == .user ? "user" : "model"
            var parts: [[String: Any]] = []

            for part in msg.parts {
                switch part {
                case .text(let text):
                    // [T-gemini-empty-part-oneof-400] Gemini rejects {"text": ""}
                    // with an uninitialized-oneof 400. Skip a truly empty text
                    // part when the turn has other parts; the parts.isEmpty
                    // fallback below covers a turn whose only content was empty.
                    if !text.isEmpty {
                        parts.append(GeminiWireFormat.textPart(text))
                    }

                case .toolUse(let id, let name, let input):
                    if unsignedToolCallIds.contains(id) {
                        // Convert unsigned function call to text summary
                        let argsDesc = (try? JSONSerialization.data(withJSONObject: input))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        parts.append(["text": "[Called \(name) with: \(argsDesc)]"])
                    } else {
                        let sig = toolCallMetadataMap[id]?.thoughtSignature
                        parts.append(GeminiConversation.functionCallPart(
                            name: name, args: input, thoughtSignature: sig
                        ))
                    }

                case .toolResult(let id, let name, let content, _, let imageData, let imageMimeType, _, _):
                    // Resolve tool name: prefer the name from the matching toolUse part
                    // (ToolResult loaded from DB may have name="" since it's not persisted there)
                    let resolvedName = (!name.isEmpty ? name : toolNameMap[id]) ?? "unknown"
                    if unsignedToolCallIds.contains(id) {
                        // Convert orphaned function response to text summary
                        let truncated = content.count > 500 ? String(content.prefix(500)) + "..." : content
                        parts.append(["text": "[Result of \(resolvedName): \(truncated)]"])
                        // Still include image data if present
                        if let data = imageData {
                            let mime = imageMimeType ?? "image/jpeg"
                            parts.append(["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]])
                        }
                    } else {
                        // [T-gemini-empty-part-oneof-400] Never ship an empty
                        // result string into the functionResponse payload.
                        parts.append(GeminiConversation.functionResponsePart(
                            name: resolvedName,
                            response: GeminiWireFormat.functionResponseResult(content)
                        ))
                        if let data = imageData {
                            let mime = imageMimeType ?? "image/jpeg"
                            parts.append(["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]])
                        }
                    }

                case .imageData(let data, let mimeType, _):
                    let base64 = data.base64EncodedString()
                    parts.append(["inlineData": ["mimeType": mimeType, "data": base64]])
                }
            }

            if parts.isEmpty {
                parts.append(["text": "(empty)"])
            }

            return ["role": role, "parts": parts]
        }
    }
    func convertTools(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: [String: Any]] = [:]
            for (name, param) in tool.parameters {
                var prop: [String: Any] = [
                    "type": param.type.geminiType,
                    "description": param.description,
                ]
                if let enumValues = param.enumValues {
                    // Gemini doesn't support enum directly in all cases, but we can add it to description
                    prop["description"] = "\(param.description) (values: \(enumValues.joined(separator: ", ")))"
                }
                properties[name] = prop
            }

            var params: [String: Any] = [
                "type": "OBJECT",
                "properties": properties,
                "required": tool.required,
            ]
            if let ordering = tool.propertyOrdering {
                params["propertyOrdering"] = ordering
            }
            return GeminiConversation.toolDefinition(
                name: tool.name,
                description: tool.description,
                parameters: params
            )
        }
    }
}
extension AgentParamType {
    var geminiType: String {
        switch self {
        case .string: return "STRING"
        case .integer: return "INTEGER"
        case .boolean: return "BOOLEAN"
        }
    }
}
