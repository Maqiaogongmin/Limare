import XCTest
@testable import OpenMinisProviders

final class NativeProtocolTests: XCTestCase {
    private let messages = Data("[{\"role\":\"user\",\"content\":\"Read the project\"}]".utf8)
    private let tools = Data("[{\"type\":\"function\",\"function\":{\"name\":\"nested_tool\",\"description\":\"fixture\",\"parameters\":{\"type\":\"object\",\"properties\":{\"tasks\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"number\"}}}}},\"required\":[\"tasks\"],\"additionalProperties\":false}}}]".utf8)

    func testAnthropicNestedSchemaAndExactXHigh() throws {
        let request = try NativeWireCodec.request(protocol: .anthropicMessages, baseURL: "https://api.anthropic.com/v1",
            appendV1: true, apiKey: "fixture", modelID: "claude-opus-4-8", messagesJSON: messages,
            toolsJSON: tools, maxTokens: 4096, thinking: "xhigh", supportsReasoning: true, effortValues: ["xhigh", "max"])
        XCTAssertEqual(request.url?.path, "/v1/messages")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertNil(body["maxTokens"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
        let schema = ((body["tools"] as? [[String: Any]])?.first)?["input_schema"] as? [String: Any]
        XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
        XCTAssertEqual(((schema?["properties"] as? [String: Any])?["tasks"] as? [String: Any])?["type"] as? String, "array")
    }

    func testGeminiMinimalAndRawSchema() throws {
        let request = try NativeWireCodec.request(protocol: .geminiNative, baseURL: "https://generativelanguage.googleapis.com/v1beta",
            appendV1: false, apiKey: "fixture", modelID: "gemini-3-flash-preview", messagesJSON: messages,
            toolsJSON: tools, maxTokens: 4096, thinking: "minimal", supportsReasoning: true, effortValues: ["minimal", "low", "high"])
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let generation = body["generationConfig"] as! [String: Any]
        XCTAssertEqual((generation["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String, "minimal")
        let declaration = (((body["tools"] as? [[String: Any]])?.first)?["functionDeclarations"] as? [[String: Any]])?.first
        XCTAssertNotNil(declaration?["parametersJsonSchema"])
        XCTAssertNil(declaration?["parameters"])
    }

    func testEOFIsNeverCompletion() throws {
        let decoder = NativeStreamDecoder(protocol: .geminiNative)
        _ = try decoder.parseLine("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}")
        XCTAssertThrowsError(try decoder.finish())
    }

    func testGeminiSafetyFinishFails() {
        let decoder = NativeStreamDecoder(protocol: .geminiNative)
        XCTAssertThrowsError(try decoder.parseLine("data: {\"candidates\":[{\"finishReason\":\"SAFETY\"}]}"))
        XCTAssertFalse(decoder.isCompleted)
    }

    func testGeminiSignatureSurvivesMetadataBoundary() throws {
        let decoder = NativeStreamDecoder(protocol: .geminiNative)
        let events = try decoder.parseLine("data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"nested_tool\",\"args\":{\"tasks\":[]}},\"thoughtSignature\":\"signed-fixture\"}]},\"finishReason\":\"STOP\"}]}")
        let metadata = events.compactMap { event -> Data? in if case .metadata(let data) = event { return data }; return nil }.first!
        let object = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
        XCTAssertEqual((object["toolSignatures"] as? [String: String])?.values.first, "signed-fixture")
        try decoder.finish()
    }

    func testUnknownThinkingRejected() {
        XCTAssertThrowsError(try NativeWireCodec.request(protocol: .geminiNative, baseURL: "https://example.invalid",
            appendV1: false, apiKey: "fixture", modelID: "fixture", messagesJSON: messages,
            toolsJSON: tools, maxTokens: 100, thinking: "future-tier", supportsReasoning: true, effortValues: ["future-tier"]))
    }

    func testBudgetControlReflectsOutputCap() throws {
        func control(_ level: String) throws -> Data {
            try NativeWireCodec.thinkingControlJSON(protocol: .anthropicMessages, modelID: "claude-3-7-sonnet",
                maxTokens: 4096, thinking: level, supportsReasoning: true, effortValues: nil)
        }
        XCTAssertEqual(try control("low"), try control("medium"))
        XCTAssertEqual(try control("medium"), try control("high"))
        let object = try JSONSerialization.jsonObject(with: control("low")) as! [String: Any]
        XCTAssertEqual((object["thinking"] as? [String: Any])?["budget_tokens"] as? Int, 4095)
    }

    func testKimiCompatibleEffortIsDistinctAndHighSpeedHasNoControl() throws {
        for id in ["k3", "k3-256k", "kimi-for-coding"] {
            var controls: Set<Data> = []
            for effort in ["low", "high", "max"] {
                let request = try NativeWireCodec.request(protocol: .anthropicMessages, baseURL: "https://api.kimi.com/coding",
                    appendV1: true, apiKey: "fixture", modelID: id, messagesJSON: messages, toolsJSON: tools,
                    maxTokens: 4096, thinking: effort, supportsReasoning: true, effortValues: ["low", "high", "max"], kimiCodeProfile: true)
                XCTAssertEqual(request.url?.path, "/coding/v1/messages")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                XCTAssertEqual(body["model"] as? String, id)
                XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, effort)
                XCTAssertNil((body["thinking"] as? [String: Any])?["budget_tokens"])
                controls.insert(try NativeWireCodec.thinkingControlJSON(protocol: .anthropicMessages, modelID: id,
                    maxTokens: 4096, thinking: effort, supportsReasoning: true, effortValues: ["low", "high", "max"], kimiCodeProfile: true))
            }
            XCTAssertEqual(controls.count, 3)
            let off = try NativeWireCodec.thinkingControlJSON(protocol: .anthropicMessages, modelID: id,
                maxTokens: 4096, thinking: "off", supportsReasoning: true, effortValues: ["low", "high", "max"], kimiCodeProfile: true)
            XCTAssertEqual(((try JSONSerialization.jsonObject(with: off)) as? [String: Any])?["thinking"] as? [String: String], ["type": "disabled"])
        }
        let highSpeed = try NativeWireCodec.thinkingControlJSON(protocol: .anthropicMessages, modelID: "kimi-for-coding-highspeed",
            maxTokens: 4096, thinking: "off", supportsReasoning: true, effortValues: [], kimiCodeProfile: true)
        XCTAssertEqual(highSpeed, Data("{}".utf8))
    }

    func testAnthropicSignedThinkingColdReplayAcrossTwoTurns() throws {
        let rows: [[String: Any]] = [
            ["role": "user", "content": "Read"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "call_first", "type": "function", "function": ["name": "nested_tool", "arguments": "{\"tasks\":[]}"]]]],
            ["role": "tool", "tool_call_id": "call_first", "content": "First result"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "call_second", "type": "function", "function": ["name": "nested_tool", "arguments": "{\"tasks\":[]}"]]]],
            ["role": "tool", "tool_call_id": "call_second", "content": "Second result"]
        ]
        let archive = try JSONSerialization.data(withJSONObject: ["thinkingByToolCallID": [
            "call_first": [["type": "thinking", "thinking": "First reasoning", "signature": "signature-first"]],
            "call_second": [["type": "redacted_thinking", "data": "redacted-second"]]
        ]])
        let request = try NativeWireCodec.request(protocol: .anthropicMessages, baseURL: "https://api.anthropic.com",
            appendV1: true, apiKey: "fixture", modelID: "claude-opus-4-8", messagesJSON: JSONSerialization.data(withJSONObject: rows),
            toolsJSON: tools, maxTokens: 4096, thinking: "high", supportsReasoning: true, effortValues: ["high"], continuationJSON: archive)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let assistants = (body["messages"] as! [[String: Any]]).filter { $0["role"] as? String == "assistant" }
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual((assistants[0]["content"] as? [[String: Any]])?.first?["signature"] as? String, "signature-first")
        XCTAssertEqual((assistants[1]["content"] as? [[String: Any]])?.first?["data"] as? String, "redacted-second")
    }

    func testAnthropicSDKCollectsStreamingSignatureAndToolIdentity() throws {
        let decoder = NativeStreamDecoder(protocol: .anthropicMessages)
        let rows: [[String: Any]] = [
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Signed reasoning"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sdk-signature-fixture"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "sdk_call", "name": "nested_tool", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"tasks\":[]}"]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use", "stop_sequence": NSNull()], "usage": ["output_tokens": 20]],
            ["type": "message_stop"]
        ]
        var events: [NativeDecodedEvent] = []
        for row in rows {
            let data = try JSONSerialization.data(withJSONObject: row)
            events += try decoder.parseLine("data: " + String(decoding: data, as: UTF8.self))
        }
        let metadata = events.compactMap { if case .metadata(let d) = $0 { return d }; return nil }.first!
        let object = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
        XCTAssertEqual((object["thinkingBlocks"] as? [[String: Any]])?.first?["signature"] as? String, "sdk-signature-fixture")
        XCTAssertEqual(object["toolCallIDs"] as? [String], ["sdk_call"])
        XCTAssertTrue(decoder.isCompleted)
    }

    func testAnthropicInitialToolInputPreservesNestedCamelCaseKeys() throws {
        let decoder = NativeStreamDecoder(protocol: .anthropicMessages)
        let row: [String: Any] = ["type": "content_block_start", "index": 0,
            "content_block": ["type": "tool_use", "id": "inline_call", "name": "nested_tool", "input": ["camelCaseArg": [["nestedValue": 3]]]]]
        let data = try JSONSerialization.data(withJSONObject: row)
        let events = try decoder.parseLine("data: " + String(decoding: data, as: UTF8.self))
        let arguments = events.compactMap { if case .tool(_, _, _, let args) = $0 { return args }; return nil }.first!
        let input = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as! [String: Any]
        XCTAssertEqual((input["camelCaseArg"] as? [[String: Int]])?.first?["nestedValue"], 3)
    }

    func testGeminiSignatureColdReplayIntoFunctionCall() throws {
        let decoder = NativeStreamDecoder(protocol: .geminiNative)
        let events = try decoder.parseLine("data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"nested_tool\",\"args\":{\"tasks\":[]}},\"thoughtSignature\":\"opaque-signature\"}]},\"finishReason\":\"STOP\"}]}")
        let metadata = events.compactMap { if case .metadata(let d) = $0 { return d }; return nil }.first!
        let id = events.compactMap { if case .tool(_, let id, _, _) = $0 { return id }; return nil }.first!
        let rows: [[String: Any]] = [
            ["role": "user", "content": "Read"],
            ["role": "assistant", "content": "", "tool_calls": [["id": id, "type": "function", "function": ["name": "nested_tool", "arguments": "{\"tasks\":[]}"]]]],
            ["role": "tool", "tool_call_id": id, "content": "Result"]
        ]
        let request = try NativeWireCodec.request(protocol: .geminiNative, baseURL: "https://generativelanguage.googleapis.com/v1beta",
            appendV1: false, apiKey: "fixture", modelID: "gemini-3-flash-preview", messagesJSON: JSONSerialization.data(withJSONObject: rows),
            toolsJSON: tools, maxTokens: 4096, thinking: "minimal", supportsReasoning: true, effortValues: ["minimal"], continuationJSON: metadata)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let parts = (body["contents"] as! [[String: Any]]).flatMap { $0["parts"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(parts.first(where: { $0["functionCall"] != nil })?["thoughtSignature"] as? String, "opaque-signature")
    }
}
