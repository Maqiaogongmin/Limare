import Foundation
import SwiftAnthropic
import ImageIO
private let logger = AppLogger(category: "AnthropicProjection")
final class AnthropicAgentProvider {
 let provider: AnthropicProvider
 var model: LLMModel { provider.model }
 var pendingToolResultImages: [String: (Data, String)] = [:]
 init(provider: AnthropicProvider) { self.provider = provider }
    static func thinkingBudget(for model: LLMModel, maxTokens: Int, level: ThinkingLevel = .medium) -> Int {
        guard model.supportsReasoning ?? false else { return 0 }
        let cap: Int = switch level {
        case .off: 0
        case .minimal: 1024
        case .low: 8192
        case .medium: 32768
        case .high: min(maxTokens, 65536)
        case .xhigh, .max, .ultra: maxTokens
        }
        // Anthropic requires budget_tokens < max_tokens (strict inequality).
        let clamped = min(cap, maxTokens)
        return clamped >= maxTokens && maxTokens > 1 ? maxTokens - 1 : clamped
    }
    static func thinkingEffort(for level: ThinkingLevel) -> String {
        switch level {
        case .off: return "low"  // never reached: caller checks isEnabled first
        case .minimal: return "low"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max, .ultra: return "max"
        }
    }
    static func injectMissingToolResults(_ messages: [AgentMessage]) -> [AgentMessage] {
        var result: [AgentMessage] = []
        result.reserveCapacity(messages.count + 2)
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            result.append(msg)
            guard msg.role == .assistant else { i += 1; continue }

            let toolUses = msg.parts.compactMap { part -> (id: String, name: String)? in
                if case .toolUse(let id, let name, _) = part { return (id, name) }
                return nil
            }
            guard !toolUses.isEmpty else { i += 1; continue }

            // Collect tool_result ids from the immediately-following user
            // message (if any). Anthropic only accepts the result in the very
            // next message, so we look exactly one ahead.
            var satisfied: Set<String> = []
            if i + 1 < messages.count, messages[i + 1].role == .user {
                for part in messages[i + 1].parts {
                    if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                        satisfied.insert(id)
                    }
                }
            }

            let missing = toolUses.filter { !satisfied.contains($0.id) }
            guard !missing.isEmpty else { i += 1; continue }

            let placeholders = missing.map { tu in
                AgentContentPart.toolResult(
                    id: tu.id, name: tu.name,
                    content: "Tool execution was interrupted before a result was returned (the session or stream ended mid-tool). Treat this tool call as unfinished and retry or proceed without its result.",
                    isError: true
                )
            }
            if i + 1 < messages.count, messages[i + 1].role == .user {
                // Prepend synthetic results to the existing next user message so
                // the matched-tool_result-first ordering still holds after merge.
                var next = messages[i + 1]
                next.parts = placeholders + next.parts
                result.append(next)
                logger.warning("Injected \(placeholders.count) synthetic tool_result(s) into existing user message for unanswered tool_use(s) at idx=\(i)")
                i += 2
            } else {
                // No following user message — insert a fresh one.
                result.append(AgentMessage(role: .user, parts: placeholders))
                logger.warning("Inserted user message with \(placeholders.count) synthetic tool_result(s) for unanswered tool_use(s) at idx=\(i)")
                i += 1
            }
        }
        return result
    }
    static func stripOrphanToolResults(_ messages: [AgentMessage]) -> [AgentMessage] {
        var result = messages
        var liveToolUseIds: Set<String> = []
        for i in 0..<result.count {
            switch result[i].role {
            case .assistant:
                liveToolUseIds = Set(result[i].parts.compactMap { part -> String? in
                    if case .toolUse(let id, _, _) = part { return id }
                    return nil
                })
            case .user:
                let original = result[i].parts
                let kept = original.filter { part in
                    if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                        return liveToolUseIds.contains(id)
                    }
                    return true
                }
                if kept.count != original.count {
                    let dropped = original.count - kept.count
                    logger.info("Stripped \(dropped) orphan tool_result block(s) from outbound payload (idx=\(i))")
                    result[i].parts = kept
                }
                // Consume the matched tool_use ids so a later duplicate
                // tool_result for the same id is treated as an orphan. Do NOT
                // clear the entire set — a single assistant turn's tool_uses
                // can have their tool_results delivered across multiple
                // consecutive user messages (e.g. the user types a text
                // message while a tool is still executing, then the tool's
                // cancel/error tool_result arrives in a separate user turn).
                // Clearing wholesale here would drop those late-arriving
                // tool_results, producing exactly the 400 we are guarding
                // against. The set is naturally reset on the next assistant
                // turn (top of this loop).
                for part in kept {
                    if case .toolResult(let id, _, _, _, _, _, _, _) = part {
                        liveToolUseIds.remove(id)
                    }
                }
            }
        }
        // Drop user messages that became empty (only had orphan tool_results).
        // Sending an empty content array is itself a 400.
        return result.filter { !$0.parts.isEmpty }
    }
    static func mergeConsecutiveSameRole(_ messages: [MessageParameter.Message]) -> [MessageParameter.Message] {
        guard !messages.isEmpty else { return messages }
        var roles: [String] = []
        var contents: [MessageParameter.Message.Content] = []
        for msg in messages {
            if let lastRole = roles.last, lastRole == msg.role {
                contents[contents.count - 1] = concatContent(contents[contents.count - 1], msg.content)
            } else {
                roles.append(msg.role)
                contents.append(msg.content)
            }
        }
        return zip(roles, contents).map { role, content in
            let r: MessageParameter.Message.Role = role == "user" ? .user : .assistant
            let ordered: MessageParameter.Message.Content
            if role == "assistant" {
                ordered = reorderAssistantContent(content)
            } else {
                ordered = reorderUserContent(content)
            }
            return MessageParameter.Message(role: r, content: ordered)
        }
    }
    static func reorderUserContent(_ content: MessageParameter.Message.Content) -> MessageParameter.Message.Content {
        guard case .list(let objects) = content, objects.count > 1 else { return content }
        var hasToolResult = false
        var firstNonToolResultIdx: Int? = nil
        for (idx, obj) in objects.enumerated() {
            if case .toolResult = obj {
                hasToolResult = true
                if let nonIdx = firstNonToolResultIdx, idx > nonIdx {
                    // tool_result follows a non-tool_result block → reorder.
                    var toolResults: [MessageParameter.Message.Content.ContentObject] = []
                    var others: [MessageParameter.Message.Content.ContentObject] = []
                    for o in objects {
                        if case .toolResult = o { toolResults.append(o) }
                        else { others.append(o) }
                    }
                    return .list(toolResults + others)
                }
            } else if firstNonToolResultIdx == nil {
                firstNonToolResultIdx = idx
            }
        }
        _ = hasToolResult
        return content
    }
    static func reorderAssistantContent(_ content: MessageParameter.Message.Content) -> MessageParameter.Message.Content {
        guard case .list(let objects) = content, objects.count > 1 else { return content }

        // Check if reordering is needed (any text/image/cache after a tool_use?)
        var sawToolUse = false
        var needsReorder = false
        for obj in objects {
            if case .toolUse = obj { sawToolUse = true }
            else if sawToolUse {
                needsReorder = true
                break
            }
        }
        guard needsReorder else { return content }

        // Partition: non-tool_use blocks first, tool_use blocks last
        var nonToolUse: [MessageParameter.Message.Content.ContentObject] = []
        var toolUse: [MessageParameter.Message.Content.ContentObject] = []
        for obj in objects {
            if case .toolUse = obj { toolUse.append(obj) }
            else { nonToolUse.append(obj) }
        }
        return .list(nonToolUse + toolUse)
    }
    static func concatContent(
        _ a: MessageParameter.Message.Content,
        _ b: MessageParameter.Message.Content
    ) -> MessageParameter.Message.Content {
        var objects: [MessageParameter.Message.Content.ContentObject] = []
        switch a {
        case .text(let t): objects.append(.text(t))
        case .list(let list): objects.append(contentsOf: list)
        @unknown default: break
        }
        switch b {
        case .text(let t): objects.append(.text(t))
        case .list(let list): objects.append(contentsOf: list)
        @unknown default: break
        }
        return .list(objects)
    }
    func convertMessages(_ messages: [AgentMessage]) -> [MessageParameter.Message] {
        // Two complementary self-healing passes, both on a value-typed copy so
        // the caller's stored history is untouched:
        //   1. injectMissingToolResults — every tool_use must be followed by a
        //      tool_result (Anthropic 400 "tool_use ids were found without
        //      tool_result blocks immediately after"). A tool_use whose result
        //      never arrived (stream interrupted mid-tool, VM/session torn down,
        //      fallback re-send of a half-finished turn) gets a synthetic error
        //      tool_result spliced in right after its assistant message.
        //   2. stripOrphanToolResults — the inverse: drop tool_results with no
        //      matching tool_use.
        // (1) runs first so any result it injects is then validated by (2).
        let healed = Self.injectMissingToolResults(messages)
        let cleaned = Self.stripOrphanToolResults(healed)
        let mapped: [MessageParameter.Message] = cleaned.map { msg in
            let role: MessageParameter.Message.Role = msg.role == .user ? .user : .assistant
            let objects: [MessageParameter.Message.Content.ContentObject] = msg.parts.compactMap { part in
                switch part {
                case .text(let text):
                    return .text(text)
                case .toolUse(let id, let name, let input):
                    return .toolUse(sanitizeToolId(id), name, convertToInput(input))
                case .toolResult(let id, _, let content, let isError, let imageData, let imageMimeType, _, _):
                    let safeId = sanitizeToolId(id)
                    if let data = imageData {
                        // Downscale to Anthropic's recommended 1568px to avoid
                        // "many-image" dimension errors in long conversations.
                        // downscaleForAnthropic always returns JPEG data, so force
                        // the mime type to match — prevents media_type/data mismatch
                        // when restored sessions have PNG data sniffed as image/png.
                        let downscaled = Self.downscaleForAnthropic(data)
                        let finalData = downscaled ?? data
                        let finalMime = downscaled != nil ? "image/jpeg" : (imageMimeType ?? "image/jpeg")
                        self.pendingToolResultImages[safeId] = (data: finalData, mimeType: finalMime)
                    }
                    return .toolResult(safeId, content, isError: isError)
                case .imageData(let data, let mimeType, _):
                    let finalData = Self.downscaleForAnthropic(data) ?? data
                    let base64 = finalData.base64EncodedString()
                    let mediaType: MessageParameter.Message.Content.ImageSource.MediaType
                    switch mimeType {
                    case "image/png": mediaType = .png
                    case "image/gif": mediaType = .gif
                    case "image/webp": mediaType = .webp
                    default: mediaType = .jpeg
                    }
                    return .image(.init(type: .base64, mediaType: mediaType, data: base64))
                }
            }
            return MessageParameter.Message(role: role, content: .list(objects))
        }

        // Merge consecutive messages with the same role. Retry, cancel, and
        // provider-switch flows can produce adjacent assistant (or user) messages.
        // Anthropic API requires tool_result immediately after tool_use — if an
        // intervening same-role message splits them, the request returns 400.
        return Self.mergeConsecutiveSameRole(mapped)
    }
    func convertToInput(_ dict: [String: Any]) -> MessageResponse.Content.Input {
        var result: MessageResponse.Content.Input = [:]
        for (key, value) in dict {
            if let s = value as? String {
                result[key] = .string(s)
            } else if let n = value as? NSNumber {
                if CFBooleanGetTypeID() == CFGetTypeID(n) {
                    result[key] = .bool(n.boolValue)
                } else {
                    result[key] = .integer(n.intValue)
                }
            }
        }
        return result
    }
    func convertTools(_ tools: [AgentToolDefinition]) -> [MessageParameter.Tool] {
        tools.map { tool in
            var properties: [String: JSONSchema.Property] = [:]
            for (name, param) in tool.parameters {
                let type: JSONSchema.JSONType = switch param.type {
                case .string: .string
                case .integer: .integer
                case .boolean: .boolean
                }
                properties[name] = JSONSchema.Property(
                    type: type,
                    description: param.description,
                    enumValues: param.enumValues
                )
            }
            return MessageParameter.Tool.function(
                name: tool.name,
                description: tool.description,
                inputSchema: JSONSchema(
                    type: .object,
                    properties: properties,
                    required: tool.required
                )
            )
        }
    }
    static func downscaleForAnthropic(_ data: Data, maxLongEdge: CGFloat = 2000) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              max(w.doubleValue, h.doubleValue) > Double(maxLongEdge),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
                kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return result as Data
    }
}
