import Foundation

struct NativeProtocolMetadata: Codable, Equatable, Sendable {
    let providerID: UUID
    let modelID: String
    let authenticationIdentityID: String
    let protocolAdapter: ProviderAPIFormat
    let payload: Data
}


struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    enum State: String, Codable, Sendable {
        case complete
        case streaming
        case failed
        case interrupted
    }

    let id: UUID
    let role: Role
    var content: String
    var reasoningContent: String?
    var state: State
    var toolCalls: [ToolCallRecord]
    var attachments: [ChatAttachment]
    var responsesReasoningEcho: ResponsesReasoningEcho?
    var nativeProtocolMetadata: NativeProtocolMetadata? = nil
    var resolvedProviderID: UUID?
    var resolvedModelID: String?
    /// Rejected provider turn evidence; never projected back onto the wire.
    var rejectedAssistantTurn: String?
    /// A user-role message the system wrote (finished subagents' results), not the user's
    /// request: it never owns the turn's changes and is never "the last user message" to undo.
    var isSystemNotice = false

    /// A message the user sent while a run was working (a steer), not a new request.
    var sentWhileWorking = false

    /// Set when the runtime, not the model, wrote this reply's text: a request that failed
    /// before any output, a stop, an interruption. The transcript draws it as a status line.
    var runtimeNotice: RuntimeNotice?

    enum RuntimeNotice: String, Codable, Sendable {
        case failed, stopped, interrupted

        static let stoppedText = "Stopped."
        static let interruptedText = "Response interrupted."
        static let requestFailedText = "Request failed."
        static let providerUnavailableText = "Provider unavailable."
        static let apiKeyErrorText = "API key error."
        static let groupUnavailableText = "Model group unavailable."
        static let groupModelsUnavailableText = "Group models unavailable."
        static let groupNoCandidateText = "Model group has no executable candidate."
        static let groupExecutionFailedText = "Group execution failed."

        /// Replies saved before the flag existed are recognised by the texts above.
        static func legacy(content: String, state: State) -> RuntimeNotice? {
            switch (state, content) {
            case (.failed, stoppedText): .stopped
            case (.interrupted, interruptedText): .interrupted
            case (.failed, requestFailedText), (.failed, providerUnavailableText), (.failed, apiKeyErrorText),
                 (.failed, groupUnavailableText), (.failed, groupModelsUnavailableText),
                 (.failed, groupNoCandidateText), (.failed, groupExecutionFailedText): .failed
            default: nil
            }
        }
    }

    /// A message the user wrote.
    var isUserPrompt: Bool { role == .user && !isSystemNotice }

    /// The text the model reads. A message sent mid-task is framed as Claude Code frames a
    /// queued message, so the model answers it and goes on with the task instead of taking it
    /// as a new request that ends the work.
    var requestText: String {
        guard isUserPrompt, sentWhileWorking, !content.isEmpty else { return content }
        return "The user sent the following message while you were working:\n\(content)\n\nPlease address this message and continue with your tasks."
    }

    static let systemNoticePrefix = "[Subagent results]"

    static func systemNotice(_ content: String) -> ChatMessage {
        var message = ChatMessage(role: .user, content: content)
        message.isSystemNotice = true
        return message
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        state: State = .complete,
        toolCalls: [ToolCallRecord] = [],
        attachments: [ChatAttachment] = [],
        responsesReasoningEcho: ResponsesReasoningEcho? = nil,
        resolvedProviderID: UUID? = nil,
        resolvedModelID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.state = state
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.responsesReasoningEcho = responsesReasoningEcho
        self.resolvedProviderID = resolvedProviderID
        self.resolvedModelID = resolvedModelID
        self.rejectedAssistantTurn = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, state, toolCalls, attachments, responsesReasoningEcho
        case resolvedProviderID, resolvedModelID, rejectedAssistantTurn, isSystemNotice, nativeProtocolMetadata
        case sentWhileWorking, runtimeNotice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(Role.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.state = try container.decode(State.self, forKey: .state)
        self.toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        self.attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        self.responsesReasoningEcho = try container.decodeIfPresent(ResponsesReasoningEcho.self, forKey: .responsesReasoningEcho)
        self.nativeProtocolMetadata = try container.decodeIfPresent(NativeProtocolMetadata.self, forKey: .nativeProtocolMetadata)
        self.resolvedProviderID = try container.decodeIfPresent(UUID.self, forKey: .resolvedProviderID)
        self.resolvedModelID = try container.decodeIfPresent(String.self, forKey: .resolvedModelID)
        self.rejectedAssistantTurn = try container.decodeIfPresent(String.self, forKey: .rejectedAssistantTurn)
        // Notices saved before the flag existed are recognised by their header.
        self.isSystemNotice = try container.decodeIfPresent(Bool.self, forKey: .isSystemNotice)
            ?? (role == .user && content.hasPrefix(Self.systemNoticePrefix))
        self.sentWhileWorking = try container.decodeIfPresent(Bool.self, forKey: .sentWhileWorking) ?? false
        if container.contains(.runtimeNotice) {
            self.runtimeNotice = try container.decodeIfPresent(RuntimeNotice.self, forKey: .runtimeNotice)
        } else if role == .assistant, toolCalls.isEmpty {
            self.runtimeNotice = RuntimeNotice.legacy(content: content, state: state)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encode(state, forKey: .state)
        try container.encode(toolCalls, forKey: .toolCalls)
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encodeIfPresent(responsesReasoningEcho, forKey: .responsesReasoningEcho)
        try container.encodeIfPresent(nativeProtocolMetadata, forKey: .nativeProtocolMetadata)
        try container.encodeIfPresent(resolvedProviderID, forKey: .resolvedProviderID)
        try container.encodeIfPresent(resolvedModelID, forKey: .resolvedModelID)
        try container.encodeIfPresent(rejectedAssistantTurn, forKey: .rejectedAssistantTurn)
        // Always written: only records saved before the flag existed fall back to the header.
        try container.encode(isSystemNotice, forKey: .isSystemNotice)
        if sentWhileWorking {
            try container.encode(sentWhileWorking, forKey: .sentWhileWorking)
        }
        // Written on every assistant reply, null included, so only records saved before the
        // flag existed fall back to the texts.
        if role == .assistant {
            try container.encode(runtimeNotice, forKey: .runtimeNotice)
        }
    }
}

public enum ChatContentPart: Encodable, Sendable, Equatable {
    case text(String)
    case imageUrl(url: String)
    case imageAttachment(ChatAttachment)
    case attachment(ChatAttachment)
    case artifact(id: UUID, semanticRole: ArtifactSemanticRole, mimeType: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, imageUrl = "image_url", attachment, id, semanticRole, mimeType
    }

    private struct ImageUrlContainer: Encodable {
        let url: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageUrl(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageUrlContainer(url: url), forKey: .imageUrl)
        case .imageAttachment(let att):
            try container.encode("attachment", forKey: .type)
            try container.encode(att, forKey: .attachment)
        case .attachment(let att):
            try container.encode("attachment", forKey: .type)
            try container.encode(att, forKey: .attachment)
        case .artifact(let id, let semanticRole, let mimeType):
            try container.encode("artifact", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(semanticRole, forKey: .semanticRole)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

extension ChatContentPart {
    /// Bounded, base64-free textual projection of a canonical artifact identity.
    ///
    /// This is what a provider turn shows when an artifact part is not projected as image
    /// bytes on the current wire, so the model can still reach the artifact through the
    /// existing specialist route. It carries identity and declared type only; it is never a
    /// substitute for the artifact itself and never carries bytes.
    static func artifactReferenceText(
        id: UUID,
        semanticRole: ArtifactSemanticRole,
        mimeType: String
    ) -> String {
        "[Artifact: id=\(id.uuidString) type=\(mimeType) role=\(semanticRole.rawValue)]"
    }
}

public enum ChatRequestContent: Encodable, Sendable, Equatable {
    case text(String)
    case parts([ChatContentPart])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    public var textValue: String? {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            let textParts = parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }
            return textParts.joined(separator: "\n")
        }
    }
}

struct ChatRequestMessage: Encodable, Sendable {
    let role: String
    let content: ChatRequestContent?
    let reasoningContent: String?
    let toolCalls: [ProviderToolCall]?
    let toolCallID: String?
    let responsesReasoningEcho: ResponsesReasoningEcho?
    var nativeProtocolMetadata: NativeProtocolMetadata? = nil

    init(role: String, content: String) {
        self.role = role
        self.content = .text(content)
        self.reasoningContent = nil
        self.toolCalls = nil
        self.toolCallID = nil
        self.responsesReasoningEcho = nil
    }

    init(role: String, content: ChatRequestContent?) {
        self.role = role
        self.content = content
        self.reasoningContent = nil
        self.toolCalls = nil
        self.toolCallID = nil
        self.responsesReasoningEcho = nil
    }

    static func assistant(
        content: String,
        reasoningContent: String? = nil,
        toolCalls: [ProviderToolCall] = [],
        responsesReasoningEcho: ResponsesReasoningEcho? = nil,
        nativeProtocolMetadata: NativeProtocolMetadata? = nil
    ) -> Self {
        var message = Self(
            role: "assistant",
            content: content.isEmpty ? nil : .text(content),
            reasoningContent: reasoningContent,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            toolCallID: nil,
            responsesReasoningEcho: responsesReasoningEcho
        )
        message.nativeProtocolMetadata = nativeProtocolMetadata
        return message
    }

    static func tool(callID: String, content: String, resultParts: [ToolResultPart]? = nil) -> Self {
        if let resultParts, resultParts.contains(where: { if case .artifact = $0 { return true } else { return false } }) {
            var parts: [ChatContentPart] = []
            if !content.isEmpty {
                parts.append(.text(content))
            }
            for part in resultParts {
                if case .artifact(let id, let role, let mime) = part {
                    parts.append(.artifact(id: id, semanticRole: role, mimeType: mime))
                }
            }
            return Self(role: "tool", content: .parts(parts), reasoningContent: nil, toolCalls: nil, toolCallID: callID, responsesReasoningEcho: nil)
        } else {
            return Self(role: "tool", content: .text(content), reasoningContent: nil, toolCalls: nil, toolCallID: callID, responsesReasoningEcho: nil)
        }
    }

    public init(
        role: String,
        content: ChatRequestContent?,
        reasoningContent: String? = nil,
        toolCalls: [ProviderToolCall]? = nil,
        toolCallID: String? = nil,
        responsesReasoningEcho: ResponsesReasoningEcho? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.responsesReasoningEcho = responsesReasoningEcho
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let content {
            try container.encode(content, forKey: .content)
        } else {
            try container.encodeNil(forKey: .content)
        }
        if let reasoningContent {
            try container.encode(reasoningContent, forKey: .reasoningContent)
        }
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

enum AgentStreamEvent: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String)
    case responsesReasoningEcho(ResponsesReasoningEcho)
    case nativeProtocolMetadata(NativeProtocolMetadata)
    case completed(finishReason: String? = nil)

    static var completed: AgentStreamEvent {
        .completed()
    }
}

struct ProviderToolCall: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        let name: String
        let arguments: String

        init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    let id: String
    let type = "function"
    let function: Function
    let finishReason: String?
    /// The max output tokens the request asked for, when the response used all of them.
    /// Some gateways report `tool_calls` for a cut-off call, so usage is the second witness.
    let reachedOutputTokenLimit: Int?

    init(id: String, function: Function, finishReason: String? = nil, reachedOutputTokenLimit: Int? = nil) {
        self.id = id
        self.function = function
        self.finishReason = finishReason
        self.reachedOutputTokenLimit = reachedOutputTokenLimit
    }

    static func finishReasonMeansOutputLimit(_ finishReason: String?) -> Bool {
        finishReason == "length" || finishReason == "max_tokens" || finishReason == "max_output_tokens"
    }

    var isTruncatedByOutputLimit: Bool {
        Self.finishReasonMeansOutputLimit(finishReason) || reachedOutputTokenLimit != nil
    }

    /// Told to the model in place of the tool result: nothing ran, and the call must be smaller.
    var outputLimitTruncationMessage: String {
        let limit = reachedOutputTokenLimit.map { "the output limit of \($0) tokens" } ?? "the output token limit"
        return "The response reached \(limit) (finish_reason: \(finishReason ?? "none")) before this tool call's arguments were complete, so the call was not executed and nothing was changed. Reasoning and tool arguments share this limit. Split the work into smaller tool calls: for a long file, write the first part, then add the rest in further calls."
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, function
    }
}

struct ChatToolDefinition: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: AnyCodable

        init(name: String, description: String, parameters: JSONSchema) {
            self.name = name
            self.description = description
            self.parameters = AnyCodable(parameters)
        }

        init(name: String, description: String, rawParameters: AnyCodable) {
            self.name = name
            self.description = description
            self.parameters = rawParameters
        }
    }

    struct JSONSchema: Encodable, Sendable {
        let type: String
        let properties: [String: Property]
        let required: [String]
        let additionalProperties: Bool

        init(type: String, properties: [String: Property], required: [String], additionalProperties: Bool) {
            self.type = type
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
        }
    }

    struct Property: Encodable, Sendable {
        let type: String
        let description: String
        var additionalProperties: ValueSchema? = nil

        init(type: String, description: String, additionalProperties: ValueSchema? = nil) {
            self.type = type
            self.description = description
            self.additionalProperties = additionalProperties
        }
    }

    struct ValueSchema: Encodable, Sendable {
        let type: String

        init(type: String) {
            self.type = type
        }
    }

    let type = "function"
    let function: Function

    init(function: Function) {
        self.function = function
    }
}

enum HarnessToolDefinitions {
    static let modelUseDefinition: ChatToolDefinition = definition(
        name: "model_use",
        description: "Discover user-approved runtime models (via list/search), run isolated text tasks (via run), or generate images with approved image-output models (via generate_image).",
        properties: [
            "action": .init(type: "string", description: "One of: list, search, run, generate_image."),
            "query": .init(type: "string", description: "Required for search. Matches model name, model ID, or Provider name."),
            "entry_id": .init(type: "string", description: "Exact composite entry_id returned by list/search; required for run and generate_image."),
            "prompt": .init(type: "string", description: "Explicit prompt text; required for run and generate_image."),
            "system_prompt": .init(type: "string", description: "Optional explicit system prompt for the isolated request (run only)."),
            "max_tokens": .init(type: "number", description: "Optional positive output limit (run only); defaults to 2048 and is capped at 8192 and the model limit."),
            "artifact_ids": .init(type: "array", description: "Optional array of UUID strings for input artifacts to attach (run only)."),
            "size": .init(type: "string", description: "Optional image size string for generate_image (e.g. 1024x1024)."),
            "quality": .init(type: "string", description: "Optional image quality string for generate_image (e.g. standard, hd)."),
        ],
        required: ["action"]
    )

    static let readImageDefinition: ChatToolDefinition = definition(
        name: "read_image",
        description: "Inspect an image file and return a detailed description and text transcription. Use when working with screenshots, charts, diagrams, or UI designs.",
        properties: [
            "path": .init(type: "string", description: "Image source. Accepted forms: an absolute path; a path relative to the working directory / Project folder; an attachment path (limare://attachments/<filename>); an Artifact URI (limare://artifacts/<UUID> or artifact://<UUID>); or a bare Artifact UUID. Tool-produced images are Artifacts, so their Artifact URI or UUID is a valid input here."),
            "prompt": .init(type: "string", description: "Optional specific question or instruction for the vision model inspecting the image."),
        ],
        required: ["path"]
    )

    static let fileListDefinition: ChatToolDefinition = definition(
        name: "file_list",
        description: "List files and directories. Relative paths resolve from the working directory / Project folder. Absolute paths may also be specified.",
        properties: [
            "path": .init(type: "string", description: "Relative or absolute directory path. Defaults to root ('.')."),
            "recursive": .init(type: "boolean", description: "Whether to list subdirectories recursively. Defaults to true."),
            "max_depth": .init(type: "number", description: "Maximum recursion depth (1-5, defaults to 5)."),
            "max_entries": .init(type: "number", description: "Maximum entries to return (1-500, defaults to 500)."),
        ],
        required: []
    )

    static let fileSearchDefinition: ChatToolDefinition = definition(
        name: "file_search",
        description: "Search for files by name or search UTF-8 text contents. Relative paths resolve from the working directory / Project folder. Absolute paths may also be specified.",
        properties: [
            "query": .init(type: "string", description: "Search query string or regex pattern."),
            "path": .init(type: "string", description: "Relative or absolute directory or file path to search in. Defaults to root ('.')."),
            "mode": .init(type: "string", description: "Search mode: 'content' (search file contents) or 'name' (match file names). Defaults to 'content'."),
            "regex": .init(type: "boolean", description: "Whether to treat query as a regular expression. Defaults to false."),
            "max_results": .init(type: "number", description: "Maximum search matches to return (1-100, defaults to 100)."),
        ],
        required: ["query"]
    )

    static let delegationResultDefinition: ChatToolDefinition = definition(
        name: "delegation_result", description: "Report your result to the parent agent. Call it once when you are done (or when told your limit is reached), then stop.",
        properties: ["summary": .init(type: "string", description: "Your findings or what you changed, with file paths and evidence."),
            "changed_files": .init(type: "array", description: "Files you changed, if any."),
            "blockers": .init(type: "array", description: "What is unfinished, unverified or blocked."),
            "partial": .init(type: "boolean", description: "True if the task is not fully done.")], required: ["summary"])

    static let delegateTaskDefinition: ChatToolDefinition = {
        let schema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "tasks": AnyCodable([
                    "type": AnyCodable("array"),
                    "description": AnyCodable("1 to 3 isolated, self-contained research tasks to execute concurrently."),
                    "minItems": AnyCodable(1),
                    "maxItems": AnyCodable(3),
                    "items": AnyCodable([
                        "type": AnyCodable("object"),
                        "properties": AnyCodable([
                            "title": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Short descriptive title of the subtask.")]),
                            "goal": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Specific question or problem the child agent should investigate.")]),
                            "context": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Concise relevant context needed for this subtask.")]),
                            "scope": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Specific files, modules, or domains to investigate.")]),
                            "constraints": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Explicit constraints or boundaries (e.g. what not to do).")]),
                            "expected_output": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Expected format and focus of the final report.")]),
                            "allow_web": AnyCodable(["type": AnyCodable("boolean"), "description": AnyCodable("Whether this subtask requires public web research.")]),
                            "workspace_scope": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("Optional workspace-relative directory where the subagent should start. Every subagent works in the whole Workspace.")]),
                            "task_effort": AnyCodable(["type": AnyCodable("string"), "enum": AnyCodable(["quick", "standard", "deep"]), "description": AnyCodable("Optional effort profile: 'quick' (120s / 8 turns), 'standard' (300s / 15 turns, default), or 'deep' (600s / 25 turns). This is each task's own allowance; at its limit the child gets one final turn without tools to report what it has.")])
                        ]),
                        "required": AnyCodable(["title", "goal"])
                    ])
                ])
            ]),
            "required": AnyCodable(["tasks"]),
            "additionalProperties": AnyCodable(false)
        ]
        return ChatToolDefinition(
            function: .init(
                name: "delegate_task",
                description: "Delegate 1–3 bounded read-only research tasks to isolated child agent sessions that execute concurrently. To delegate research on local materials, stage them into the current Workspace and specify 'workspace_scope' to narrow child containment. External host directories outside the workspace do not inherit parent authorization.",
                rawParameters: AnyCodable(schema)
            )
        )
    }()

    static let nativeDelegateTaskDefinition: ChatToolDefinition = {
        let normalized = try! JSONDecoder().decode(AnyCodable.self,
            from: JSONEncoder().encode(delegateTaskDefinition.function.parameters))
        var schema = normalized.dictionaryValue!
        var properties = schema["properties"]!.dictionaryValue!
        var tasks = properties["tasks"]!.dictionaryValue!
        var item = tasks["items"]!.dictionaryValue!
        var fields = item["properties"]!.dictionaryValue!
        fields["role"] = AnyCodable.from(json: ["type": "string", "enum": ["coding", "research"], "description": "research (default): investigates with file read/list/search, read_image and shell_execute (git log, grep, builds, tests), and the browser when allow_web is true; it has no file_write or file_edit and is told not to change files, though its shell is not technically read-only. coding: the same tools you have, to make and verify changes. Neither can delegate or use computer_use."])
        item["properties"] = AnyCodable(fields)
        tasks["items"] = AnyCodable(item)
        tasks["description"] = AnyCodable("1–3 subagent tasks, run in parallel.")
        properties["tasks"] = AnyCodable(tasks)
        properties["wait_seconds"] = AnyCodable.from(json: ["type": "number", "description": "How long this call waits before returning: it returns as soon as one task finishes, or after this many seconds with every task's progress. Default 30; 0 returns at once (use it when you have other work to do meanwhile). Between 10 and 3600 otherwise."])
        schema["properties"] = AnyCodable(properties)
        return ChatToolDefinition(function: .init(name: "delegate_task",
            description: "Start 1–3 subagents, each in its own conversation with the selected helper model, your workspace, your permission rules, the tools of its role, and the allowance its task_effort names. The call returns when one task finishes or wait_seconds pass, with each finished task's result and each running task's progress (time, model requests, tool calls, recent actions). Then keep working, wait again with delegation_control, redirect a task with continue, or cancel it and do the work yourself if it is slow or off track. Results you do not wait for are delivered to this conversation when they finish, so never poll. Subagents cannot delegate further.", rawParameters: AnyCodable(schema)))
    }()

    /// Codex's update_plan tool; its description texts are taken unchanged (openai/codex, Apache-2.0,
    /// codex-rs/core/src/tools/handlers/plan_spec.rs; LICENSES/codex-Apache-2.0.txt, LICENSES/codex-NOTICE.txt).
    static let updatePlanDefinition: ChatToolDefinition = ChatToolDefinition(function: .init(name: "update_plan",
        description: "Updates the task plan.\nProvide an optional explanation and a list of plan items, each with a step and status.\nAt most one step can be in_progress at a time.\n",
        rawParameters: AnyCodable.from(json: [
            "type": "object",
            "properties": [
                "explanation": ["type": "string", "description": "Optional explanation for this plan update."],
                "plan": ["type": "array", "description": "The list of steps", "items": [
                    "type": "object",
                    "properties": [
                        "step": ["type": "string", "description": "Task step text."],
                        "status": ["type": "string", "enum": ["pending", "in_progress", "completed"], "description": "Step status."]
                    ],
                    "required": ["step", "status"], "additionalProperties": false]]
            ],
            "required": ["plan"], "additionalProperties": false])))

    /// ask_user_question: schema shape follows Claude Code's AskUserQuestion; three sentences adapted
    /// from openai/codex (Apache-2.0) codex-rs/core/src/tools/handlers/request_user_input_spec.rs;
    /// LICENSES/codex-Apache-2.0.txt, LICENSES/codex-NOTICE.txt.
    static let askUserQuestionDefinition: ChatToolDefinition = ChatToolDefinition(function: .init(name: "ask_user_question",
        description: "Ask the user 1–4 multiple-choice questions in a card and wait for the answers before you continue. Use it when you reach a fork that is the user's to decide — a preference or trade-off you cannot settle from the request, the files or the environment — and the choice materially changes what you do next. Usually ask one question. Explore first: never ask what you can find out with your tools. Do not use it to ask permission to run a tool (Limare asks the user for approval on its own), never to ask for secrets such as keys or passwords, and not when a reasonable default exists (take it and say so). Put the option you recommend first and add \" (Recommended)\" at the end of its label. Do not add an \"Other\" option; the user can always write their own answer or skip. Do not also write the questions as text in your reply. If the user skips, continue with your best judgment and do not ask the same questions again.",
        rawParameters: AnyCodable.from(json: [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 4,
                    "description": "Questions to show the user (1–4; usually 1).",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "The complete question, ending with a question mark."],
                            "header": ["type": "string", "description": "Very short label shown as a chip (at most 12 characters)."],
                            "options": [
                                "type": "array",
                                "minItems": 2,
                                "maxItems": 4,
                                "description": "2–4 distinct choices. Put the recommended option first and add \" (Recommended)\" at the end of its label. Do not include an \"Other\" option; the client adds a free-form answer automatically.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "User-facing label (1–5 words)."],
                                        "description": ["type": "string", "description": "One short sentence explaining the impact or trade-off if selected."]
                                    ],
                                    "required": ["label", "description"],
                                    "additionalProperties": false
                                ]
                            ],
                            "multiSelect": ["type": "boolean", "description": "true lets the user select several options. Default false."]
                        ],
                        "required": ["question", "header", "options"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["questions"],
            "additionalProperties": false])))

    static let toolSearchDefinition = definition(name: "tool_search",
        description: "Load deferred tools (listed by name under DEFERRED TOOLS) so you can call them. Query \"select:name1,name2\" loads those tools; other queries load the best keyword matches. Returns the loaded tools' definitions; call them from your next step.",
        properties: [
            "query": .init(type: "string", description: "\"select:<tool names, comma separated>\" or search keywords"),
            "max_results": .init(type: "number", description: "For keyword queries: how many tools to load (default 5).")
        ], required: ["query"])

    static let delegationControlDefinition = definition(name: "delegation_control",
        description: "Wait for, check on, redirect or stop subagent tasks this conversation started. wait: returns when one of the tasks finishes or timeout_seconds pass, with results of finished tasks and progress of running ones; without task_id it waits on every running task. status: one task's progress or result. continue: give a running task an instruction, or run a finished task again with it. cancel: stop a task. Results you do not wait for are delivered to this conversation on their own.",
        properties: [
            "action": .init(type: "string", description: "wait, status, continue or cancel"),
            "task_id": .init(type: "string", description: "The task_id from delegate_task. Required except for wait."),
            "instruction": .init(type: "string", description: "The instruction for continue."),
            "timeout_seconds": .init(type: "number", description: "For wait: seconds to wait at most (default 30, 10 to 3600).")
        ], required: ["action"])

    static let workspaceTools: [ChatToolDefinition] = [
        definition(
            name: "shell_execute",
            description: "Run a shell command on this Mac. Relative paths resolve from the working directory / Project folder. It starts in that folder: do not `cd` into it — use relative or absolute paths, or `cwd` for another folder. Read, list and search files with file_read, file_list and file_search, not cat, head, tail, sed, ls, find or grep. Outside Full access it runs in a sandbox: it reads files, uses the network and can serve on local ports, but writes only to the working directory and temp, and cannot open apps or URLs (`open`) or use AppleScript. A command that needs more (fails with \"Operation not permitted\", or opens something for the user) sets sandbox_permissions to \"require_escalated\" with a justification, which asks for approval and then runs it outside the sandbox. A long-running server must run in the background with its output redirected to a file (`cmd > /tmp/log 2>&1 &`).",
            properties: [
                "command": .init(type: "string", description: "The exact zsh command to run."),
                "description": .init(type: "string", description: "Optional. What this command does in 5–10 words, in the language the user writes in (e.g. \"查看工作区状态\", \"Run the unit tests\"). The transcript shows it in place of the command; approvals always show the command itself."),
                "cwd": .init(type: "string", description: "Optional absolute or relative working directory."),
                "environment": .init(
                    type: "object",
                    description: "Optional environment variables to overlay for this process.",
                    additionalProperties: .init(type: "string")
                ),
                "timeout_seconds": .init(type: "number", description: "Optional timeout in seconds; defaults to 120."),
                "sandbox_permissions": .init(
                    type: "string",
                    description: "\"use_default\" (default) or \"require_escalated\" to run outside the sandbox once approved. Not needed in Full access."
                ),
                "justification": .init(type: "string", description: "With require_escalated: one sentence telling the user why the command needs it."),
            ],
            required: ["command"]
        ),
        fileReadDefinition,
        fileListDefinition,
        fileSearchDefinition,
        definition(
            name: "file_write",
            description: "Create or replace a UTF-8 text file on this Mac.",
            properties: [
                "path": .init(type: "string", description: "Absolute or relative file path."),
                "content": .init(type: "string", description: "Complete UTF-8 file content."),
            ],
            required: ["path", "content"]
        ),
        definition(
            name: "file_edit",
            description: "Replace one unique exact text occurrence in a UTF-8 file on this Mac.",
            properties: [
                "path": .init(type: "string", description: "Absolute or relative file path."),
                "old_text": .init(type: "string", description: "Exact existing text; it must occur once."),
                "new_text": .init(type: "string", description: "Replacement text."),
            ],
            required: ["path", "old_text", "new_text"]
        ),
        attachmentCopyDefinition,
        resourceConvertDefinition,
        artifactAcquireDefinition,
        artifactRegisterDefinition,
        toolResultReadDefinition
    ]

    static let toolResultReadDefinition: ChatToolDefinition = definition(
        name: "tool_result_read",
        description: "Retrieve the original canonical result and execution details of a previously executed tool call after its working-set representation has been reduced to an offload stub.",
        properties: [
            "call_id": .init(type: "string", description: "The exact Call ID of the historical tool call to retrieve.")
        ],
        required: ["call_id"]
    )

    static let artifactAcquireDefinition: ChatToolDefinition = definition(
        name: "artifact_acquire",
        description: "Explicitly acquire an external host file into conversation-scoped artifact storage. Evaluates permission and snapshots the file for durable downstream processing.",
        properties: [
            "path": .init(type: "string", description: "Absolute or home-relative path of the host file to acquire.")
        ],
        required: ["path"]
    )

    static let artifactRegisterDefinition: ChatToolDefinition = definition(
        name: "artifact_register",
        description: "Register a workspace-generated or workspace-contained file into conversation-scoped artifact storage with SHA-256 integrity and provenance. A registered file is delivered to the user: it appears as a file card on your reply that opens a preview, so use this to send the user a file you made.",
        properties: [
            "path": .init(type: "string", description: "Workspace-relative or absolute path to the file to register."),
            "description": .init(type: "string", description: "Optional description of the registered artifact.")
        ],
        required: ["path"]
    )

    static let attachmentCopyDefinition: ChatToolDefinition = definition(
        name: "attachment_copy",
        description: "Copy a chat attachment (limare://attachments/<filename>) into the working directory or Project folder to inspect or process it with Shell, scripts, Skills, or MCP tools. Only call this when local processing is needed.",
        properties: [
            "source": .init(
                type: "string",
                description: "Source attachment URI (must start with limare://attachments/)."
            ),
            "destination": .init(
                type: "string",
                description: "Optional relative destination path (e.g. '.limare-input/demo.mp4'). If omitted, defaults to '.limare-input/<filename>'."
            ),
        ],
        required: ["source"]
    )

    static let resourceConvertDefinition: ChatToolDefinition = definition(
        name: "resource_convert",
        description: "Obtain a bounded derived representation of a conversation resource. Use this when its content is needed in another representation. Available conversions are decided by this runtime's policies.",
        properties: [
            "source": .init(type: "string", description: "Conversation attachment URI or conversation-scoped Artifact URI supported by this runtime."),
            "target_mime": .init(type: "string", description: "Desired representation MIME type. Accepted values depend on the source and runtime conversion policies. A source/target pair with no matching policy is unsupported."),
        ],
        required: ["source", "target_mime"]
    )

    static let fileReadDefinition = definition(
        name: "file_read",
        description: "Read bounded UTF-8 text from a local file or limare:// attachment. A local image file (PNG, JPEG, HEIC…) is returned as the image itself; other binary attachments return metadata only. Large files: read them in parts with offset and limit; a cut-off result says where to continue.",
        properties: [
            "path": .init(type: "string", description: "Absolute path, relative path, or limare://attachments/<filename>."),
            "offset": .init(type: "number", description: "Optional. 1-based line to start reading at."),
            "limit": .init(type: "number", description: "Optional. Maximum number of lines to read."),
        ],
        required: ["path"]
    )

    static let browserUseDefinition: ChatToolDefinition = definition(
        name: "browser_use",
        description: "Interact with the built-in Limare web browser. Control web pages via navigation, reading text/DOM, clicking, typing, scrolling, and taking screenshots.",
        properties: [
            "action": .init(type: "string", description: "The browser action: navigate, get_page_info, get_text, get_readable, find_elements, click, type, scroll, screenshot, wait_for_dom_stable."),
            "url": .init(type: "string", description: "URL to navigate to: http/https (a local dev server such as http://localhost:5173 included), or a local file as file:// or an absolute path (a built index.html, a report). Required for navigate."),
            "selector": .init(type: "string", description: "CSS selector for target element. Required for click and type; optional for get_text, find_elements, scroll."),
            "text": .init(type: "string", description: "Text to input. Required for type."),
            "direction": .init(type: "string", description: "Scroll direction: 'up' or 'down'. Defaults to 'down'."),
            "amount": .init(type: "number", description: "Scroll amount in pixels (1-5000). Defaults to 600."),
            "timeout_seconds": .init(type: "number", description: "Timeout in seconds for wait_for_dom_stable (1-20, default 10)."),
        ],
        required: ["action"]
    )

    static let researchBrowserUseDefinition: ChatToolDefinition = definition(
        name: "browser_use",
        description: "Interact with the web browser for read-only research. Inspect web pages via navigation, reading text/DOM, finding links, scrolling, and taking screenshots. Modifying web pages (click, type) is strictly forbidden.",
        properties: [
            "action": .init(type: "string", description: "The read-only browser action: navigate, get_page_info, get_text, get_readable, find_elements, scroll, screenshot, wait_for_dom_stable."),
            "url": .init(type: "string", description: "URL to navigate to: http/https (a local dev server such as http://localhost:5173 included), or a local file as file:// or an absolute path (a built index.html, a report). Required for navigate."),
            "selector": .init(type: "string", description: "CSS selector for target element. Optional for get_text, find_elements, scroll."),
            "direction": .init(type: "string", description: "Scroll direction: 'up' or 'down'. Defaults to 'down'."),
            "amount": .init(type: "number", description: "Scroll amount in pixels (1-5000). Defaults to 600."),
            "timeout_seconds": .init(type: "number", description: "Timeout in seconds for wait_for_dom_stable (1-20, default 10)."),
        ],
        required: ["action"]
    )

    static let computerUseV2Definition: ChatToolDefinition = definition(
        name: "computer_use",
        description: "Operate macOS apps through their accessibility tree, in the background by default. launch_app opens an app and returns its window; capture observes a window. Every result includes the window's current elements with references (e1, e2, ...); use the references from the most recent result in the next action. Each app asks the user for permission once per conversation. Password managers, Keychain, System Settings and password fields are off limits: ask the user to do those steps. list_windows needs a pid or target_app. If an app is launched but has no window yet (launchedAwaitingWindow), use capture(target_app) instead of launching again.",
        properties: [
            "action": .init(type: "string", description: "The action kind: launch_app, list_apps, list_windows, capture, click, double_click, right_click, type, key, set_value, scroll, drag, wait."),
            "target_app": .init(type: "string", description: "Target application bundle identifier (e.g. 'com.apple.calculator') or application name."),
            "pid": .init(type: "number", description: "Process ID for list_windows or targeting."),
            "window_id": .init(type: "number", description: "Window ID for targeting."),
            "element": .init(type: "string", description: "Opaque element reference identifier (e.g. 'e1', 'e2') from current window observation."),
            "text": .init(type: "string", description: "Text content to type into the target element or window."),
            "key": .init(type: "string", description: "Key name to press (e.g. 'return', 'tab', 'escape', 'space')."),
            "keys": .init(type: "array", description: "Key combinations or modifier keys to press (e.g. ['cmd', 'c'])."),
            "value": .init(type: "string", description: "Value to set directly on the target element."),
            "direction": .init(type: "string", description: "Scroll direction: up, down, left, right."),
            "amount": .init(type: "number", description: "Scroll notches or amount (default 3)."),
            "from_element": .init(type: "string", description: "Source element reference for drag (or use element)."),
            "to_element": .init(type: "string", description: "Destination element reference for drag."),
            "duration_ms": .init(type: "number", description: "Duration in milliseconds for wait (default 1000)."),
            "delivery_mode": .init(type: "string", description: "'background' (default) acts without stealing focus; 'foreground' brings the window to the front first."),
        ],
        required: ["action"]
    )

    /// The actions mcp_manage offers; the executor dispatches every one of them.
    static let mcpManageActions = ["list", "status", "create", "patch", "remove", "enable", "disable", "reconnect", "authenticate", "logout"]

    /// Every argument mcp_manage accepts; the executor rejects any other field.
    static let mcpManageProperties: [String: ChatToolDefinition.Property] = {
        var properties: [String: ChatToolDefinition.Property] = [
            "action": .init(type: "string", description: mcpManageActions.joined(separator: ", ")),
            "server_id": .init(type: "string", description: "Server ID; required except for list."),
            "expected_revision": .init(type: "integer", description: "Current configuration_revision from list, required for mutating actions."),
            "request_id": .init(type: "string", description: "UUID idempotency identifier, required for mutating actions."),
            "transport": .init(type: "string", description: "create only: http or stdio."),
            "url": .init(type: "string", description: "create only: absolute HTTP endpoint, without credentials."),
            "command": .init(type: "string", description: "create only: stdio executable."),
            "args": .init(type: "array", description: "create only: public stdio arguments."),
            "set": .init(type: "object", description: "patch only: \(MCPStore.patchableFields.sorted().joined(separator: ", ")). Dictionaries merge by key; credential references only; oauth accepts clientId only."),
            "remove": .init(type: "array", description: "patch only: fields or env.NAME/headers.NAME entries to remove explicitly.")
        ]
        // Offered only when a profile can be used in this build.
        let profiles = MCPServerProfile.available.map(\.rawValue)
        if !profiles.isEmpty {
            properties["profile"] = .init(type: "string", description: "create only, instead of transport/url/command: a product profile with a fixed endpoint and OAuth sign-in through the user's own app (\(profiles.joined(separator: ", "))). The public client ID can be set with patch oauth.clientId; the user enters the client secret in Limare.")
        }
        return properties
    }()

    static let mcpManageDefinition: ChatToolDefinition = definition(
        name: "mcp_manage",
        description: """
        Manage MCP servers in Limare. MCP servers give you extra tools (e.g. GitHub, databases, docs). Actions: \(mcpManageActions.joined(separator: ", ")).
        How to connect a server for the user:
        1. list: see what exists and get configuration_revision. Mutations need expected_revision and a new UUID request_id (reuse a request_id only to re-read that result).
        2. create: a local server (transport stdio, command + args of a program installed on this Mac) or a remote one (transport http, url). mcp_manage cannot install software. Check with the shell whether a local server's program is installed; if it is missing, give the user the install command to run in Terminal.
        3. Credentials (tokens, API keys) only as references: patch set env {"NAME": "${secret:NAME}"} (local) or headers {"Authorization": "${secret:Authorization}"} (remote). Then call authenticate: Limare asks the user for each value in its own secure window (with Touch ID) and stores it privately. Never ask the user to paste a secret into the conversation and never put one in tool arguments. Tell the user which kind of token to create and with what minimal permissions.
        4. status: transport/auth state, missing_credentials and next_action; follow next_action. A connected server's tools appear from the next turn.
        Users can do the same in Settings → MCP. Do not edit configuration files or install via shell.
        """,
        properties: mcpManageProperties,
        required: ["action"]
    )

    /// Every argument schedule_manage accepts; the executor rejects any other field.
    static let scheduleManageProperties: [String: ChatToolDefinition.Property] = [
        "action": .init(type: "string", description: "One of: list, create, update, delete, run_now."),
        "task_id": .init(type: "string", description: "The task's id from list; required for update, delete and run_now."),
        "name": .init(type: "string", description: "Short display name in the user's language."),
        "prompt": .init(type: "string", description: "The instruction each run sends as a user message. With target new_conversation a run starts with none of this conversation's context, so make it self-contained: what to do, sources, output format and language."),
        "repeat": .init(type: "string", description: "Required for create: once, daily, weekdays (Mon–Fri), weekly, every_n_hours or monthly."),
        "time": .init(type: "string", description: "Local time HH:mm for daily, weekdays, weekly and monthly (default 09:00); for every_n_hours only the minute is used."),
        "weekdays": .init(type: "string", description: "weekly only: comma-separated days, e.g. \"mon,wed,fri\"."),
        "interval_hours": .init(type: "number", description: "every_n_hours only: 1 to 24."),
        "day_of_month": .init(type: "number", description: "monthly only: 1 to 31."),
        "fire_at": .init(type: "string", description: "once only: a future moment, ISO 8601 with offset (e.g. 2026-10-24T15:30:00+08:00)."),
        "target": .init(type: "string", description: "new_conversation (default): every run opens a new conversation in this conversation's project. this_conversation: every run posts the prompt here."),
        "enabled": .init(type: "boolean", description: "update only: false pauses the task, true resumes it."),
        "notify": .init(type: "string", description: "completion_and_failure (default) or failure_only."),
    ]

    static let scheduleManageDefinition: ChatToolDefinition = definition(
        name: "schedule_manage",
        description: """
        Manage Limare's scheduled tasks (the Schedules page): a prompt that runs by itself once at a future moment or on a repeating rule. Use it when the user asks for something to happen later or repeatedly ("every day at 9", "tomorrow at 3pm"); if the time or the content is unclear, ask first. Times are the user's local time zone.
        Runs happen only while Limare is running (a missed run is caught up once on the next launch). A run is unattended: steps that need approval are refused, so the prompt should only need what the current permission mode allows. Each run's result is a conversation plus a macOS notification; Limare cannot send email or messages unless a tool for that is available in the run.
        After create, tell the user the name, the rule and the next run time from the result; they can edit, pause or run it from Schedules in the sidebar.
        """,
        properties: scheduleManageProperties,
        required: ["action"]
    )

    static var all: [ChatToolDefinition] {
        workspaceTools + [readImageDefinition, browserUseDefinition, delegateTaskDefinition, mcpManageDefinition, scheduleManageDefinition]
    }

    private static func definition(
        name: String,
        description: String,
        properties: [String: ChatToolDefinition.Property],
        required: [String]
    ) -> ChatToolDefinition {
        ChatToolDefinition(
            function: .init(
                name: name,
                description: description,
                parameters: .init(
                    type: "object",
                    properties: properties,
                    required: required,
                    additionalProperties: false
                )
            )
        )
    }
}
