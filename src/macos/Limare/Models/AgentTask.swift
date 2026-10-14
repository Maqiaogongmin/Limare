import Foundation

enum AgentTaskValidationError: LocalizedError, Equatable {
    case emptyTitle
    case emptyGoal
    case contextExceedsLimit(count: Int, limit: Int)
    case invalidWorkspaceScope(String)
    case invalidTaskEffort(String)

    var errorDescription: String? {
        switch self {
        case .emptyTitle:
            "Task title cannot be empty."
        case .emptyGoal:
            "Task goal cannot be empty."
        case .contextExceedsLimit(let count, let limit):
            "Task context is too large (\(count) chars, limit is \(limit)). Please provide a smaller self-contained research task."
        case .invalidWorkspaceScope(let msg):
            "Invalid workspace_scope: \(msg)"
        case .invalidTaskEffort(let msg):
            "Invalid task_effort: \(msg)"
        }
    }
}

public struct AgentTask: Identifiable, Codable, Sendable, Equatable {
    public static let maxCharacterLimit = 12_000

    public let id: UUID
    public let title: String
    public let goal: String
    public let context: String
    public let scope: String
    public let constraints: String?
    public let expectedOutput: String?
    public let allowWebResearch: Bool
    public let workspaceScope: String?
    public let taskEffort: String?

    public init(
        id: UUID = UUID(),
        title: String,
        goal: String,
        context: String = "",
        scope: String = "",
        constraints: String? = nil,
        expectedOutput: String? = nil,
        allowWebResearch: Bool = false,
        workspaceScope: String? = nil,
        taskEffort: String? = nil
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        self.constraints = constraints?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expectedOutput = expectedOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowWebResearch = allowWebResearch
        let trimmedWs = workspaceScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceScope = (trimmedWs?.isEmpty == true) ? nil : trimmedWs
        let trimmedEffort = taskEffort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.taskEffort = (trimmedEffort?.isEmpty == true) ? nil : trimmedEffort
    }

    public var totalCharacterCount: Int {
        title.count + goal.count + context.count + scope.count + (constraints?.count ?? 0) + (expectedOutput?.count ?? 0) + (workspaceScope?.count ?? 0) + (taskEffort?.count ?? 0)
    }

    public func validate() throws {
        guard !title.isEmpty else {
            throw AgentTaskValidationError.emptyTitle
        }
        guard !goal.isEmpty else {
            throw AgentTaskValidationError.emptyGoal
        }
        if let ws = workspaceScope {
            if ws.hasPrefix("/") {
                throw AgentTaskValidationError.invalidWorkspaceScope("Path must be workspace-relative and cannot start with '/'.")
            }
            if ws.components(separatedBy: "/").contains("..") {
                throw AgentTaskValidationError.invalidWorkspaceScope("Path cannot contain directory traversal '..'.")
            }
        }
        if let effort = taskEffort {
            guard AgentTaskEffortProfile(rawValue: effort) != nil else {
                throw AgentTaskValidationError.invalidTaskEffort("Unknown task_effort '\(effort)'. Allowed values: quick, standard, deep.")
            }
        }
        let total = totalCharacterCount
        guard total <= Self.maxCharacterLimit else {
            throw AgentTaskValidationError.contextExceedsLimit(count: total, limit: Self.maxCharacterLimit)
        }
    }
}
