import Foundation

/// Content-prefix `<think>...</think>` streaming parser ported from the upstream OpenMinis iOS app.
/// Separates reasoning content streamed inline as visible text into `reasoningDelta` and clean `textDelta`.
public struct ThinkPrefixStreamParser: Sendable {
    private enum Mode: Sendable { case undecided, thinking, body }
    private var mode: Mode = .undecided
    private var buf = ""
    /// True when this turn opened with a think prefix — enables body trim.
    public private(set) var hadThinkPrefix = false
    /// Leading-body trim armed from `</think>` until the first non-whitespace body character.
    private var trimLeadingBody = false

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public init() {}

    /// Feed one streamed content chunk. Returns text to emit now.
    public mutating func consume(_ chunk: String) -> (thinking: String, visible: String) {
        buf += chunk
        var thinking = ""
        var visible = ""

        loop: while !buf.isEmpty {
            switch mode {
            case .undecided:
                // Decide against the buffer with leading whitespace skipped.
                let t = buf.drop(while: { $0.isWhitespace })
                if t.isEmpty { break loop } // whitespace so far — wait
                if t.count < Self.openTag.count {
                    if Self.openTag.hasPrefix(String(t)) { break loop } // may still become <think>
                } else if t.hasPrefix(Self.openTag) {
                    // Think turn: drop the pre-tag whitespace + the tag itself.
                    hadThinkPrefix = true
                    trimLeadingBody = true
                    mode = .thinking
                    buf = String(t.dropFirst(Self.openTag.count))
                    continue loop
                }
                // Plain turn: everything buffered (incl. leading whitespace) is body, verbatim from here on.
                mode = .body
                visible += buf
                buf = ""

            case .thinking:
                if let close = buf.range(of: Self.closeTag) {
                    thinking += String(buf[..<close.lowerBound])
                    buf = String(buf[close.upperBound...])
                    mode = .body
                    continue loop
                }
                // No close tag yet — emit all but the last 8 chars, which could be a partial "</think>" spanning chunks.
                if buf.count > 8 {
                    thinking += String(buf.dropLast(8))
                    buf = String(buf.suffix(8))
                }
                break loop

            case .body:
                if !hadThinkPrefix {
                    visible += buf
                    buf = ""
                    break loop
                }
                if trimLeadingBody {
                    buf = String(buf.drop(while: { $0.isWhitespace }))
                    if buf.isEmpty { break loop }
                    trimLeadingBody = false
                }
                // Withhold any trailing-whitespace run: emitted next chunk if interior, dropped at end-of-turn if truly trailing.
                if let lastNonWS = buf.lastIndex(where: { !$0.isWhitespace }) {
                    let emitEnd = buf.index(after: lastNonWS)
                    visible += String(buf[..<emitEnd])
                    buf = String(buf[emitEnd...])
                }
                break loop
            }
        }
        return (thinking, visible)
    }

    /// Flush at a hard end-of-content boundary ([DONE] / finish_reason).
    public mutating func finishTurn() -> (thinking: String, visible: String) {
        defer { buf = "" }
        switch mode {
        case .undecided:
            mode = .body
            return ("", buf)
        case .thinking:
            // Unclosed think tag — remainder is reasoning, not body.
            return (buf, "")
        case .body:
            return ("", hadThinkPrefix ? "" : buf)
        }
    }

    /// Resolve a still-undecided buffer when a tool_call delta arrives.
    public mutating func resolveAtToolBoundary() -> (thinking: String, visible: String) {
        guard mode == .undecided, !buf.isEmpty else { return ("", "") }
        mode = .body
        defer { buf = "" }
        return ("", buf)
    }
}

/// Normalized usage telemetry reported authoritatively by the model provider.
public struct ProviderUsageTelemetry: Sendable, Equatable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = (inputTokens ?? -1) >= 0 ? inputTokens : nil
        self.outputTokens = (outputTokens ?? -1) >= 0 ? outputTokens : nil
        self.totalTokens = (totalTokens ?? -1) >= 0 ? totalTokens : nil
    }

    public var hasAuthoritativeInputTokens: Bool {
        guard let inputTokens else { return false }
        return inputTokens > 0
    }
}

/// Diagnostics gathered from an active or completed streaming response.
public struct ProviderStreamDiagnostics: Sendable, Equatable {
    public var thinkingMetadata: [String: String] = [:]
    public var textCharacters: Int
    public var reasoningCharacters: Int
    public var toolCallEvents: Int
    public var reasoningEchoEvents: Int
    public var completedReceived: Bool
    public var streamOpened: Bool
    public var unrecognizedEventCount: Int
    public var unrecognizedPayloadSummaries: [String]
    public var usage: ProviderUsageTelemetry?
    public var finishReason: String?

    public init(
        textCharacters: Int = 0,
        reasoningCharacters: Int = 0,
        toolCallEvents: Int = 0,
        reasoningEchoEvents: Int = 0,
        completedReceived: Bool = false,
        streamOpened: Bool = false,
        unrecognizedEventCount: Int = 0,
        unrecognizedPayloadSummaries: [String] = [],
        usage: ProviderUsageTelemetry? = nil,
        finishReason: String? = nil
    ) {
        self.textCharacters = textCharacters
        self.reasoningCharacters = reasoningCharacters
        self.toolCallEvents = toolCallEvents
        self.reasoningEchoEvents = reasoningEchoEvents
        self.completedReceived = completedReceived
        self.streamOpened = streamOpened
        self.unrecognizedEventCount = unrecognizedEventCount
        self.unrecognizedPayloadSummaries = unrecognizedPayloadSummaries
        self.usage = usage
        self.finishReason = finishReason
    }
}

/// Production parser for OpenAI-compatible Server-Sent Events (SSE) streaming responses.
public struct OpenAIStreamParser: Sendable {
    public let model: ProviderModel?
    private var thinkParser = ThinkPrefixStreamParser()

    public private(set) var emittedText = false
    public private(set) var emittedReasoning = false
    public private(set) var emittedToolCall = false
    public private(set) var emittedCompletion = false
    public private(set) var isDone = false
    public private(set) var finishReason: String? = nil
    public private(set) var diagnostics = ProviderStreamDiagnostics()

    public var hasEmittedAnyOutput: Bool {
        emittedText || emittedReasoning || emittedToolCall
    }

    public init(model: ProviderModel? = nil) {
        self.model = model
    }

    /// Parses a single SSE raw line from the HTTP response stream.
    mutating func parseLine(_ rawLine: String) throws -> [AgentStreamEvent] {
        guard !isDone else { return [] }
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = Self.ssePayload(from: line) else { return [] }

        diagnostics.streamOpened = true

        if payload == "[DONE]" {
            isDone = true
            diagnostics.completedReceived = true
            var events: [AgentStreamEvent] = []
            let flushed = thinkParser.finishTurn()
            if !flushed.thinking.isEmpty {
                emittedReasoning = true
                diagnostics.reasoningCharacters += flushed.thinking.count
                events.append(.reasoningDelta(flushed.thinking))
            }
            if !flushed.visible.isEmpty {
                emittedText = true
                diagnostics.textCharacters += flushed.visible.count
                events.append(.textDelta(flushed.visible))
            }
            if !emittedCompletion {
                emittedCompletion = true
                events.append(.completed(finishReason: finishReason))
            }
            return events
        }

        guard let data = payload.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            diagnostics.unrecognizedEventCount += 1
            if diagnostics.unrecognizedPayloadSummaries.count < 3 {
                diagnostics.unrecognizedPayloadSummaries.append(String(payload.prefix(120)))
            }
            return []
        }

        if let error = Self.providerStreamError(from: json) {
            throw error
        }

        var events: [AgentStreamEvent] = []
        var eventRecognized = false

        // 0. Usage telemetry parsing (opportunistic, tolerant of missing/null/partial)
        if let usageDict = json["usage"] as? [String: Any] {
            let promptTokens = usageDict["prompt_tokens"] as? Int
            let completionTokens = usageDict["completion_tokens"] as? Int
            let totalTokens = usageDict["total_tokens"] as? Int
            if promptTokens != nil || completionTokens != nil || totalTokens != nil {
                diagnostics.usage = ProviderUsageTelemetry(
                    inputTokens: promptTokens,
                    outputTokens: completionTokens,
                    totalTokens: totalTokens
                )
                eventRecognized = true
            }
        }

        // 1. Structured / interleaved reasoning fields
        if let reasoning = Self.reasoningDelta(from: json, interleavedField: model?.interleavedReasoningField) {
            emittedReasoning = true
            diagnostics.reasoningCharacters += reasoning.count
            events.append(.reasoningDelta(reasoning))
            eventRecognized = true
        }

        // 2. Tool calls (resolve think prefix buffer first if needed)
        let toolDeltas = Self.toolCallDeltas(from: json)
        if !toolDeltas.isEmpty {
            let flushed = thinkParser.resolveAtToolBoundary()
            if !flushed.visible.isEmpty {
                emittedText = true
                diagnostics.textCharacters += flushed.visible.count
                events.append(.textDelta(flushed.visible))
            }
            emittedToolCall = true
            diagnostics.toolCallEvents += toolDeltas.count
            events.append(contentsOf: toolDeltas)
            eventRecognized = true
        }

        // 3. Text content (piped through ThinkPrefixStreamParser)
        if let text = Self.textDelta(from: json) {
            let parsed = thinkParser.consume(text)
            if !parsed.thinking.isEmpty {
                emittedReasoning = true
                diagnostics.reasoningCharacters += parsed.thinking.count
                events.append(.reasoningDelta(parsed.thinking))
            }
            if !parsed.visible.isEmpty {
                emittedText = true
                diagnostics.textCharacters += parsed.visible.count
                events.append(.textDelta(parsed.visible))
            }
            eventRecognized = true
        }

        // 4. Finish reason
        if let reason = Self.finishReason(from: json) {
            finishReason = reason
            diagnostics.finishReason = reason
            diagnostics.completedReceived = true
            let flushed = thinkParser.finishTurn()
            if !flushed.thinking.isEmpty {
                emittedReasoning = true
                diagnostics.reasoningCharacters += flushed.thinking.count
                events.append(.reasoningDelta(flushed.thinking))
            }
            if !flushed.visible.isEmpty {
                emittedText = true
                diagnostics.textCharacters += flushed.visible.count
                events.append(.textDelta(flushed.visible))
            }
            if !emittedCompletion {
                emittedCompletion = true
                events.append(.completed(finishReason: reason))
            }
            eventRecognized = true
        }

        if !eventRecognized {
            diagnostics.unrecognizedEventCount += 1
            if diagnostics.unrecognizedPayloadSummaries.count < 3 {
                diagnostics.unrecognizedPayloadSummaries.append(String(payload.prefix(120)))
            }
        }

        return events
    }

    /// Finalize and flush any buffered tokens at end of stream.
    mutating func finish() -> [AgentStreamEvent] {
        var events: [AgentStreamEvent] = []
        let flushed = thinkParser.finishTurn()
        if !flushed.thinking.isEmpty {
            emittedReasoning = true
            diagnostics.reasoningCharacters += flushed.thinking.count
            events.append(.reasoningDelta(flushed.thinking))
        }
        if !flushed.visible.isEmpty {
            emittedText = true
            diagnostics.textCharacters += flushed.visible.count
            events.append(.textDelta(flushed.visible))
        }
        // EOF is transport closure, never terminal evidence.
        return events
    }

    // MARK: - Static Parsers

    /// Extract payload from SSE data line (tolerating optional space after colon).
    static func ssePayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let after = line.dropFirst(5)
        if after.first == " " {
            return String(after.dropFirst())
        }
        return String(after)
    }

    static func reasoningDelta(from root: [String: Any], interleavedField: String? = nil) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }

        if let delta = first["delta"] as? [String: Any] {
            if let field = interleavedField, !field.isEmpty, let val = delta[field] as? String {
                return val
            }
            if let reasoning = delta["reasoning_content"] as? String { return reasoning }
            if let reasoning = delta["reasoning"] as? String { return reasoning }
            if let reasoning = delta["reasoning_text"] as? String { return reasoning }
            if let parts = delta["reasoning_content"] as? [[String: Any]] {
                return parts.compactMap { part in
                    (part["text"] as? String) ?? ((part["text"] as? [String: Any])?["value"] as? String)
                }.joined()
            }
            if let parts = delta["reasoning"] as? [[String: Any]] {
                return parts.compactMap { part in
                    (part["text"] as? String) ?? ((part["text"] as? [String: Any])?["value"] as? String)
                }.joined()
            }
        }
        return nil
    }

    static func textDelta(from root: [String: Any]) -> String? {
        guard let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }

        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String { return content }
            if let parts = delta["content"] as? [[String: Any]] {
                return parts.compactMap { part in
                    (part["text"] as? String) ?? ((part["text"] as? [String: Any])?["value"] as? String)
                }.joined()
            }
        }
        return first["text"] as? String
    }

    public static func finishReason(from root: [String: Any]) -> String? {
        if let choices = root["choices"] as? [[String: Any]],
           let first = choices.first {
            if let reason = first["finish_reason"] as? String {
                return reason
            }
            if let reason = first["stop_reason"] as? String {
                return reason
            }
        }
        if let reason = root["finish_reason"] as? String {
            return reason
        }
        return nil
    }

    public static func isFinished(_ root: [String: Any]) -> Bool {
        finishReason(from: root) != nil
    }

    static func toolCallDeltas(from root: [String: Any]) -> [AgentStreamEvent] {
        guard let choices = root["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { call in
            let index = call["index"] as? Int ?? 0
            let function = call["function"] as? [String: Any]
            return .toolCallDelta(
                index: index,
                id: call["id"] as? String,
                name: function?["name"] as? String,
                arguments: function?["arguments"] as? String ?? ""
            )
        }
    }

    /// An error object inside the stream arrives after an HTTP 200, so it has no status of its own.
    static func providerStreamError(from root: [String: Any]) -> ProviderClientError? {
        guard let error = root["error"] as? [String: Any], let message = error["message"] as? String else { return nil }
        let code = error["code"] as? String ?? (error["code"] as? Int).map(String.init) ?? error["type"] as? String
        return .streamError(code: code, message: message)
    }
}
