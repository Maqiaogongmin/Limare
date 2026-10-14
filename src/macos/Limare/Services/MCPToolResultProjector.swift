import Foundation

/// Projects MCP tool call results (content arrays or raw json) into structured `MCPToolCallResult`
/// and typed `ToolResultPart` items with fail-closed binary materialization truth.
enum MCPToolResultProjector: Sendable {

    static func project(
        contentItems: [AnyCodable]?,
        rawResult: AnyCodable?,
        isError: Bool,
        conversationID: UUID?,
        artifactStore: ArtifactStore?
    ) -> MCPToolCallResult {
        guard let contentArray = contentItems else {
            if let rawResult = rawResult {
                if let data = try? JSONEncoder().encode(rawResult),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    return MCPToolCallResult(content: jsonStr, isError: isError)
                }
                return MCPToolCallResult(content: "\(rawResult)", isError: isError)
            }
            return MCPToolCallResult(content: "(empty content)", isError: isError)
        }

        var textParts: [String] = []
        var resultParts: [ToolResultPart] = []
        var materializationFailed = false
        var failureReasons: [String] = []

        for item in contentArray {
            if let dict = item.dictionaryValue {
                let type = dict["type"]?.stringValue
                if type == "image" {
                    let mimeType = dict["mimeType"]?.stringValue ?? "image/png"
                    guard let base64String = dict["data"]?.stringValue else {
                        materializationFailed = true
                        let err = "Missing base64 data for image"
                        failureReasons.append(err)
                        textParts.append("[Image Error: \(err)]")
                        resultParts.append(.error(err))
                        continue
                    }
                    guard let data = Data(base64Encoded: base64String, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
                        materializationFailed = true
                        let err = "Invalid base64 encoding for image data"
                        failureReasons.append(err)
                        textParts.append("[Image Error: \(err)]")
                        resultParts.append(.error(err))
                        continue
                    }
                    guard let store = artifactStore, let convID = conversationID else {
                        materializationFailed = true
                        let err = "ArtifactStore or conversation scope unavailable for image materialization"
                        failureReasons.append(err)
                        textParts.append("[Image Error: \(err)]")
                        resultParts.append(.error(err))
                        continue
                    }
                    let ext = mimeType.contains("jpeg") || mimeType.contains("jpg") ? "jpg" : "png"
                    let filename = "mcp_image_\(UUID().uuidString.prefix(8)).\(ext)"
                    do {
                        let desc = try store.save(
                            data: data,
                            conversationID: convID,
                            filename: filename,
                            mimeType: mimeType,
                            producerProvenance: .mcpResource,
                            retentionClass: .temporaryExtraction
                        )
                        resultParts.append(.artifact(id: desc.artifactID, semanticRole: .image, mimeType: mimeType))
                        textParts.append("[Image: \(desc.artifactID.uuidString), \(mimeType), \(data.count) bytes]")
                    } catch {
                        materializationFailed = true
                        let err = "Failed to save image artifact: \(error.localizedDescription)"
                        failureReasons.append(err)
                        textParts.append("[Image Error: \(err)]")
                        resultParts.append(.error(err))
                    }
                } else if type == "resource" {
                    if let resDict = dict["resource"]?.dictionaryValue {
                        let mimeType = resDict["mimeType"]?.stringValue ?? "application/octet-stream"
                        if let blob = resDict["blob"]?.stringValue {
                            guard let data = Data(base64Encoded: blob, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
                                materializationFailed = true
                                let err = "Invalid base64 encoding for resource blob"
                                failureReasons.append(err)
                                textParts.append("[Resource Error: \(err)]")
                                resultParts.append(.error(err))
                                continue
                            }
                            guard let store = artifactStore, let convID = conversationID else {
                                materializationFailed = true
                                let err = "ArtifactStore or conversation scope unavailable for resource materialization"
                                failureReasons.append(err)
                                textParts.append("[Resource Error: \(err)]")
                                resultParts.append(.error(err))
                                continue
                            }
                            let filename = "mcp_resource_\(UUID().uuidString.prefix(8)).bin"
                            do {
                                let desc = try store.save(
                                    data: data,
                                    conversationID: convID,
                                    filename: filename,
                                    mimeType: mimeType,
                                    producerProvenance: .mcpResource,
                                    retentionClass: .temporaryExtraction
                                )
                                resultParts.append(.artifact(id: desc.artifactID, semanticRole: .deliverable, mimeType: mimeType))
                                textParts.append("[Resource: \(desc.artifactID.uuidString), \(mimeType), \(data.count) bytes]")
                            } catch {
                                materializationFailed = true
                                let err = "Failed to save resource artifact: \(error.localizedDescription)"
                                failureReasons.append(err)
                                textParts.append("[Resource Error: \(err)]")
                                resultParts.append(.error(err))
                            }
                        } else if let resText = resDict["text"]?.stringValue {
                            textParts.append(resText)
                            resultParts.append(.text(resText))
                        } else {
                            materializationFailed = true
                            let err = "Resource has neither text nor blob"
                            failureReasons.append(err)
                            textParts.append("[Resource Error: \(err)]")
                            resultParts.append(.error(err))
                        }
                    } else {
                        materializationFailed = true
                        let err = "Malformed resource dictionary"
                        failureReasons.append(err)
                        textParts.append("[Resource Error: \(err)]")
                        resultParts.append(.error(err))
                    }
                } else if type == "text" {
                    if let text = dict["text"]?.stringValue {
                        textParts.append(text)
                        resultParts.append(.text(text))
                    }
                } else {
                    if let text = dict["text"]?.stringValue {
                        textParts.append(text)
                        resultParts.append(.text(text))
                    } else if let data = try? JSONEncoder().encode(item),
                              let str = String(data: data, encoding: .utf8) {
                        textParts.append(str)
                        resultParts.append(.text(str))
                    }
                }
            } else if let str = item.stringValue {
                textParts.append(str)
                resultParts.append(.text(str))
            }
        }

        let joined = textParts.joined(separator: "\n")
        let finalIsError = isError || materializationFailed

        return MCPToolCallResult(
            content: joined.isEmpty ? (finalIsError ? "Tool execution failed: \(failureReasons.joined(separator: "; "))" : "(empty content)") : joined,
            isError: finalIsError,
            resultParts: resultParts.isEmpty ? nil : resultParts
        )
    }
}
