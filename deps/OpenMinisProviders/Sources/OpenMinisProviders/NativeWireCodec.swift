import Foundation
import SwiftAnthropic

public enum NativeWireProtocol: String, Sendable { case anthropicMessages, geminiNative }

public enum NativeWireError: LocalizedError {
    case invalidInput, incompleteStream, terminal(String)
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Native protocol input could not be projected without losing information."
        case .incompleteStream: "The native stream ended without a successful protocol terminal event."
        case .terminal(let reason): "Native provider terminated: \(reason)."
        }
    }
}

public enum NativeDecodedEvent: Sendable {
    case text(String), thinking(String)
    case tool(index: Int, id: String?, name: String?, arguments: String)
    case metadata(Data)
    case usage(input: Int, output: Int)
    case completed(String)
}

/// Pure protocol projection. Provider configuration, credential acquisition and transport belong to the host.
public enum NativeWireCodec {
    /// Shared by request projection and host UI distinct-control checks.
    public static func thinkingControlJSON(protocol wire: NativeWireProtocol, modelID: String,
        maxTokens: Int, thinking: String, supportsReasoning: Bool?, effortValues: [String]?,
        kimiCodeProfile: Bool = false) throws -> Data {
        guard let level = ThinkingLevel(rawValue: thinking), level != .ultra else { throw NativeWireError.invalidInput }
        var control: [String: Any] = [:]
        switch wire {
        case .anthropicMessages:
            if kimiCodeProfile {
                // Kimi's compatible API accepts named effort, with thinking enabled by default.
                if effortValues?.isEmpty != false { break }
                if level == .off { control["thinking"] = ["type": "disabled"] }
                else {
                    guard effortValues?.contains(thinking) == true else { throw NativeWireError.invalidInput }
                    control["output_config"] = ["effort": thinking]
                }
            } else {
                let shape = ThinkingRuleResolver.anthropicThinkingShape(modelId: modelID, supportsReasoning: supportsReasoning, level: level, maxTokens: maxTokens)
                if let effort = shape["effort"] as? String {
                    guard level != .minimal || effortValues?.contains("minimal") == true else { throw NativeWireError.invalidInput }
                    control["thinking"] = ["type": "adaptive"]
                    control["output_config"] = ["effort": effortValues?.contains(thinking) == true ? thinking : effort]
                } else if let budget = shape["budget_tokens"] as? Int {
                    guard budget >= 1024, budget < maxTokens else { throw NativeWireError.invalidInput }
                    control["thinking"] = ["type": "enabled", "budget_tokens": budget]
                } else if shape["disabled"] != nil { control["thinking"] = ["type": "disabled"] }
            }
        case .geminiNative:
            guard ![.xhigh, .max].contains(level) else { throw NativeWireError.invalidInput }
            let canDisableBudget = modelID.lowercased().contains("gemini-2.5-flash") && !modelID.lowercased().contains("lite")
            let config = level == .off && !canDisableBudget ? [:] : ThinkingRuleResolver.geminiThinkingConfig(modelId: modelID, level: level)
            if !config.isEmpty { control["thinkingConfig"] = config }
        }
        return try JSONSerialization.data(withJSONObject: control, options: [.sortedKeys])
    }

    public static func request(protocol wire: NativeWireProtocol, baseURL: String, appendV1: Bool,
                               apiKey: String, modelID: String, messagesJSON: Data, toolsJSON: Data,
                               maxTokens: Int, thinking: String, supportsReasoning: Bool?,
                               effortValues: [String]?, continuationJSON: Data? = nil,
                               kimiCodeProfile: Bool = false) throws -> URLRequest {
        guard let rows = try JSONSerialization.jsonObject(with: messagesJSON) as? [[String: Any]],
              let tools = try JSONSerialization.jsonObject(with: toolsJSON) as? [[String: Any]],
              let level = ThinkingLevel(rawValue: thinking), level != .ultra else { throw NativeWireError.invalidInput }
        let messages = try motherMessages(rows)
        let model = LLMModel(id: modelID, displayName: modelID, provider: wire.rawValue,
                             supportsReasoning: supportsReasoning, reasoningEffortValues: effortValues)
        let system = rows.filter { $0["role"] as? String == "system" }.compactMap { $0["content"] as? String }.joined(separator: "\n\n")
        let metadata = try continuationJSON.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        let control = try JSONSerialization.jsonObject(with: thinkingControlJSON(protocol: wire, modelID: modelID,
            maxTokens: maxTokens, thinking: thinking, supportsReasoning: supportsReasoning,
            effortValues: effortValues, kimiCodeProfile: kimiCodeProfile)) as! [String: Any]
        var body: [String: Any]
        let endpoint: String
        switch wire {
        case .anthropicMessages:
            let host = URLComponents(string: baseURL)?.host ?? ""
            let projection = AnthropicAgentProvider(provider: AnthropicProvider(model: model, isOfficialAnthropicEndpoint: host == "api.anthropic.com"))
            let parameter = MessageParameter(model: .other(modelID), messages: projection.convertMessages(messages),
                                             maxTokens: maxTokens, system: system.isEmpty ? nil : .text(system), stream: true)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            body = try JSONSerialization.jsonObject(with: encoder.encode(parameter)) as! [String: Any]
            if !tools.isEmpty {
                body["tools"] = tools.map { tool -> [String: Any] in
                    let f = tool["function"] as? [String: Any] ?? tool
                    return ["name": f["name"] ?? "", "description": f["description"] ?? "", "input_schema": f["parameters"] ?? [:]]
                }
            }
            body.merge(control) { _, new in new }
            try restoreAnthropicToolInputs(rows, into: &body)
            var projectedMessages = body["messages"] as? [[String: Any]] ?? []
            for i in projectedMessages.indices {
                guard var blocks = projectedMessages[i]["content"] as? [[String: Any]] else { continue }
                for j in blocks.indices where blocks[j]["type"] as? String == "tool_result" {
                    if let id = blocks[j]["tool_use_id"] as? String, let image = projection.pendingToolResultImages[id] {
                        let text = blocks[j]["content"] as? String ?? ""
                        blocks[j]["content"] = [["type": "text", "text": text],
                            ["type": "image", "source": ["type": "base64", "media_type": image.1, "data": image.0.base64EncodedString()]]]
                    }
                }
                projectedMessages[i]["content"] = blocks
            }
            body["messages"] = projectedMessages
            if let perCall = metadata?["thinkingByToolCallID"] as? [String: [[String: Any]]] {
                restoreThinkingBlocks(perCall, into: &body)
            } else if let blocks = metadata?["thinkingBlocks"] as? [[String: Any]] {
                restoreThinkingBlocks(blocks, into: &body)
            }
            var base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if appendV1 && base.hasSuffix("/v1") { base = String(base.dropLast(3)) }
            endpoint = appendV1 ? URLBuilding.join(base, "/v1/messages") : URLBuilding.join(base, "/messages")
        case .geminiNative:
            let projection = GeminiAgentProvider(model: model)
            if let signatures = metadata?["toolSignatures"] as? [String: String] {
                projection.toolCallMetadataMap = signatures.mapValues { ToolCallMetadata(thoughtSignature: $0) }
            }
            let contents = projection.convertMessages(messages)
            body = ["contents": contents]
            if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
            var generation: [String: Any] = ["maxOutputTokens": maxTokens]
            generation.merge(control) { _, new in new }
            body["generationConfig"] = generation
            if !tools.isEmpty {
                body["tools"] = [["functionDeclarations": tools.map { tool -> [String: Any] in
                    let f = tool["function"] as? [String: Any] ?? tool
                    return ["name": f["name"] ?? "", "description": f["description"] ?? "", "parametersJsonSchema": f["parameters"] ?? [:]]
                }]]
                body["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
            }
            endpoint = URLBuilding.join(baseURL, "models/\(modelID):streamGenerateContent?alt=sse")
        }
        guard let url = URL(string: endpoint) else { throw NativeWireError.invalidInput }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if wire == .anthropicMessages {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else { request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key") }
        return request
    }

    private static func motherMessages(_ rows: [[String: Any]]) throws -> [AgentMessage] {
        var result: [AgentMessage] = []
        for row in rows {
            let role = row["role"] as? String ?? ""
            if role == "system" { continue }
            var parts: [AgentContentPart] = []
            if let text = row["content"] as? String, !text.isEmpty {
                if role == "tool" {
                    parts.append(.toolResult(id: sanitizeToolId(row["tool_call_id"] as? String ?? ""), name: "", content: text, isError: false))
                } else { parts.append(.text(text)) }
            }
            if let content = row["content"] as? [[String: Any]] {
                for item in content {
                    if let text = item["text"] as? String { parts.append(.text(text)) }
                    if let image = item["image_url"] as? [String: Any], let url = image["url"] as? String {
                        guard url.hasPrefix("data:"), let split = url.firstIndex(of: ","),
                              let data = Data(base64Encoded: String(url[url.index(after: split)...])) else { throw NativeWireError.invalidInput }
                        let mime = String(url[url.index(url.startIndex, offsetBy: 5)..<split]).components(separatedBy: ";")[0]
                        parts.append(.imageData(data: data, mimeType: mime))
                    }
                }
                if role == "tool" {
                    let text = parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
                    let images = parts.compactMap { if case .imageData(let d, let m, _) = $0 { return (d, m) }; return nil }
                    parts = [.toolResult(id: sanitizeToolId(row["tool_call_id"] as? String ?? ""), name: "", content: text, isError: false, imageData: images.first?.0, imageMimeType: images.first?.1)]
                }
            }
            for call in row["tool_calls"] as? [[String: Any]] ?? [] {
                guard let f = call["function"] as? [String: Any], let name = f["name"] as? String,
                      let raw = f["arguments"] as? String,
                      let args = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw NativeWireError.invalidInput }
                parts.append(.toolUse(id: sanitizeToolId(call["id"] as? String ?? ""), name: name, input: args))
            }
            if !parts.isEmpty { result.append(AgentMessage(role: role == "assistant" ? .assistant : .user, parts: parts, reasoningContent: row["reasoning_content"] as? String)) }
        }
        return result
    }

    private static func restoreAnthropicToolInputs(_ rows: [[String: Any]], into body: inout [String: Any]) throws {
        var inputs: [String: [String: Any]] = [:]
        for row in rows {
            for call in row["tool_calls"] as? [[String: Any]] ?? [] {
                let f = call["function"] as? [String: Any] ?? [:]
                if let id = call["id"] as? String, let raw = f["arguments"] as? String {
                    inputs[sanitizeToolId(id)] = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                }
            }
        }
        var messages = body["messages"] as? [[String: Any]] ?? []
        for i in messages.indices {
            guard var blocks = messages[i]["content"] as? [[String: Any]] else { continue }
            for j in blocks.indices where blocks[j]["type"] as? String == "tool_use" {
                if let id = blocks[j]["id"] as? String, let input = inputs[id] { blocks[j]["input"] = input }
            }
            messages[i]["content"] = blocks
        }
        body["messages"] = messages
    }

    private static func restoreThinkingBlocks(_ byCall: [String: [[String: Any]]], into body: inout [String: Any]) {
        var messages = body["messages"] as? [[String: Any]] ?? []
        for i in messages.indices where messages[i]["role"] as? String == "assistant" {
            guard let content = messages[i]["content"] as? [[String: Any]],
                  let id = content.first(where: { $0["type"] as? String == "tool_use" })?["id"] as? String,
                  let blocks = byCall[id] else { continue }
            messages[i]["content"] = blocks + content
        }
        body["messages"] = messages
    }

    private static func restoreThinkingBlocks(_ blocks: [[String: Any]], into body: inout [String: Any]) {
        var messages = body["messages"] as? [[String: Any]] ?? []
        guard let i = messages.lastIndex(where: { $0["role"] as? String == "assistant" }),
              let content = messages[i]["content"] as? [[String: Any]] else { return }
        messages[i]["content"] = blocks + content
        body["messages"] = messages
    }
}

public final class NativeStreamDecoder {
    private let wire: NativeWireProtocol
    private let anthropic = StreamHandler()
    private var nextToolIndex = 0
    private var signatures: [String: String] = [:]
    private var anthropicCallIDs: [String] = []
    private var terminalReason: String?
    public private(set) var isCompleted = false

    public init(protocol wire: NativeWireProtocol) { self.wire = wire }

    public func parseLine(_ line: String) throws -> [NativeDecodedEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if raw == "[DONE]" { return [] }
        guard let data = raw.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeWireError.invalidInput }
        if let error = root["error"] as? [String: Any] { throw NativeWireError.terminal(error["type"] as? String ?? error["status"] as? String ?? "provider_error") }
        var events: [NativeDecodedEvent] = []
        if let usage = root["usageMetadata"] as? [String: Any] {
            events.append(.usage(input: usage["promptTokenCount"] as? Int ?? 0, output: usage["candidatesTokenCount"] as? Int ?? 0))
        }
        let anthropicUsage = root["usage"] as? [String: Any] ?? (root["message"] as? [String: Any])?["usage"] as? [String: Any]
        if let usage = anthropicUsage {
            events.append(.usage(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0))
        }
        switch wire {
        case .anthropicMessages:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let response = try decoder.decode(MessageStreamResponse.self, from: data)
            anthropic.handleStreamEvent(response)
            if let t = response.delta?.text, !t.isEmpty { events.append(.text(t)) }
            if let t = response.delta?.thinking, !t.isEmpty { events.append(.thinking(t)) }
            if root["type"] as? String == "content_block_start", let b = root["content_block"] as? [String: Any], b["type"] as? String == "tool_use" {
                let initial = b["input"] as? [String: Any] ?? [:]
                let arguments = initial.isEmpty ? "" : String(decoding: try JSONSerialization.data(withJSONObject: initial, options: [.sortedKeys]), as: UTF8.self)
                events.append(.tool(index: root["index"] as? Int ?? nextToolIndex, id: b["id"] as? String, name: b["name"] as? String, arguments: arguments))
                if let id = b["id"] as? String { anthropicCallIDs.append(id) }
                nextToolIndex += 1
            }
            if let delta = root["delta"] as? [String: Any], let partial = delta["partial_json"] as? String {
                events.append(.tool(index: root["index"] as? Int ?? 0, id: nil, name: nil, arguments: partial))
            }
            if let reason = response.delta?.stopReason { terminalReason = reason }
            if root["type"] as? String == "message_stop" {
                guard let reason = terminalReason, ["end_turn", "tool_use", "stop_sequence", "max_tokens"].contains(reason) else { throw NativeWireError.terminal(terminalReason ?? "unknown_finish_reason") }
                let blocks = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anthropic.getThinkingBlocksForAPI()))
                events.append(.metadata(try JSONSerialization.data(withJSONObject: ["thinkingBlocks": blocks, "toolCallIDs": anthropicCallIDs])))
                events.append(.completed(reason)); isCompleted = true
            }
        case .geminiNative:
            guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { return events }
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let t = part["text"] as? String, !t.isEmpty { events.append(part["thought"] as? Bool == true ? .thinking(t) : .text(t)) }
                if let fc = part["functionCall"] as? [String: Any], let name = fc["name"] as? String {
                    let id = "gemini_" + UUID().uuidString
                    let args = try JSONSerialization.data(withJSONObject: fc["args"] as? [String: Any] ?? [:], options: [.sortedKeys])
                    events.append(.tool(index: nextToolIndex, id: id, name: name, arguments: String(decoding: args, as: UTF8.self)))
                    if let signature = part["thoughtSignature"] as? String { signatures[id] = signature }
                    nextToolIndex += 1
                }
            }
            if let reason = candidate["finishReason"] as? String {
                guard ["STOP", "MAX_TOKENS"].contains(reason) else { throw NativeWireError.terminal(reason) }
                events.append(.metadata(try JSONSerialization.data(withJSONObject: ["toolSignatures": signatures])))
                events.append(.completed(reason == "MAX_TOKENS" ? "max_tokens" : nextToolIndex > 0 ? "tool_use" : "end_turn"))
                isCompleted = true
            }
        }
        return events
    }

    public func finish() throws { guard isCompleted else { throw NativeWireError.incompleteStream } }
}
