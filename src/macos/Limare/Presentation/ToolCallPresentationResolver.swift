import Foundation

enum ToolCallTone: String, Sendable, Equatable {
    case neutral
    case active
    case success
    case warning
    case danger
}

struct ToolCallPresentationModel: Sendable, Equatable {
    let displayToolName: String
    let namespaceLabel: String?
    let summary: String?
    let tone: ToolCallTone
    let symbolName: String

    init(
        displayToolName: String,
        namespaceLabel: String? = nil,
        summary: String? = nil,
        tone: ToolCallTone,
        symbolName: String
    ) {
        self.displayToolName = displayToolName
        self.namespaceLabel = namespaceLabel
        self.summary = summary
        self.tone = tone
        self.symbolName = symbolName
    }
}

public struct DelegatedRunPresentation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let status: AgentRunStatus
    public let modelAttribution: String
    public let currentActivity: String?
    public let summary: String?
    public let error: String?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        id: UUID,
        title: String,
        status: AgentRunStatus,
        modelAttribution: String = "",
        currentActivity: String? = nil,
        summary: String? = nil,
        error: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.modelAttribution = modelAttribution
        self.currentActivity = currentActivity
        self.summary = summary
        self.error = error
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

}

enum ToolCallPresentationResolver {

    static func resolve(
        toolCall: ToolCallRecord,
        runs: [DelegatedRunPresentation]? = nil
    ) -> ToolCallPresentationModel {
        let (displayToolName, namespaceLabel) = resolveToolNames(name: toolCall.name)
        let summary = resolveSummary(name: toolCall.name, input: toolCall.input)

        let tone: ToolCallTone
        let symbolName: String

        if toolCall.name == "delegate_task" || toolCall.name.hasSuffix("delegate_task") {
            let effectiveRuns = runs ?? extractDelegatedRuns(from: toolCall.output)
            (tone, symbolName) = resolveDelegatedToneAndSymbol(
                state: toolCall.state,
                runs: effectiveRuns,
                output: toolCall.output
            )
        } else {
            (tone, symbolName) = resolveToneAndSymbol(state: toolCall.state, toolName: toolCall.name)
        }

        return ToolCallPresentationModel(
            displayToolName: displayToolName,
            namespaceLabel: namespaceLabel,
            summary: summary,
            tone: tone,
            symbolName: symbolName
        )
    }

    static func resolveToolNames(name: String) -> (displayName: String, namespaceLabel: String?) {
        if let (serverID, toolName) = MCPToolNamespace.parse(exposedName: name) {
            return (toolName, "MCP: \(serverID)")
        }
        return (name, nil)
    }

    static func resolveSummary(name: String, input: String) -> String? {
        guard !input.isEmpty, input != "Receiving arguments…" else { return nil }
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if name == "shell_execute" || name.hasSuffix("shell_execute") {
            if let command = json["command"] as? String {
                return "$ \(command)"
            }
        }

        if name.contains("file_") {
            if let path = json["path"] as? String {
                return path
            }
        }

        if name == "model_use" || name.hasSuffix("model_use") {
            let action = json["action"] as? String ?? ""
            if action == "generate_image", let prompt = json["prompt"] as? String {
                return "generate_image: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else if action == "run", let prompt = json["prompt"] as? String {
                return "run: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else if action == "search", let query = json["query"] as? String {
                return "search: \(query.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else if !action.isEmpty {
                return action
            }
        }

        if name == "browser_use" || name.hasSuffix("browser_use") {
            let action = json["action"] as? String ?? ""
            if action == "navigate", let url = json["url"] as? String {
                return "navigate: \(url)"
            } else if action == "click", let sel = json["selector"] as? String {
                return "click: \(sel)"
            } else if action == "type", let sel = json["selector"] as? String {
                return "type: \(sel)"
            } else if !action.isEmpty {
                return action
            }
        }

        return nil
    }

    static func resolveToneAndSymbol(
        state: ToolExecutionState,
        toolName: String = ""
    ) -> (tone: ToolCallTone, symbol: String) {
        let isBrowser = toolName == "browser_use" || toolName.hasSuffix("browser_use")
        switch state {
        case .queued:
            return (.neutral, isBrowser ? "globe" : "clock")
        case .awaitingApproval:
            return (.warning, "exclamationmark.shield.fill")
        case .running:
            return (.active, isBrowser ? "globe" : "progress.indicator")
        case .completed:
            return (.success, isBrowser ? "globe" : "checkmark.circle.fill")
        case .failed:
            return (.danger, "xmark.circle.fill")
        case .timedOut:
            return (.danger, "timer")
        case .cancelled:
            return (.warning, "stop.circle.fill")
        case .denied:
            return (.danger, "hand.raised.fill")
        case .interrupted:
            return (.warning, "exclamationmark.triangle.fill")
        }
    }

    static func resolveDelegatedToneAndSymbol(
        state: ToolExecutionState,
        runs: [DelegatedRunPresentation] = [],
        output: String = ""
    ) -> (tone: ToolCallTone, symbol: String) {
        switch state {
        case .queued:
            return (.neutral, "clock")
        case .awaitingApproval:
            return (.warning, "exclamationmark.shield.fill")
        case .running:
            return (.active, "progress.indicator")
        case .denied:
            return (.danger, "hand.raised.fill")
        case .interrupted:
            return (.warning, "exclamationmark.triangle.fill")
        case .cancelled:
            return (.warning, "stop.circle.fill")
        case .timedOut:
            return (.danger, "timer")
        case .failed:
            return (.danger, "xmark.circle.fill")
        case .completed:
            if !runs.isEmpty {
                let completedCount = runs.filter { $0.status == .completed }.count
                let timedOutCount = runs.filter { $0.status == .timedOut }.count
                let cancelledCount = runs.filter { $0.status == .cancelled }.count

                if completedCount == runs.count {
                    return (.success, "checkmark.circle.fill")
                } else if completedCount > 0 {
                    return (.warning, "exclamationmark.triangle.fill")
                } else if timedOutCount == runs.count {
                    return (.danger, "timer")
                } else if cancelledCount == runs.count {
                    return (.warning, "stop.circle.fill")
                } else {
                    return (.danger, "xmark.circle.fill")
                }
            }

            // Fallback to top-level aggregate status in output JSON if runs array is empty
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                switch status {
                case "failed":
                    return (.danger, "xmark.circle.fill")
                case "timed_out":
                    return (.danger, "timer")
                case "cancelled":
                    return (.warning, "stop.circle.fill")
                case "completed_with_issues":
                    return (.warning, "exclamationmark.triangle.fill")
                case "completed":
                    return (.success, "checkmark.circle.fill")
                default:
                    break
                }
            }

            return (.success, "checkmark.circle.fill")
        }
    }

    /// Safely extracts delegated run presentation snapshots from delegated task output JSON.
    static func extractDelegatedRuns(from toolCallOutput: String) -> [DelegatedRunPresentation] {
        guard let data = toolCallOutput.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runsList = obj["runs"] as? [[String: Any]] else {
            return []
        }
        let isoFormatter = ISO8601DateFormatter()
        return runsList.compactMap { dict in
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let title = dict["title"] as? String,
                  let statusRaw = dict["status"] as? String else {
                return nil
            }
            let status: AgentRunStatus
            if statusRaw == "timed_out" || statusRaw == "timedOut" {
                status = .timedOut
            } else if let parsed = AgentRunStatus(rawValue: statusRaw) {
                status = parsed
            } else {
                return nil
            }
            let model = dict["model"] as? String ?? ""
            let report = dict["report"] as? String
            let error = dict["error"] as? String
            let startedAt = (dict["started_at"] as? String).flatMap { isoFormatter.date(from: $0) }
            let completedAt = (dict["completed_at"] as? String).flatMap { isoFormatter.date(from: $0) }
            return DelegatedRunPresentation(
                id: id,
                title: title,
                status: status,
                modelAttribution: model,
                currentActivity: nil,
                summary: report,
                error: error,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }
    }

    /// Safely extracts child run UUIDs from delegated task output JSON.
    static func extractDelegatedRunIDs(from toolCallOutput: String) -> Set<UUID> {
        let runs = extractDelegatedRuns(from: toolCallOutput)
        if !runs.isEmpty {
            return Set(runs.map(\.id))
        }
        guard let data = toolCallOutput.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runsList = obj["runs"] as? [[String: Any]] else {
            return []
        }
        return Set(runsList.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
    }
}
