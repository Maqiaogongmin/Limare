import Foundation

enum PermissionMode: String, CaseIterable, Codable, Sendable {
    case requestApproval
    case helpMeApprove
    case fullAccess

    var displayName: String {
        switch self {
        case .requestApproval: String(localized: "Ask for approval")
        case .helpMeApprove: String(localized: "Approve for me")
        case .fullAccess: String(localized: "Full access")
        }
    }

    var detail: String {
        switch self {
        case .requestApproval:
            String(localized: "Shell commands run in a sandbox without asking: they read and use the network, but write only in the Workspace and temp. Asks you before a command runs outside the sandbox or a file tool reaches outside the Workspace.")
        case .helpMeApprove:
            String(localized: "The same sandbox. Requests that need more access are reviewed automatically.")
        case .fullAccess:
            String(localized: "Runs commands outside the sandbox and reaches files outside the Workspace without approval.")
        }
    }
}

public enum PermissionTriggerReason: String, Sendable, Codable, Equatable {
    case sensitivePath = "sensitive_path"
    case highRiskCommand = "high_risk_command"
    case networkAccess = "network_access"
    case outsideWorkspace = "outside_workspace"
    case boundarySensitiveTool = "boundary_sensitive_tool"
}

public struct PermissionTrigger: Sendable, Codable, Equatable {
    public let reason: PermissionTriggerReason
    public let detail: String

    public init(reason: PermissionTriggerReason, detail: String) {
        self.reason = reason
        self.detail = detail
    }
}

public struct ToolPermissionRequest: Sendable {
    /// Stable identity for this one human-approval decision. It is independent
    /// of queue position and of any replacement conversation run.
    public let requestID: UUID
    public let conversationID: UUID?
    public let runID: UUID?
    public let conversationTitle: String?
    public let toolName: String
    public let summary: String
    public let workspaceURL: URL?
    public let affectedURLs: [URL]
    public let command: String?
    public let reviewerSafeCommand: String?
    public let environmentKeys: [String]
    public let requestsNetwork: Bool
    public let isHighRisk: Bool
    /// A shell command that asks to run outside the sandbox (`require_escalated`).
    public let leavesSandbox: Bool

    public init(
        requestID: UUID = UUID(),
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        conversationTitle: String? = nil,
        toolName: String,
        summary: String,
        workspaceURL: URL?,
        affectedURLs: [URL] = [],
        command: String? = nil,
        reviewerSafeCommand: String? = nil,
        environmentKeys: [String] = [],
        requestsNetwork: Bool = false,
        isHighRisk: Bool = false,
        leavesSandbox: Bool = false
    ) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.runID = runID
        self.conversationTitle = conversationTitle
        self.toolName = toolName
        self.summary = summary
        self.workspaceURL = workspaceURL
        self.affectedURLs = affectedURLs
        self.command = command
        self.reviewerSafeCommand = reviewerSafeCommand ?? command
        self.environmentKeys = environmentKeys
        self.requestsNetwork = requestsNetwork
        self.isHighRisk = isHighRisk
        self.leavesSandbox = leavesSandbox
    }

    public func attributed(
        conversationID: UUID,
        runID: UUID,
        conversationTitle: String?
    ) -> ToolPermissionRequest {
        ToolPermissionRequest(
            requestID: requestID,
            conversationID: conversationID,
            runID: runID,
            conversationTitle: conversationTitle,
            toolName: toolName,
            summary: summary,
            workspaceURL: workspaceURL,
            affectedURLs: affectedURLs,
            command: command,
            reviewerSafeCommand: reviewerSafeCommand,
            environmentKeys: environmentKeys,
            requestsNetwork: requestsNetwork,
            isHighRisk: isHighRisk,
            leavesSandbox: leavesSandbox
        )
    }
}

public enum PermissionEvaluation: Sendable, Equatable {
    case allowed
    case requiresApproval(reason: String, triggers: [PermissionTrigger])

    public static func requiresApproval(reason: String) -> PermissionEvaluation {
        .requiresApproval(reason: reason, triggers: [])
    }
}

public enum AutoReviewDecision: Sendable, Equatable {
    case approve(rationale: String)
    case deny(rationale: String)
    case needsUserReview(reason: String)
}

public struct PermissionReviewContext: Sendable {
    public let provider: ProviderConfiguration
    public let apiKey: String
    public let modelID: String

    public init(provider: ProviderConfiguration, apiKey: String, modelID: String) {
        self.provider = provider
        self.apiKey = apiKey
        self.modelID = modelID
    }
}

public enum TurnReviewContext {
    @TaskLocal public static var activeReviewer: (any PermissionReviewing)?
}

@MainActor
public protocol PermissionReviewing: AnyObject, Sendable {
    func review(request: ToolPermissionRequest, reason: String) async -> AutoReviewDecision
}

struct PendingApproval: Identifiable, Sendable {
    let id: UUID
    let requestID: UUID
    let conversationID: UUID?
    let runID: UUID?
    let conversationTitle: String?
    let toolName: String
    let summary: String
    let reason: String
    let details: String
    let command: String?
    let affectedPaths: [String]
    let environmentKeys: [String]
    let requestsNetwork: Bool
    let isHighRisk: Bool

    init(
        id: UUID = UUID(),
        requestID: UUID,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        conversationTitle: String? = nil,
        toolName: String,
        summary: String,
        reason: String,
        details: String,
        command: String? = nil,
        affectedPaths: [String] = [],
        environmentKeys: [String] = [],
        requestsNetwork: Bool = false,
        isHighRisk: Bool = false
    ) {
        self.id = id
        self.requestID = requestID
        self.conversationID = conversationID
        self.runID = runID
        self.conversationTitle = conversationTitle
        self.toolName = toolName
        self.summary = summary
        self.reason = reason
        self.details = details
        self.command = command
        self.affectedPaths = affectedPaths
        self.environmentKeys = environmentKeys
        self.requestsNetwork = requestsNetwork
        self.isHighRisk = isHighRisk
    }
}

public enum ToolApprovalState: String, Codable, Sendable {
    case notRequired
    case awaitingApproval
    case approved
    case denied
}
