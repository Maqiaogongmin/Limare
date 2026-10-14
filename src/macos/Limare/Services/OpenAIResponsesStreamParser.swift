import Foundation

public struct OpenAIResponsesStreamParser {
    public struct FunctionCallState {
        public let outputIndex: Int
        public let callID: String
        public let name: String
        public var json: String

        public init(outputIndex: Int, callID: String, name: String, json: String) {
            self.outputIndex = outputIndex
            self.callID = callID
            self.name = name
            self.json = json
        }
    }

    public let providerID: UUID
    public let modelID: String
    public private(set) var isDone: Bool = false
    public private(set) var hasEmittedAnyOutput: Bool = false
    public private(set) var finishReason: String? = nil
    public private(set) var diagnostics = ProviderStreamDiagnostics()

    private var functionCalls: [String: FunctionCallState] = [:]
    private var outputIndexByItemId: [String: Int] = [:]
    private var nextOutputIndex: Int = 0

    private var reasoningSummaryByItemId: [String: String] = [:]
    private var reasoningItems: [ResponsesReasoningItem] = []
    private var currentReasoningItemId: String? = nil

    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    mutating func parseLine(_ line: String) throws -> [AgentStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Support data: ... and data:{...}
        guard trimmed.hasPrefix("data:") else { return [] }
        diagnostics.streamOpened = true
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isDone = true
            // [DONE] is not response.completed evidence on Responses wire.
            return []
        }

        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            diagnostics.unrecognizedEventCount += 1
            if diagnostics.unrecognizedPayloadSummaries.count < 3 {
                diagnostics.unrecognizedPayloadSummaries.append(String(payload.prefix(120)))
            }
            return []
        }

        let usageObj = (event["response"] as? [String: Any])?["usage"] as? [String: Any] ?? event["usage"] as? [String: Any]
        if let usageObj {
            let inputTokens = usageObj["input_tokens"] as? Int
            let outputTokens = usageObj["output_tokens"] as? Int
            let totalTokens = usageObj["total_tokens"] as? Int
            if inputTokens != nil || outputTokens != nil || totalTokens != nil {
                diagnostics.usage = ProviderUsageTelemetry(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    totalTokens: totalTokens
                )
            }
        }

        let eventType = event["type"] as? String ?? ""

        switch eventType {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                hasEmittedAnyOutput = true
                diagnostics.textCharacters += delta.count
                return [.textDelta(delta)]
            }

        case "response.reasoning_summary_text.delta",
             "response.reasoning_text.delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                let itemId = (event["item_id"] as? String) ?? currentReasoningItemId ?? "default"
                reasoningSummaryByItemId[itemId, default: ""] += delta
                hasEmittedAnyOutput = true
                diagnostics.reasoningCharacters += delta.count
                return [.reasoningDelta(delta)]
            }

        case "response.output_item.added":
            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String {
                if itemType == "reasoning" {
                    let itemId = item["id"] as? String ?? ""
                    currentReasoningItemId = itemId
                    if !itemId.isEmpty && reasoningSummaryByItemId[itemId] == nil {
                        reasoningSummaryByItemId[itemId] = ""
                    }
                } else if itemType == "function_call" {
                    let itemId = item["id"] as? String ?? ""
                    let callId = item["call_id"] as? String ?? itemId
                    let name = item["name"] as? String ?? ""
                    let outputIndex = (event["output_index"] as? Int) ?? nextOutputIndex
                    nextOutputIndex = max(nextOutputIndex, outputIndex + 1)
                    outputIndexByItemId[itemId] = outputIndex
                    functionCalls[itemId] = FunctionCallState(outputIndex: outputIndex, callID: callId, name: name, json: "")
                    hasEmittedAnyOutput = true
                    diagnostics.toolCallEvents += 1
                    return [.toolCallDelta(index: outputIndex, id: callId, name: name, arguments: "")]
                }
            }

        case "response.function_call_arguments.delta":
            let itemId = (event["item_id"] as? String) ?? ""
            let delta = event["delta"] as? String ?? ""
            if var state = functionCalls[itemId] {
                state.json += delta
                functionCalls[itemId] = state
                return [.toolCallDelta(index: state.outputIndex, id: nil, name: nil, arguments: delta)]
            }

        case "response.output_item.done":
            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String {
                if itemType == "function_call" {
                    let itemId = item["id"] as? String ?? ""
                    if let fullArgs = item["arguments"] as? String, var state = functionCalls[itemId] {
                        if state.json.isEmpty && !fullArgs.isEmpty {
                            state.json = fullArgs
                            functionCalls[itemId] = state
                            return [.toolCallDelta(index: state.outputIndex, id: nil, name: nil, arguments: fullArgs)]
                        }
                    }
                } else if itemType == "reasoning" {
                    let itemId = item["id"] as? String ?? ""
                    let encrypted = item["encrypted_content"] as? String
                    var summaries: [String] = []
                    if let sumArr = item["summary"] as? [[String: Any]] {
                        summaries = sumArr.compactMap { $0["text"] as? String }
                    }
                    if summaries.isEmpty, let streamed = reasoningSummaryByItemId[itemId], !streamed.isEmpty {
                        summaries = [streamed]
                    }
                    if !reasoningItems.contains(where: { $0.id == itemId }) {
                        reasoningItems.append(ResponsesReasoningItem(id: itemId, encryptedContent: encrypted, summary: summaries))
                    }
                    if currentReasoningItemId == itemId {
                        currentReasoningItemId = nil
                    }
                }
            }

        case "response.failed":
            let responseObj = event["response"] as? [String: Any]
            let errObj = responseObj?["error"] as? [String: Any]
            let code = errObj?["code"] as? String ?? "unknown"
            let message = errObj?["message"] as? String ?? ""
            if code == "server_error" {
                throw ProviderClientError.http(status: 500, message: message)
            } else if code == "rate_limit_exceeded" {
                throw ProviderClientError.http(status: 429, message: message)
            } else {
                throw ProviderClientError.responsesFailed(code: code, message: message)
            }

        case "response.incomplete":
            let responseObj = event["response"] as? [String: Any]
            let details = responseObj?["incomplete_details"] as? [String: Any]
            let reason = details?["reason"] as? String ?? "unknown"
            throw ProviderClientError.responsesIncomplete(reason: reason)

        case "response.completed":
            diagnostics.completedReceived = true
            let responseObj = event["response"] as? [String: Any]
            let status = responseObj?["status"] as? String
            if status == "incomplete" {
                let details = responseObj?["incomplete_details"] as? [String: Any]
                let reason = details?["reason"] as? String ?? "unknown"
                throw ProviderClientError.responsesIncomplete(reason: reason)
            } else if status == "failed" {
                let errObj = responseObj?["error"] as? [String: Any]
                let code = errObj?["code"] as? String ?? "unknown"
                let message = errObj?["message"] as? String ?? ""
                if code == "server_error" {
                    throw ProviderClientError.http(status: 500, message: message)
                } else if code == "rate_limit_exceeded" {
                    throw ProviderClientError.http(status: 429, message: message)
                } else {
                    throw ProviderClientError.responsesFailed(code: code, message: message)
                }
            }

            let authoritativeReason: String? = (status == "completed") ? "stop" : status
            self.finishReason = authoritativeReason
            diagnostics.finishReason = authoritativeReason
            isDone = true
            diagnostics.completedReceived = true
            var outEvents: [AgentStreamEvent] = []

            let outputArray = responseObj?["output"] as? [[String: Any]] ?? []
            for outItem in outputArray {
                if outItem["type"] as? String == "reasoning" {
                    let id = outItem["id"] as? String ?? ""
                    if !reasoningItems.contains(where: { $0.id == id }) {
                        let encrypted = outItem["encrypted_content"] as? String
                        var summaries: [String] = []
                        if let sumArr = outItem["summary"] as? [[String: Any]] {
                            summaries = sumArr.compactMap { $0["text"] as? String }
                        }
                        if summaries.isEmpty, let streamed = reasoningSummaryByItemId[id], !streamed.isEmpty {
                            summaries = [streamed]
                        }
                        reasoningItems.append(ResponsesReasoningItem(id: id, encryptedContent: encrypted, summary: summaries))
                    }
                }
            }

            if !reasoningItems.isEmpty {
                diagnostics.reasoningEchoEvents += reasoningItems.count
                let echo = ResponsesReasoningEcho(providerID: providerID, modelID: modelID, items: reasoningItems)
                outEvents.append(.responsesReasoningEcho(echo))
            }
            outEvents.append(.completed(finishReason: authoritativeReason))
            return outEvents

        default:
            diagnostics.unrecognizedEventCount += 1
            if diagnostics.unrecognizedPayloadSummaries.count < 3 {
                diagnostics.unrecognizedPayloadSummaries.append(String(eventType.prefix(120)))
            }
            break
        }

        return []
    }

    mutating func finish() -> [AgentStreamEvent] {
        guard !isDone else { return [] }
        isDone = true
        // EOF does not manufacture response.completed.
        var out: [AgentStreamEvent] = []
        if !reasoningItems.isEmpty {
            diagnostics.reasoningEchoEvents += reasoningItems.count
            let echo = ResponsesReasoningEcho(providerID: providerID, modelID: modelID, items: reasoningItems)
            out.append(.responsesReasoningEcho(echo))
        }

        return out
    }
}
