import XCTest
import SQLite3
@testable import Limare

private final class UsageMockState: @unchecked Sendable {
    enum Mode { case fallback, generic, quota, quotaAccountDenied, quotaKeyDenied, quotaBothDenied, quotaTooLarge, quotaTimeout, quotaDelayed, quotaRedirect, interrupted, emptyUsage, retry, retryUsage, hold, streamErrorUsage, geminiSafetyUsage, script }
    private let lock = NSLock()
    private var mode: Mode = .fallback
    private var captured: [URLRequest] = []
    private var capturedBodies: [Data] = []
    private var responder: (@Sendable (URLRequest, Data?) -> (Int, Data))?
    func reset(_ mode: Mode) { lock.withLock { self.mode = mode; self.responder = nil; captured = []; capturedBodies = [] } }
    func reset(_ mode: Mode, responder: @escaping @Sendable (URLRequest, Data?) -> (Int, Data)) {
        lock.withLock { self.mode = mode; self.responder = responder; captured = []; capturedBodies = [] }
    }
    func capturedRequestList() -> [URLRequest] { lock.withLock { captured } }
    func lastCapturedBody() -> Data? { lock.withLock { capturedBodies.last } }
    func capturedBodyCount() -> Int { lock.withLock { capturedBodies.count } }
    func scriptedResponse(for request: URLRequest, body: Data?) -> (Int, Data)? {
        let handler = lock.withLock { mode == .script ? responder : nil }
        return handler?(request, body)
    }
    static func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 { data.append(buffer, count: count) } else { break }
        }
        return data.isEmpty ? nil : data
    }
    var requests: [URLRequest] { lock.withLock { captured } }
    var bodies: [Data] { lock.withLock { capturedBodies } }
    var isHolding: Bool { lock.withLock { mode == .hold } }
    var isDelayed: Bool { lock.withLock { mode == .quotaDelayed } }
    var isTimeout: Bool { lock.withLock { mode == .quotaTimeout } }
    func response(_ request: URLRequest) -> (Int, Data) {
        lock.withLock {
            captured.append(request)
            if let body = request.httpBody { capturedBodies.append(body) }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
                }
                capturedBodies.append(data)
            } else { capturedBodies.append(Data()) }
            let index = captured.count
            let path = request.url?.path ?? ""
            switch mode {
            case .fallback where index == 1:
                return (400, Data(#"{"error":{"message":"Unsupported parameter: include_usage"}}"#.utf8))
            case .generic:
                return (400, Data(#"{"error":{"message":"Bad request"}}"#.utf8))
            case .interrupted:
                return (200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}],\"usage\":{\"prompt_tokens\":11}}\n\ndata: {\"error\":{\"type\":\"invalid_request_error\",\"message\":\"broken\"}}\n\n".utf8))
            case .emptyUsage:
                return (200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
            case .retry where index == 1:
                return (503, Data(#"{"error":{"message":"unavailable"}}"#.utf8))
            case .retryUsage where index == 1:
                return (200, Data("data: {\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":2}}\n\ndata: {\"error\":{\"type\":\"overloaded_error\",\"message\":\"unavailable\"}}\n\n".utf8))
            case .quotaTooLarge:
                return (200, Data(repeating: 0x20, count: 1_048_577))
            case .quota, .quotaAccountDenied, .quotaKeyDenied, .quotaBothDenied, .quotaTimeout, .quotaDelayed:
                if path == "/api/v1/key" {
                    if mode == .quotaKeyDenied || mode == .quotaBothDenied { return (403, Data()) }
                    return (200, Data(#"{"data":{"usage":12.5,"limit":null,"limit_remaining":null}}"#.utf8))
                }
                if mode == .quotaAccountDenied || mode == .quotaBothDenied { return (403, Data()) }
                return (200, Data(#"{"data":{"total_credits":30,"total_usage":8}}"#.utf8))
            case .quotaRedirect:
                return (302, Data())
            case .streamErrorUsage:
                let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\ndata: {\"error\":{\"code\":\"server_error\",\"message\":\"upstream boom\"},\"usage\":{\"prompt_tokens\":60,\"completion_tokens\":5,\"total_tokens\":65}}\n\n"
                return (200, Data(sse.utf8))
            case .geminiSafetyUsage:
                let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hi\"}]},\"finishReason\":\"SAFETY\"}],\"usageMetadata\":{\"promptTokenCount\":42,\"candidatesTokenCount\":7,\"totalTokenCount\":49}}\n\n"
                return (200, Data(sse.utf8))
            case .script:
                return (200, Data())
            default:
                let body = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":50,\"total_tokens\":151}}\n\ndata: [DONE]\n\n"
                return (200, Data(body.utf8))
            }
        }
    }
}

private final class UsageMockProtocol: URLProtocol, @unchecked Sendable {
    static let state = UsageMockState()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let prevBodyCount = Self.state.capturedBodyCount()
        var (status, data) = Self.state.response(request)
        let capturedBody = Self.state.capturedBodyCount() > prevBodyCount ? Self.state.lastCapturedBody() : UsageMockState.requestBody(from: request)
        if let overridden = Self.state.scriptedResponse(for: request, body: capturedBody) {
            (status, data) = overridden
        }
        if Self.state.isHolding { return }
        if Self.state.isTimeout { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        if status == 302,
           let url = request.url,
           let redirectURL = URL(string: "https://evil.example.test/steal"),
           let redirectResponse = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirectURL.absoluteString]) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: redirectResponse)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [self] in
                guard !lock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if Self.state.isDelayed {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                guard !lock.withLock({ stopped }) else { return }
                send(status: status, data: data)
            }
            return
        }
        send(status: status, data: data)
    }
    private func send(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

@MainActor
final class ProviderUsageTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageMockProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("limare-usage-tests-\(UUID().uuidString)") }

    func testStreamingRequestDefaultsAndOldConfiguration() throws {
        var provider = ProviderConfiguration(name: "Gateway", baseURL: "https://gateway.example/v1")
        let oldData = try JSONEncoder().encode(provider)
        var oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        oldObject.removeValue(forKey: "requestStreamUsage")
        provider = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: oldObject))
        func includesUsage(_ p: ProviderConfiguration) throws -> Bool {
            let payload = try OpenAIChatRequestBuilder.buildPayload(provider: p, modelID: "m", messages: [ChatRequestMessage(role: "user", content: "Hi")])
            return (payload["stream_options"] as? [String: Bool])?["include_usage"] == true
        }
        XCTAssertTrue(try includesUsage(provider))
        provider.requestStreamUsage = false
        let reloaded = try JSONDecoder().decode(ProviderConfiguration.self, from: JSONEncoder().encode(provider))
        XCTAssertFalse(try includesUsage(reloaded))
        XCTAssertTrue(OpenAICompatibleClient.rejectsStreamUsage(status: 422, message: "Unknown field stream_options"))
        XCTAssertFalse(OpenAICompatibleClient.rejectsStreamUsage(status: 400, message: "Bad request"))
        XCTAssertFalse(OpenAICompatibleClient.rejectsStreamUsage(status: 400, message: #"{"error":{"message":"Invalid API key"},"request":{"stream_options":{"include_usage":true}}}"#))
        XCTAssertTrue(OpenAICompatibleClient.rejectsStreamUsage(status: 422, message: #"{"detail":[{"loc":["body","stream_options"],"msg":"Extra inputs are not permitted"}]}"#))
        let state = StreamUsageCompatibility()
        let generation = state.generation(provider.id)
        state.invalidate(provider.id)
        state.markRejected(provider, generation: generation)
        XCTAssertFalse(state.isRejected(provider))
    }

    func testParsersAndProtocolNormalization() throws {
        var chat = OpenAIStreamParser()
        _ = try chat.parseLine(#"data: {"choices":[{"delta":{"content":"x"},"finish_reason":"stop"}]}"#)
        _ = try chat.parseLine(#"data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":151,"prompt_tokens_details":{"cached_tokens":0,"cache_write_tokens":10},"prompt_cache_hit_tokens":20,"completion_tokens_details":{"reasoning_tokens":7}}}"#)
        let raw = try XCTUnwrap(chat.diagnostics.usage)
        XCTAssertEqual(raw.cacheReadTokens, 20)
        let normalized = NormalizedUsage.from(raw, format: .chatCompletions, finished: true)
        XCTAssertEqual(normalized.input, 100); XCTAssertEqual(normalized.output, 50)
        XCTAssertEqual(normalized.providerTotal, 151); XCTAssertEqual(normalized.cacheWrite, 10)
        XCTAssertEqual(normalized.reasoning, 7); XCTAssertEqual(normalized.status, .complete)

        var responses = OpenAIResponsesStreamParser(providerID: UUID(), modelID: "m")
        _ = try responses.parseLine(#"data: {"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":20}}}"#)
        _ = try responses.parseLine(#"data: {"usage":{"output_tokens":50,"total_tokens":150,"output_tokens_details":{"reasoning_tokens":7}}}"#)
        let responseUsage = NormalizedUsage.from(responses.diagnostics.usage, format: .responses, finished: true)
        XCTAssertEqual(responseUsage.input, 100); XCTAssertEqual(responseUsage.output, 50)
        XCTAssertEqual(responseUsage.cacheRead, 20); XCTAssertEqual(responseUsage.reasoning, 7)

        let anthropicRaw = ProviderUsageTelemetry(inputTokens: 0, outputTokens: 1, cacheReadTokens: 100)
            .merged(with: ProviderUsageTelemetry(outputTokens: 50))
            .merged(with: ProviderUsageTelemetry(outputTokens: nil))
        XCTAssertEqual(anthropicRaw.withContextInput(for: .anthropicMessages).contextInputTokens, 100)
        let anthropic = NormalizedUsage.from(anthropicRaw, format: .anthropicMessages, finished: true)
        XCTAssertEqual(anthropic.input, 100); XCTAssertEqual(anthropic.output, 50)
        XCTAssertEqual(NormalizedUsage.from(anthropicRaw, format: .anthropicMessages, finished: false).status, .partial)

        // §7.3 Normalization table edge cases & 3-frame output=1 -> nil -> 50 parser merges
        var responsesParser = OpenAIResponsesStreamParser(providerID: UUID(), modelID: "gpt-test")
        _ = try responsesParser.parseLine("data: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\",\"usage\":{\"input_tokens\":100,\"output_tokens\":1}}}")
        _ = try responsesParser.parseLine("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}")
        _ = try responsesParser.parseLine("data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":100,\"input_tokens_details\":{\"cached_tokens\":20},\"output_tokens\":50,\"output_tokens_details\":{\"reasoning_tokens\":10},\"total_tokens\":150}}}")
        let responsesNorm = NormalizedUsage.from(responsesParser.diagnostics.usage, format: .responses, finished: true)
        XCTAssertEqual(responsesNorm.input, 100); XCTAssertEqual(responsesNorm.output, 50)
        XCTAssertEqual(responsesNorm.cacheRead, 20); XCTAssertEqual(responsesNorm.reasoning, 10)
        XCTAssertEqual(responsesParser.diagnostics.usage?.totalTokens, 150); XCTAssertEqual(responsesNorm.status, .complete)

        var chatParser = OpenAIStreamParser()
        _ = try chatParser.parseLine("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":1}}")
        _ = try chatParser.parseLine("data: {\"choices\":[{\"delta\":{\"content\":\"!\"}}]}")
        _ = try chatParser.parseLine("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":100,\"prompt_tokens_details\":{\"cached_tokens\":20},\"completion_tokens\":50,\"completion_tokens_details\":{\"reasoning_tokens\":10},\"total_tokens\":151}}")
        let chatNorm = NormalizedUsage.from(chatParser.diagnostics.usage, format: .chatCompletions, finished: true)
        XCTAssertEqual(chatNorm.input, 100); XCTAssertEqual(chatNorm.output, 50)
        XCTAssertEqual(chatNorm.cacheRead, 20); XCTAssertEqual(chatNorm.reasoning, 10)
        XCTAssertEqual(chatParser.diagnostics.usage?.totalTokens, 151); XCTAssertEqual(chatNorm.status, .complete)

        let chatMinimal = NormalizedUsage.from(ProviderUsageTelemetry(inputTokens: 100, outputTokens: 50), format: .chatCompletions, finished: true)
        XCTAssertEqual(chatMinimal.status, .complete); XCTAssertNil(chatMinimal.cacheRead); XCTAssertNil(chatMinimal.reasoning)

        let anthropicCacheSum = NormalizedUsage.from(
            ProviderUsageTelemetry(inputTokens: 10, outputTokens: 50, cacheReadTokens: 70, cacheWriteTokens: 20),
            format: .anthropicMessages,
            finished: true
        )
        XCTAssertEqual(anthropicCacheSum.input, 100); XCTAssertEqual(anthropicCacheSum.output, 50)
        XCTAssertEqual(anthropicCacheSum.cacheRead, 70); XCTAssertEqual(anthropicCacheSum.cacheWrite, 20)
        XCTAssertEqual(anthropicCacheSum.status, .complete)

        let anthropicNoCache = NormalizedUsage.from(ProviderUsageTelemetry(inputTokens: 100, outputTokens: 50), format: .anthropicMessages, finished: true)
        XCTAssertEqual(anthropicNoCache.status, .complete); XCTAssertNil(anthropicNoCache.cacheRead); XCTAssertNil(anthropicNoCache.cacheWrite)

        var errorParser = OpenAIStreamParser()
        XCTAssertThrowsError(try errorParser.parseLine("data: {\"error\":{\"code\":\"server_error\",\"message\":\"boom\"},\"usage\":{\"prompt_tokens\":60,\"completion_tokens\":5}}"))
        XCTAssertEqual(errorParser.diagnostics.usage?.inputTokens, 60)
        XCTAssertEqual(errorParser.diagnostics.usage?.outputTokens, 5)

        let geminiRaw = ProviderUsageTelemetry(inputTokens: 100, outputTokens: 40, totalTokens: 160,
            cacheReadTokens: 20, reasoningTokens: 10, toolUsePromptTokens: 10)
        let gemini = NormalizedUsage.from(geminiRaw, format: .geminiNative, finished: true)
        XCTAssertEqual(gemini.input, 110); XCTAssertEqual(gemini.output, 50); XCTAssertEqual(gemini.toolUsePrompt, 10)
        let geminiMinimal = NormalizedUsage.from(ProviderUsageTelemetry(inputTokens: 100, outputTokens: 50), format: .geminiNative, finished: true)
        XCTAssertEqual(geminiMinimal.status, .complete); XCTAssertNil(geminiMinimal.cacheRead); XCTAssertNil(geminiMinimal.reasoning); XCTAssertNil(geminiMinimal.toolUsePrompt)
        let defaultGemini = NormalizedUsage.from(ProviderUsageTelemetry(inputTokens: 100), format: .geminiNative, finished: true)
        XCTAssertEqual(defaultGemini.output, 0); XCTAssertEqual(defaultGemini.status, .complete)
        let onlyTotal = NormalizedUsage.from(ProviderUsageTelemetry(totalTokens: 150), format: .geminiNative, finished: true)
        XCTAssertEqual(onlyTotal.status, .partial); XCTAssertNil(onlyTotal.input); XCTAssertNil(onlyTotal.output)
        XCTAssertEqual(NormalizedUsage.from(nil, format: .geminiNative, finished: true).status, .unknown)
    }

    func testRecorderPersistenceAndFailureAreVisible() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let status = UsageRecordingStatus()
        let recorder = try UsageRecorder(storageRootURL: directory, status: status)
        let providerID = UUID()
        var row = UsageRequestRecord(providerID: providerID, providerName: "提供商 🐋", modelID: "模型", modelName: "中文模型", format: .chatCompletions, kind: .chat)
        row.attemptCount = 2
        row.addAttempt(ProviderUsageTelemetry(inputTokens: 3, outputTokens: 2, totalTokens: 9), finished: true, excluded: false)
        row.addAttempt(ProviderUsageTelemetry(inputTokens: 4, outputTokens: 1), finished: true, excluded: false)
        XCTAssertEqual(row.usage.input, 7); XCTAssertEqual(row.usage.output, 3); XCTAssertEqual(row.usage.providerTotal, 9)
        await recorder.append(row)
        let report = try await recorder.report(since: nil, kind: .chat)
        XCTAssertEqual(report.totals.requests, 1); XCTAssertEqual(report.totals.input, 7)
        XCTAssertEqual(report.groups.first?.provider, "提供商 🐋"); XCTAssertEqual(report.groups.first?.model, "中文模型")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        let database = directory.appendingPathComponent("usage.sqlite3").path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: database)[.posixPermissions] as? Int, 0o600)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database, &db), SQLITE_OK)
        var pragma: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &pragma, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(pragma), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(pragma, 0)), "wal")
        sqlite3_finalize(pragma)
        let dbPath = sqlite3_db_filename(db, "main").map { String(cString: $0) }
        var sqlStmt: OpaquePointer?
        var savedCreateSQL = ""
        if sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='usage_request'", -1, &sqlStmt, nil) == SQLITE_OK {
            if sqlite3_step(sqlStmt) == SQLITE_ROW, let txt = sqlite3_column_text(sqlStmt, 0) {
                savedCreateSQL = String(cString: txt)
            }
            sqlite3_finalize(sqlStmt)
        }
        XCTAssertFalse(savedCreateSQL.isEmpty)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE usage_request", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        await recorder.append(row)
        XCTAssertNotNil(status.failure)
        do { _ = try await recorder.report(since: nil, kind: nil); XCTFail("Query should fail") } catch {}

        var recoveredDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(try XCTUnwrap(dbPath), &recoveredDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(recoveredDB, savedCreateSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(recoveredDB)
        await recorder.append(row)
        XCTAssertNil(status.failure)
        let recoveredReport = try await recorder.report(since: nil, kind: nil)
        XCTAssertGreaterThanOrEqual(recoveredReport.totals.requests, 1)
    }

    func testInitializationFailureDoesNotStopAppState() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("usage.sqlite3"), withIntermediateDirectories: true)
        let state = AppState(storageRootURL: directory)
        XCTAssertNil(state.usageRecorder)
        XCTAssertNotNil(state.usageRecordingStatus.failure)
        XCTAssertNotNil(state.providers.networkClient as OpenAICompatibleClient?)
    }

    func testTwoRecordersCanShareWALDatabase() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let firstStatus = UsageRecordingStatus(); let secondStatus = UsageRecordingStatus()
        let first = try UsageRecorder(storageRootURL: directory, status: firstStatus)
        let second = try UsageRecorder(storageRootURL: directory, status: secondStatus)
        let providerID = UUID()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    var row = UsageRequestRecord(providerID: providerID, providerName: "Shared", modelID: "m", modelName: "M", format: .chatCompletions, kind: .chat)
                    row.attemptCount = 1
                    row.addAttempt(ProviderUsageTelemetry(inputTokens: 1, outputTokens: 1), finished: true, excluded: false)
                    await (i.isMultiple(of: 2) ? first : second).append(row)
                }
            }
        }
        let report = try await first.report(since: nil, kind: nil)
        XCTAssertEqual(report.totals.requests, 20)
        XCTAssertEqual(report.totals.input, 20)
        XCTAssertNil(firstStatus.failure); XCTAssertNil(secondStatus.failure)
    }

    func testOutcomesAndMissingAttemptsAreDistinct() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let status = UsageRecordingStatus()
        let recorder = try UsageRecorder(storageRootURL: directory, status: status)
        let client = OpenAICompatibleClient(session: session()).recordingUsage(recorder)
        let provider = ProviderConfiguration(name: "Mock", baseURL: "https://example.test/v1")
        let message = [ChatRequestMessage(role: "user", content: "Hi")]
        UsageMockProtocol.state.reset(.emptyUsage)
        for try await _ in client.streamChat(provider: provider, apiKey: "x", modelID: "m", messages: message) {}
        UsageMockProtocol.state.reset(.interrupted)
        do {
            for try await _ in client.streamChat(provider: provider, apiKey: "x", modelID: "m", messages: message) {}
            XCTFail("Expected stream error")
        } catch {}
        UsageMockProtocol.state.reset(.retry)
        for try await _ in client.streamChat(provider: provider, apiKey: "x", modelID: "m", messages: message) {}
        UsageMockProtocol.state.reset(.retryUsage)
        for try await _ in client.streamChat(provider: provider, apiKey: "x", modelID: "m", messages: message) {}

        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT outcome, usage_status, attempt_count, attempts_without_usage, input_total FROM usage_request ORDER BY started_at", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let expected: [(String, String, Int32, Int32)] = [("completed", "unknown", 1, 1), ("failed", "partial", 1, 0), ("completed", "partial", 2, 1), ("completed", "partial", 2, 0)]
        for row in expected {
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), row.0)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), row.1)
            XCTAssertEqual(sqlite3_column_int(statement, 2), row.2)
            XCTAssertEqual(sqlite3_column_int(statement, 3), row.3)
        }
        XCTAssertEqual(sqlite3_column_int(statement, 4), 111)
    }

    func testStreamFallbackIsRememberedAndRecordedOnce() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let status = UsageRecordingStatus()
        let recorder = try UsageRecorder(storageRootURL: directory, status: status)
        UsageMockProtocol.state.reset(.fallback)
        let provider = ProviderConfiguration(name: "测试提供商", baseURL: "https://example.test/v1", models: [ProviderModel(id: "m", displayName: "模型名称")])
        let client = OpenAICompatibleClient(session: session()).recordingUsage(recorder)
        for _ in 0..<2 {
            for try await _ in client.streamChat(provider: provider, apiKey: "fixture", modelID: "m", messages: [ChatRequestMessage(role: "user", content: "Hi")], options: ChatInferenceOptions(usageKind: .title)) {}
        }
        let requests = UsageMockProtocol.state.requests
        XCTAssertEqual(requests.count, 3)
        func hasOption(_ data: Data) -> Bool {
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return body["stream_options"] != nil
        }
        let bodies = UsageMockProtocol.state.bodies
        XCTAssertTrue(hasOption(bodies[0])); XCTAssertFalse(hasOption(bodies[1])); XCTAssertFalse(hasOption(bodies[2]))
        XCTAssertTrue(client.streamUsageWasRejected(provider))
        let report = try await recorder.report(since: nil, kind: .title)
        XCTAssertEqual(report.totals.requests, 2); XCTAssertEqual(report.totals.input, 200)
        XCTAssertEqual(report.groups.first?.model, "模型名称")
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT attempt_count, attempts_without_usage, usage_status, provider_total FROM usage_request ORDER BY started_at LIMIT 1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2); XCTAssertEqual(sqlite3_column_int(statement, 1), 0)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 2)), "complete")
        XCTAssertEqual(sqlite3_column_int(statement, 3), 151)
        var changed = provider
        changed.baseURL = "https://another.example/v1"
        XCTAssertFalse(client.streamUsageWasRejected(changed))
        client.invalidateStreamUsageCompatibility(provider.id)
        XCTAssertFalse(client.streamUsageWasRejected(provider))
    }

    func testGenericBadRequestDoesNotRetry() async throws {
        UsageMockProtocol.state.reset(.generic)
        let provider = ProviderConfiguration(name: "Gateway", baseURL: "https://example.test/v1")
        let client = OpenAICompatibleClient(session: session())
        do {
            for try await _ in client.streamChat(provider: provider, apiKey: "fixture", modelID: "m", messages: [ChatRequestMessage(role: "user", content: "Hi")]) {}
            XCTFail("Expected failure")
        } catch {}
        XCTAssertEqual(UsageMockProtocol.state.requests.count, 1)
        XCTAssertFalse(client.streamUsageWasRejected(provider))
    }

    func testCancelledCallIsRecordedWithoutBlockingChat() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let status = UsageRecordingStatus()
        let recorder = try UsageRecorder(storageRootURL: directory, status: status)
        let client = OpenAICompatibleClient(session: session()).recordingUsage(recorder)
        let provider = ProviderConfiguration(name: "Mock", baseURL: "https://example.test/v1")
        let cancellation = ProviderStreamCancellationHandle()
        UsageMockProtocol.state.reset(.hold)
        let consumer = Task {
            do {
                for try await _ in client.streamChat(provider: provider, apiKey: "x", modelID: "m",
                    messages: [ChatRequestMessage(role: "user", content: "Hi")], cancellationHandle: cancellation) {}
            } catch {}
        }
        for _ in 0..<100 where UsageMockProtocol.state.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(UsageMockProtocol.state.requests.count, 1)
        cancellation.cancel()
        await consumer.value
        let report = try await recorder.report(since: nil, kind: nil)
        XCTAssertEqual(report.totals.requests, 1)
        XCTAssertTrue(report.totals.incomplete)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("usage.sqlite3").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT outcome, usage_status FROM usage_request", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "cancelled")
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "unknown")
    }

    func testQuotaConcurrentRefreshAndInvalidation() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderStore(storageRootURL: directory, logs: DebugLogStore(storageRootURL: directory))
        let provider = ProviderConfiguration(name: "Router", baseURL: "https://openrouter.ai/api/v1")
        try store.save(provider, apiKey: "old-fixture")
        let quota = ProviderQuotaService(providers: store, session: session())
        store.onQuotaInvalidated = { [weak quota] in quota?.invalidate(providerID: $0) }
        UsageMockProtocol.state.reset(.quotaDelayed)
        async let first: Void = quota.refresh(provider, force: true)
        async let second: Void = quota.refresh(provider, force: true)
        _ = await (first, second)
        XCTAssertEqual(UsageMockProtocol.state.requests.count, 2)
        XCTAssertNotNil(quota.state(for: provider.id).account)

        UsageMockProtocol.state.reset(.quotaDelayed)
        let old = Task { await quota.refresh(provider, force: true) }
        for _ in 0..<100 where UsageMockProtocol.state.requests.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try store.save(provider, apiKey: "new-fixture")
        await quota.refresh(provider, force: true)
        await old.value
        let headers = UsageMockProtocol.state.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
        XCTAssertEqual(headers.filter { $0 == "Bearer old-fixture" }.count, 2)
        XCTAssertEqual(headers.filter { $0 == "Bearer new-fixture" }.count, 2)
        XCTAssertEqual(quota.state(for: provider.id).account?.amounts.first?.value, 22)
        XCTAssertNil(quota.state(for: provider.id).accountError)
    }

    func testQuotaPathsParsingCredentialsAndStaleData() async throws {
        for path in ["", "/v1", "/api/", "/coding"] {
            let provider = ProviderConfiguration(name: "D", baseURL: "https://api.deepseek.com:8443\(path)?q=1#fragment")
            XCTAssertEqual(ProviderQuotaService.endpoint(provider, path: "/user/balance")?.absoluteString, "https://api.deepseek.com:8443/user/balance")
        }
        let fake = ProviderConfiguration(name: "D", baseURL: "https://api.deepseek.com.evil.test/v1")
        XCTAssertEqual(ProviderQuotaService.kind(fake), .relay)
        XCTAssertEqual(ProviderQuotaService.endpoint(fake, path: "/api/usage/token")?.absoluteString, "https://api.deepseek.com.evil.test/api/usage/token")
        let officialOpenAI = ProviderConfiguration(name: "OpenAI", baseURL: "https://api.openai.com/v1")
        XCTAssertNil(ProviderQuotaService.kind(officialOpenAI))
        let oauthOpenAI = ProviderConfiguration(
            name: "OpenAI",
            baseURL: "https://api.openai.com",
            apiFormat: .responses,
            providerIdentity: .openAI,
            authenticationSelection: .legacy(.oauth)
        )
        XCTAssertEqual(ProviderQuotaService.kind(oauthOpenAI), .codexSubscription)
        XCTAssertEqual(ProviderQuotaService.endpoint(oauthOpenAI, path: "/backend-api/wham/usage")?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        let codexQuota = try ProviderQuotaService.parse([
            "plan_type": "plus",
            "rate_limit": [
                "allowed": true,
                "limit_reached": false,
                "primary_window": ["used_percent": 9, "limit_window_seconds": 18000, "reset_after_seconds": 14716, "reset_at": 1794631183],
                "secondary_window": ["used_percent": 35, "limit_window_seconds": 604800, "reset_after_seconds": 433714, "reset_at": 1795050181],
            ],
        ], parser: .codexUsage)
        XCTAssertEqual(codexQuota.amounts[0].text, "ChatGPT Plus")
        XCTAssertEqual(codexQuota.amounts[1].value, 91)
        XCTAssertEqual(codexQuota.amounts[1].currency, "%")
        XCTAssertEqual(codexQuota.amounts[1].usedFraction ?? -1, 0.09, accuracy: 0.0001)
        XCTAssertNotNil(codexQuota.amounts[1].subtitle)
        XCTAssertEqual(codexQuota.amounts[2].value, 65)
        XCTAssertEqual(codexQuota.amounts[2].currency, "%")
        XCTAssertEqual(codexQuota.amounts[2].usedFraction ?? -1, 0.35, accuracy: 0.0001)
        XCTAssertFalse(codexQuota.insufficient)
        let codexLimited = try ProviderQuotaService.parse([
            "plan_type": "pro",
            "rate_limit": ["allowed": false, "limit_reached": true, "primary_window": ["used_percent": 100, "limit_window_seconds": 18000]],
            "additional_rate_limits": [["limit_name": "GPT-5.3-Codex-Spark", "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]]]],
            "credits": ["has_credits": true, "unlimited": false, "balance": "12.5"],
        ], parser: .codexUsage)
        XCTAssertTrue(codexLimited.insufficient)
        XCTAssertEqual(codexLimited.amounts.last?.value, Decimal(string: "12.5"))
        XCTAssertEqual(codexLimited.amounts.last?.currency, "credits")
        let newAPIToken = try ProviderQuotaService.parse([
            "code": true,
            "data": ["name": "limare", "total_available": -22055344, "total_granted": 0, "total_used": 22055344, "unlimited_quota": true]
        ], parser: .newAPIToken)
        XCTAssertEqual(newAPIToken.amounts.first?.value, Decimal(string: "22055344"))
        XCTAssertEqual(newAPIToken.amounts.last?.unlimited, true)
        let billing = try ProviderQuotaService.parse(
            ["hard_limit_usd": 182.59],
            parser: .openAIBilling(usage: ["total_usage": 12461.9378])
        )
        XCTAssertEqual(billing.amounts.first?.value, Decimal(string: "57.97"))
        XCTAssertEqual(billing.amounts[1].value, Decimal(string: "182.59"))
        XCTAssertEqual(billing.amounts[2].value, Decimal(string: "124.62"))
        let sub2 = try ProviderQuotaService.parse(
            ["isValid": true, "mode": "quota_limited", "quota": ["limit": 50, "remaining": 32.5, "used": 17.5]],
            parser: .sub2api
        )
        XCTAssertEqual(sub2.amounts.first?.value, Decimal(string: "32.5"))
        for (base, path) in [("https://api.moonshot.cn/coding", "/v1/users/me/balance"),
                             ("https://api.moonshot.ai/v1/", "/v1/users/me/balance"),
                             ("https://openrouter.ai/v1", "/api/v1/key"),
                             ("https://openrouter.ai/api", "/api/v1/credits")] {
            let provider = ProviderConfiguration(name: "Fixture", baseURL: base, apiFormat: .anthropicMessages)
            let url = try XCTUnwrap(ProviderQuotaService.endpoint(provider, path: path))
            XCTAssertEqual(url.path, path)
            var request = URLRequest(url: url)
            ProviderRequestConfigurator.configureBearerHeaders(request: &request, provider: provider, apiKey: "fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        }
        XCTAssertFalse(TransportMetricsRecorder.sameOrigin(URL(string: "https://openrouter.ai/x"), URL(string: "https://evil.test/x")))
        XCTAssertTrue(TransportMetricsRecorder.sameOrigin(URL(string: "https://openrouter.ai/x"), URL(string: "https://openrouter.ai:443/y")))
        let deep = try ProviderQuotaService.parse(["is_available": false, "balance_infos": [["currency": "CNY", "total_balance": "12.30", "granted_balance": "2", "topped_up_balance": "10.30"]]], parser: .deepSeek)
        XCTAssertEqual(deep.amounts.first?.value, Decimal(string: "12.30")); XCTAssertTrue(deep.insufficient)
        XCTAssertThrowsError(try ProviderQuotaService.parse(["code": 1, "data": [:]], parser: .moonshot))

        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProviderStore(storageRootURL: directory, logs: DebugLogStore(storageRootURL: directory))
        let provider = ProviderConfiguration(name: "Router", baseURL: "https://openrouter.ai/api/v1")
        try store.save(provider, apiKey: "inference-fixture")
        try store.saveManagementKey("management-fixture", providerID: provider.id)
        let quota = ProviderQuotaService(providers: store, session: session())
        store.onQuotaInvalidated = { [weak quota] in quota?.invalidate(providerID: $0) }
        UsageMockProtocol.state.reset(.quota)
        await quota.refresh(provider)
        let requests = UsageMockProtocol.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/api/v1/key" })?.value(forHTTPHeaderField: "Authorization"), "Bearer inference-fixture")
        XCTAssertEqual(requests.first(where: { $0.url?.path == "/api/v1/credits" })?.value(forHTTPHeaderField: "Authorization"), "Bearer management-fixture")
        XCTAssertEqual(quota.state(for: provider.id).account?.amounts.first?.value, 22)
        XCTAssertEqual(quota.state(for: provider.id).key?.amounts[1].unlimited, true)
        let missingLimit = try ProviderQuotaService.parse(["data": ["usage": 4]], parser: .routerKey)
        XCTAssertNil(missingLimit.amounts[1].value); XCTAssertFalse(missingLimit.amounts[1].unlimited)
        let finiteLimit = try ProviderQuotaService.parse(["data": ["usage": 4, "limit": 10, "limit_remaining": 6]], parser: .routerKey)
        XCTAssertEqual(finiteLimit.amounts[1].value, 10); XCTAssertEqual(finiteLimit.amounts[2].value, 6)
        UsageMockProtocol.state.reset(.quotaAccountDenied)
        await quota.refresh(provider, force: true)
        XCTAssertEqual(quota.state(for: provider.id).account?.amounts.first?.value, 22)
        XCTAssertNotNil(quota.state(for: provider.id).accountError)
        XCTAssertTrue(quota.state(for: provider.id).accountPermissionDenied)
        XCTAssertNil(quota.state(for: provider.id).keyError)
        UsageMockProtocol.state.reset(.quotaKeyDenied)
        quota.invalidate(providerID: provider.id)
        await quota.refresh(provider, force: true)
        XCTAssertNotNil(quota.state(for: provider.id).account)
        XCTAssertNotNil(quota.state(for: provider.id).keyError)
        XCTAssertNil(quota.state(for: provider.id).key)
        UsageMockProtocol.state.reset(.quotaBothDenied)
        quota.invalidate(providerID: provider.id)
        await quota.refresh(provider, force: true)
        XCTAssertNotNil(quota.state(for: provider.id).accountError)
        XCTAssertNotNil(quota.state(for: provider.id).keyError)
        UsageMockProtocol.state.reset(.quotaTooLarge)
        quota.invalidate(providerID: provider.id)
        await quota.refresh(provider, force: true)
        XCTAssertNotNil(quota.state(for: provider.id).accountError)
        XCTAssertFalse(quota.state(for: provider.id).accountPermissionDenied)
        XCTAssertEqual(UsageMockProtocol.state.requests.count, 2)
        UsageMockProtocol.state.reset(.quotaTimeout)
        quota.invalidate(providerID: provider.id)
        await quota.refresh(provider, force: true)
        XCTAssertNotNil(quota.state(for: provider.id).accountError)
        XCTAssertEqual(UsageMockProtocol.state.requests.count, 2)
        try store.saveManagementKey("replacement-fixture", providerID: provider.id)
        XCTAssertEqual(try store.managementKey(providerID: provider.id), "replacement-fixture")
        XCTAssertEqual(try store.apiKey(providerID: provider.id), "inference-fixture")
        try store.deleteManagementKey(providerID: provider.id)
        XCTAssertNil(try store.managementKey(providerID: provider.id))
        XCTAssertNil(quota.state(for: provider.id).account)
        try store.saveManagementKey("management-fixture", providerID: provider.id)
        try store.delete(providerID: provider.id)
        XCTAssertNil(try store.managementKey(providerID: provider.id))

        let redirectProvider = ProviderConfiguration(
            name: "RedirectOR",
            baseURL: "https://mock.test/api",
            appendV1Suffix: false,
            providerIdentity: .openRouter
        )
        try store.save(redirectProvider, apiKey: "or-key")
        UsageMockProtocol.state.reset(.quotaRedirect)
        await quota.refresh(redirectProvider)
        XCTAssertNil(quota.state(for: redirectProvider.id).account)
        let redirectRequests = UsageMockProtocol.state.capturedRequestList()
        XCTAssertFalse(redirectRequests.isEmpty)
        XCTAssertTrue(redirectRequests.allSatisfy { $0.url?.host != "evil.example.test" })
        try? store.delete(providerID: redirectProvider.id)
    }

    func testErrorAndSafetyPartialUsageArePersisted() async throws {
        let storageRoot = root()
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let recorder = try UsageRecorder(storageRootURL: storageRoot, status: UsageRecordingStatus())
        let client = OpenAICompatibleClient(session: session()).recordingUsage(recorder)

        let chatProv = ProviderConfiguration(
            name: "ErrChat",
            baseURL: "https://mock.test",
            apiFormat: .chatCompletions
        )
        UsageMockProtocol.state.reset(.streamErrorUsage)
        do {
            for try await _ in client.streamChat(
                provider: chatProv,
                apiKey: "k1",
                modelID: "m1",
                messages: [ChatRequestMessage(role: "user", content: "hi")],
                options: ChatInferenceOptions(usageKind: .chat)
            ) {}
            XCTFail("Expected stream error")
        } catch {}
        let errReport = try await recorder.report(since: nil, kind: .chat)
        XCTAssertEqual(errReport.totals.requests, 1)
        XCTAssertEqual(errReport.totals.input, 60)
        XCTAssertEqual(errReport.totals.output, 5)
        XCTAssertTrue(errReport.totals.incomplete)

        let geminiProv = ProviderConfiguration(
            name: "SafeGemini",
            baseURL: "https://mock.test",
            appendV1Suffix: false,
            authenticationMode: .bearer,
            apiFormat: .geminiNative,
            providerIdentity: .gemini
        )
        UsageMockProtocol.state.reset(.geminiSafetyUsage)
        do {
            for try await _ in client.streamChat(
                provider: geminiProv,
                apiKey: "k2",
                modelID: "gemini-test",
                messages: [ChatRequestMessage(role: "user", content: "hi")],
                options: ChatInferenceOptions(usageKind: .other)
            ) {}
            XCTFail("Expected Gemini SAFETY error")
        } catch {}
        let safetyReport = try await recorder.report(since: nil, kind: .other)
        XCTAssertEqual(safetyReport.totals.requests, 1)
        XCTAssertEqual(safetyReport.totals.input, 42)
        XCTAssertEqual(safetyReport.totals.output, 7)
        XCTAssertTrue(safetyReport.totals.incomplete)
    }

    @MainActor
    func testServiceWiringRunClassificationCompactionCalibrationAndRetention() async throws {
        let storageRoot = root()
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }

        let appState = AppState(client: OpenAICompatibleClient(session: session()), storageRootURL: storageRoot)
        let recorder = try XCTUnwrap(appState.usageRecorder)

        let friendlyModel = ProviderModel(
            id: "friendly-id",
            displayName: "Friendly Model",
            baseModality: .vision,
            baseContextWindow: 200_000,
            baseMaxOutputTokens: 4096
        )
        let chatProvider = ProviderConfiguration(
            name: "Snapshot Provider",
            baseURL: "https://mock.test",
            appendV1Suffix: true,
            authenticationMode: .bearer,
            apiFormat: .chatCompletions,
            models: [friendlyModel],
            selectedModelID: "friendly-id",
            providerIdentity: .custom
        )
        try appState.providers.save(chatProvider, apiKey: "chat-key")

        let anthModel = ProviderModel(
            id: "claude-test",
            displayName: "Claude Cache",
            baseModality: .vision,
            baseContextWindow: 200_000,
            baseMaxOutputTokens: 4096
        )
        let anthProvider = ProviderConfiguration(
            name: "Anth Provider",
            baseURL: "https://anth.test",
            appendV1Suffix: false,
            authenticationMode: .bearer,
            apiFormat: .anthropicMessages,
            models: [anthModel],
            selectedModelID: "claude-test",
            providerIdentity: .anthropic
        )
        try appState.providers.save(anthProvider, apiKey: "anth-key")

        let entryID = ModelGroup.makeEntryId(providerID: chatProvider.id, modelID: "friendly-id")
        let chatGroup = ModelGroup(id: "grp-chat", name: "Chat Group", memberEntryIds: [entryID])
        let visionGroup = ModelGroup(id: "grp-vision", name: "Vision Group", memberEntryIds: [entryID])
        appState.modelGroups.addGroup(chatGroup)
        appState.modelGroups.addGroup(visionGroup)
        appState.modelGroups.visionGroupId = visionGroup.id
        appState.modelGroups.addRuntimeModelEntry(entryID)

        final class MaxTokenCapture: @unchecked Sendable {
            private let lock = NSLock()
            var directCompactMaxTokens: Int?
            func record(_ value: Int?) { lock.withLock { directCompactMaxTokens = value } }
        }
        let maxTokenCapture = MaxTokenCapture()

        UsageMockProtocol.state.reset(.script) { request, body in
            if request.url?.host == "anth.test" {
                let events: [String] = [
                    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":0,\"output_tokens\":1,\"cache_read_input_tokens\":100}}}",
                    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
                    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Anthropic ok\"}}",
                    "data: {\"type\":\"content_block_stop\",\"index\":0}",
                    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":9}}",
                    "data: {\"type\":\"message_stop\"}"
                ]
                return (200, Data((events.joined(separator: "\n\n") + "\n\n").utf8))
            }

            let bodyText = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if bodyText.contains("UNIQUE_DIRECT_COMPACT"),
               let body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                maxTokenCapture.record(json["max_tokens"] as? Int ?? json["max_completion_tokens"] as? Int)
            }

            let content: String
            let promptTokens: Int
            let completionTokens: Int
            if bodyText.contains("UNIQUE_PERMISSION_REQ") {
                content = "{\"decision\":\"approve\",\"rationale\":\"safe\"}"
                promptTokens = 12; completionTokens = 4
            } else if bodyText.contains("UNIQUE_TITLE_PROMPT") {
                content = "Mock Chat Title"
                promptTokens = 11; completionTokens = 3
            } else if bodyText.contains("UNIQUE_MODEL_TOOL") {
                content = "model-tool-ok"
                promptTokens = 13; completionTokens = 3
            } else if bodyText.contains("UNIQUE_VISION_PROMPT") {
                content = "vision-ok"
                promptTokens = 17; completionTokens = 5
            } else if bodyText.contains("UNIQUE_DIRECT_COMPACT") || bodyText.contains("UNIQUE_COORD_COMPACT") {
                content = "Compacted summary"
                promptTokens = 19; completionTokens = 6
            } else if bodyText.contains("UNIQUE_CALIBRATE_120") {
                content = "Calibrated 120"
                promptTokens = 120; completionTokens = 10
            } else {
                content = "OK"
                promptTokens = 30; completionTokens = 5
            }
            let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
            let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":\(promptTokens),\"completion_tokens\":\(completionTokens),\"total_tokens\":\(promptTokens + completionTokens)}}\n\ndata: [DONE]\n\n"
            return (200, Data(sse.utf8))
        }

        // 1. Service entries: title, modelTool, quickTest, vision, permissionReview, compaction
        let titleGen = ConversationTitleGenerator(
            resolver: SubModelResolver(modelGroups: appState.modelGroups, providers: appState.providers),
            providers: appState.providers,
            client: appState.providers.networkClient,
            logs: appState.logs
        )
        let titleConv = try appState.conversations.createBackgroundConversation(
            id: UUID(),
            projectID: nil,
            modelSource: .direct(providerID: chatProvider.id, modelID: "friendly-id"),
            messages: [
                ChatMessage(role: .user, content: "UNIQUE_TITLE_PROMPT"),
                ChatMessage(role: .assistant, content: "Answer")
            ]
        )
        let generatedTitle = await titleGen.generateTitle(for: titleConv)
        XCTAssertEqual(generatedTitle, "Mock Chat Title")

        let modelUse = RuntimeModelUseService(
            registry: appState.runtimeModelRegistry,
            providers: appState.providers,
            client: appState.providers.networkClient,
            logs: appState.logs
        )
        let modelUseResult = try await modelUse.run(
            entryID: entryID,
            prompt: "UNIQUE_MODEL_TOOL",
            systemPrompt: nil,
            maxTokens: nil
        )
        XCTAssertTrue(modelUseResult.content.contains("model-tool-ok"))

        let quickTest = ProviderQuickTestService(client: appState.providers.networkClient)
        let qtResult = await quickTest.runSingleTest(
            kind: .text,
            provider: chatProvider,
            model: friendlyModel,
            apiKey: "chat-key"
        )
        if case .passed = qtResult.status {} else { XCTFail("Expected quick test passed, got \(qtResult.status)") }

        let pngData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="))
        let visionText = try await appState.conversationRuns.visionGroupResolver.describe(
            imageData: pngData,
            mimeType: "image/png",
            customPrompt: "UNIQUE_VISION_PROMPT"
        )
        XCTAssertEqual(visionText.description, "vision-ok")

        let reviewer = AutoPermissionReviewer(
            context: PermissionReviewContext(provider: chatProvider, apiKey: "chat-key", modelID: "friendly-id"),
            client: appState.providers.networkClient,
            logs: appState.logs
        )
        let reviewDecision = await reviewer.review(
            request: ToolPermissionRequest(toolName: "shell", summary: "UNIQUE_PERMISSION_REQ", workspaceURL: storageRoot),
            reason: "network"
        )
        XCTAssertEqual(reviewDecision, .approve(rationale: "safe"))

        let compactTransport = DefaultSemanticCompactionTransport(client: appState.providers.networkClient, provider: chatProvider)
        let directCompactResp = try await compactTransport.executeCompaction(
            request: SemanticCompactorWireRequest(
                providerID: chatProvider.id.uuidString,
                modelID: "friendly-id",
                systemPrompt: "Summarize",
                userPrompt: "UNIQUE_DIRECT_COMPACT",
                maxOutputTokens: 777,
                apiKey: "chat-key",
                apiFormat: .chatCompletions
            ),
            cancellationHandle: nil
        )
        XCTAssertEqual(directCompactResp.text, "Compacted summary")
        XCTAssertEqual(maxTokenCapture.directCompactMaxTokens, 777)

        let compactConv = try appState.conversations.createBackgroundConversation(
            id: UUID(),
            projectID: nil,
            modelSource: .direct(providerID: chatProvider.id, modelID: "friendly-id"),
            messages: [
                ChatMessage(role: .user, content: "UNIQUE_COORD_COMPACT first"),
                ChatMessage(role: .assistant, content: "Reply one"),
                ChatMessage(role: .user, content: "Follow up"),
                ChatMessage(role: .assistant, content: "Reply two")
            ]
        )
        await appState.conversationRuns.compactConversation(
            conversationID: compactConv.id,
            modelSource: .direct(providerID: chatProvider.id, modelID: "friendly-id")
        )

        // 2. Coordinator run classification: .chat (direct & group), .scheduled, .subagent (priority over scheduled)
        @MainActor
        func runAndWait(conversationID: UUID, trigger: () throws -> Void) async throws {
            var finished = false
            var finalStatus: ConversationRunStatus?
            var finalError: String?
            var continuation: CheckedContinuation<Void, Never>?
            let sub = appState.conversationRuns.observe { event in
                if case .runFinished(let cid, _, let status, let err) = event, cid == conversationID {
                    finished = true
                    finalStatus = status
                    finalError = err
                    continuation?.resume()
                    continuation = nil
                }
            }
            defer { sub.cancel() }
            try trigger()
            if !finished && appState.conversationRuns.activeRuns[conversationID] != nil {
                await withCheckedContinuation { cont in
                    if finished || appState.conversationRuns.activeRuns[conversationID] == nil {
                        cont.resume()
                    } else {
                        continuation = cont
                    }
                }
            }
            if finalStatus == nil {
                finalStatus = appState.conversationRuns.activeRuns[conversationID]?.status
                finalError = appState.conversationRuns.activeRuns[conversationID]?.error
            }
            XCTAssertEqual(finalStatus, .completed, finalError ?? "")
        }

        let ws = WorkspaceConfiguration.from(url: storageRoot)
        let cDirectChat = appState.conversations.newBackgroundConversation(
            workspace: ws,
            modelSource: .direct(providerID: chatProvider.id, modelID: "friendly-id"),
            title: "Direct Chat"
        )
        let directMsgs = [ChatMessage(role: .user, content: "UNIQUE_CALIBRATE_120")]
        try appState.conversations.commitDurableMessages(id: cDirectChat.id, messages: directMsgs)
        try await runAndWait(conversationID: cDirectChat.id) {
            appState.conversationRuns.startRun(
                conversationID: cDirectChat.id,
                modelSource: .direct(providerID: chatProvider.id, modelID: "friendly-id"),
                prompt: "UNIQUE_CALIBRATE_120",
                initialMessages: directMsgs
            )
        }
        XCTAssertEqual(
            appState.conversationRuns.contextCalibrationStore.entry(
                for: ContextCalibrationKey(conversationID: cDirectChat.id, providerID: chatProvider.id, modelID: "friendly-id")
            )?.lastActualInputTokens,
            120
        )
        XCTAssertEqual(appState.conversationRuns.contextUsage[cDirectChat.id]?.lastActualInputTokens, 120)

        let cGroupChat = appState.conversations.newBackgroundConversation(
            workspace: ws,
            modelSource: .group(groupID: chatGroup.id),
            title: "Group Chat"
        )
        let groupMsgs = [ChatMessage(role: .user, content: "Group chat run")]
        try appState.conversations.commitDurableMessages(id: cGroupChat.id, messages: groupMsgs)
        try await runAndWait(conversationID: cGroupChat.id) {
            appState.conversationRuns.startRun(
                conversationID: cGroupChat.id,
                modelSource: .group(groupID: chatGroup.id),
                prompt: "Group chat run",
                initialMessages: groupMsgs
            )
        }

        let cSched = appState.conversations.newBackgroundConversation(
            workspace: ws,
            modelSource: .group(groupID: chatGroup.id),
            title: "Scheduled Run"
        )
        let schedMsgs = [ChatMessage(role: .user, content: "Scheduled group run")]
        try appState.conversations.commitDurableMessages(id: cSched.id, messages: schedMsgs)
        var schedRunID: UUID?
        appState.conversationRuns.scheduledRunLookup = { runID in runID == schedRunID }
        try await runAndWait(conversationID: cSched.id) {
            appState.conversationRuns.startRun(
                conversationID: cSched.id,
                modelSource: .group(groupID: chatGroup.id),
                prompt: "Scheduled group run",
                initialMessages: schedMsgs,
                onRunAdmitted: { _, runID in schedRunID = runID }
            )
        }

        // Force scheduledRunLookup true for everything to prove .subagent wins over .scheduled
        appState.conversationRuns.scheduledRunLookup = { _ in true }
        let subSpecID = UUID()
        let startedSub = try appState.subagents.start(
            [SubagentSpec(
                id: subSpecID,
                title: "Sub",
                goal: "Subagent group run",
                role: .research,
                allowWeb: false,
                allowance: SubagentAllowance(modelRequests: 2, toolCalls: 2, seconds: 30)
            )],
            parentConversationID: cDirectChat.id,
            modelSource: .group(groupID: chatGroup.id),
            background: false
        )
        let cSubID = try XCTUnwrap(startedSub.first?.childConversationID)
        _ = try await appState.subagents.wait(taskIDs: [subSpecID], timeout: 10)
        appState.conversationRuns.scheduledRunLookup = nil

        // 3. Anthropic input=0 + cache_read=100 calibration via Coordinator + direct AgentLoopEngine
        let cAnth = appState.conversations.newBackgroundConversation(
            workspace: ws,
            modelSource: .direct(providerID: anthProvider.id, modelID: "claude-test"),
            title: "Anthropic Calibration"
        )
        let anthMsgs = [ChatMessage(role: .user, content: "Calibrate Anthropic cache")]
        try appState.conversations.commitDurableMessages(id: cAnth.id, messages: anthMsgs)
        try await runAndWait(conversationID: cAnth.id) {
            appState.conversationRuns.startRun(
                conversationID: cAnth.id,
                modelSource: .direct(providerID: anthProvider.id, modelID: "claude-test"),
                prompt: "Calibrate Anthropic cache",
                initialMessages: anthMsgs
            )
        }
        XCTAssertEqual(
            appState.conversationRuns.contextCalibrationStore.entry(
                for: ContextCalibrationKey(conversationID: cAnth.id, providerID: anthProvider.id, modelID: "claude-test")
            )?.lastActualInputTokens,
            100
        )
        XCTAssertEqual(appState.conversationRuns.contextUsage[cAnth.id]?.lastActualInputTokens, 100)

        let directObserver = CalibrationMockObserver()
        let directEngine = AgentLoopEngine(client: CalibrationMockClient())
        _ = try await directEngine.run(
            provider: anthProvider,
            apiKey: "anth-key",
            modelID: "claude-test",
            tools: [],
            configuration: AgentLoopConfiguration(maximumTurns: 1),
            initialMessages: [ChatRequestMessage(role: "user", content: "hi")],
            toolExecutor: { _, _ in preconditionFailure("No tool expected") },
            observer: directObserver
        )
        XCTAssertEqual(directObserver.receivedUsages.first?.contextInputTokens, 100)

        // Verify per-kind counts before deletion
        let chatReport = try await recorder.report(since: nil, kind: .chat)
        XCTAssertEqual(chatReport.totals.requests, 3) // cDirectChat + cGroupChat + cAnth
        let scheduledCount = try await recorder.report(since: nil, kind: .scheduled).totals.requests
        let subagentCount = try await recorder.report(since: nil, kind: .subagent).totals.requests
        let titleCount = try await recorder.report(since: nil, kind: .title).totals.requests
        let modelToolCount = try await recorder.report(since: nil, kind: .modelTool).totals.requests
        let quickTestCount = try await recorder.report(since: nil, kind: .quickTest).totals.requests
        let visionCount = try await recorder.report(since: nil, kind: .vision).totals.requests
        let reviewCount = try await recorder.report(since: nil, kind: .permissionReview).totals.requests
        XCTAssertEqual(scheduledCount, 1)
        XCTAssertEqual(subagentCount, 1)
        XCTAssertEqual(titleCount, 1)
        XCTAssertEqual(modelToolCount, 1)
        XCTAssertEqual(quickTestCount, 1)
        XCTAssertEqual(visionCount, 1)
        XCTAssertEqual(reviewCount, 1)
        let compactionReport = try await recorder.report(since: nil, kind: .compaction)
        XCTAssertEqual(compactionReport.totals.requests, 2)
        XCTAssertTrue(compactionReport.groups.contains { $0.model == "Friendly Model" && $0.provider == "Snapshot Provider" })

        // 4. Ledger retention across conversation & provider deletion
        for id in [titleConv.id, compactConv.id, cDirectChat.id, cGroupChat.id, cSched.id, cSubID, cAnth.id] {
            appState.conversations.deleteConversation(id: id)
        }
        try appState.providers.delete(providerID: chatProvider.id)
        try appState.providers.delete(providerID: anthProvider.id)

        let retainedReport = try await recorder.report(since: nil, kind: nil)
        XCTAssertEqual(retainedReport.totals.requests, 12)
        XCTAssertTrue(retainedReport.groups.contains { $0.provider == "Snapshot Provider" && $0.model == "Friendly Model" })
        XCTAssertTrue(retainedReport.groups.contains { $0.provider == "Anth Provider" && $0.model == "Claude Cache" })
    }
}

private final class CalibrationMockClient: ProviderClient {
    func fetchModelDiscovery(provider: ProviderConfiguration, apiKey: String?) async throws -> ModelDiscoveryResult {
        ModelDiscoveryResult(models: provider.models, completeness: .complete, fetchedAt: Date())
    }

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
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            onDiagnostics?(ProviderStreamDiagnostics(
                textCharacters: 2,
                completedReceived: true,
                streamOpened: true,
                usage: ProviderUsageTelemetry(inputTokens: 0, outputTokens: 5, cacheReadTokens: 100),
                finishReason: "end_turn"
            ))
            continuation.yield(.textDelta("ok"))
            continuation.yield(.completed())
            continuation.finish()
        }
    }
}

private final class CalibrationMockObserver: AgentLoopObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var usages: [ProviderUsageTelemetry] = []
    var receivedUsages: [ProviderUsageTelemetry] { lock.withLock { usages } }

    func onTurnStarted(turnIndex: Int) {}
    func onAssistantTurnDiscarded() {}
    func onReasoningDelta(_ delta: String) {}
    func onTextDelta(_ delta: String) {}
    func onToolCallAccumulated(toolIndex: Int, accumulator: ToolCallAccumulator) {}
    func onNativeProtocolMetadata(_ metadata: NativeProtocolMetadata) {}
    func onResponsesReasoningEcho(_ echo: ResponsesReasoningEcho) {}
    func onAssistantMessageCompleted(content: String, reasoningContent: String?, toolCalls: [ProviderToolCall], responsesReasoningEcho: ResponsesReasoningEcho?) {}
    func onToolExecutionStarted(call: ProviderToolCall) {}
    func onToolExecutionCompleted(call: ProviderToolCall, outcome: ToolExecutionOutcome) {}
    func onUsageTelemetryReceived(usage: ProviderUsageTelemetry, providerID: UUID?, modelID: String) {
        lock.withLock { usages.append(usage) }
    }
    func onProviderRequestStarted(providerID: UUID, modelID: String, requestAttempt: Int) {}
    func onProviderRequestRetry(providerID: UUID, modelID: String, requestAttempt: Int, reason: String) {}
    func onProviderThinkingResolved(_ metadata: [String: String]) {}
    func onProviderRequestToolNames(_ names: [String]) {}
}
