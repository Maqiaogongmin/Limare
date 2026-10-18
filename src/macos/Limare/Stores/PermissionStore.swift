import Foundation
import Observation

@MainActor
@Observable
final class PermissionStore {
    /// Called when an approval request is shown (the Background Alerts notifier listens).
    @ObservationIgnored var onApprovalPresented: ((PendingApproval) -> Void)?
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let defaultsKey: String

    var mode: PermissionMode {
        didSet {
            defaults.set(mode.rawValue, forKey: defaultsKey)
            logs.info("Permission", "Permission mode changed to \(mode.displayName).")
            onModeChanged?(mode)
        }
    }

    var onModeChanged: ((PermissionMode) -> Void)?

    private(set) var pendingApproval: PendingApproval?

    private struct QueuedApproval {
        let id: UUID
        let approval: PendingApproval
        let continuation: CheckedContinuation<Bool, Never>
    }

    @ObservationIgnored
    private var approvalQueue: [QueuedApproval] = []

    @ObservationIgnored
    private var autoReviewer: PermissionReviewing?

    private let logs: DebugLogStore
    init(
        logs: DebugLogStore,
        defaults: UserDefaults = .standard,
        defaultsKey: String = "permissionMode",
        initialMode: PermissionMode? = nil,
        autoReviewer: PermissionReviewing? = nil
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        let stored = defaults.string(forKey: defaultsKey)
        self.mode = initialMode ?? PermissionMode(rawValue: stored ?? "") ?? .requestApproval
        self.autoReviewer = autoReviewer
        self.logs = logs
    }

    func setAutoReviewer(_ reviewer: PermissionReviewing?) {
        self.autoReviewer = reviewer
    }

    func authorize(
        _ request: ToolPermissionRequest,
        allowedReadDirectories: [URL] = [],
        memoryLocations: [URL] = [],
        reviewer: (any PermissionReviewing)? = nil
    ) async -> ToolApprovalState {
        await authorizePrimaryPolicy(request, allowedReadDirectories: allowedReadDirectories, memoryLocations: memoryLocations, reviewer: reviewer)
    }

    /// Why a request was denied, in words the model can act on; read once by the tool that asked.
    private var denialReasons: [UUID: String] = [:]

    func takeDenialReason(requestID: UUID) -> String? { denialReasons.removeValue(forKey: requestID) }

    private func denied(_ request: ToolPermissionRequest, _ reason: String) -> ToolApprovalState {
        denialReasons[request.requestID] = reason
        return .denied
    }

    private func authorizePrimaryPolicy(
        _ request: ToolPermissionRequest,
        allowedReadDirectories: [URL],
        memoryLocations: [URL],
        reviewer: (any PermissionReviewing)?
    ) async -> ToolApprovalState {
        // Full Access directly bypasses normal approval gate
        if mode == .fullAccess {
            logs.info("Permission", "Full Access active; bypassed approval for \(request.toolName).")
            return .notRequired
        }

        let evaluation = PermissionEvaluator.evaluate(request, allowedReadDirectories: allowedReadDirectories, memoryLocations: memoryLocations)
        switch evaluation {
        case .allowed:
            return .notRequired
        case .requiresApproval(let reason, _):
            logs.info("Permission", "Boundary approval required for \(request.toolName) [mode=\(mode.displayName)]: \(reason)")

            let effectiveReviewer = reviewer ?? TurnReviewContext.activeReviewer ?? autoReviewer
            if mode == .helpMeApprove, let effectiveReviewer {
                let reviewDecision = await effectiveReviewer.review(request: request, reason: reason)
                switch reviewDecision {
                case .approve(let rationale):
                    logs.info("Permission", "Auto-reviewer APPROVED \(request.toolName): \(rationale)")
                    return .approved
                case .deny(let rationale):
                    logs.info("Permission", "Auto-reviewer DENIED \(request.toolName): \(rationale)")
                    return denied(request, "The automatic reviewer denied this \(request.toolName) call: \(rationale). Do not retry the same action; choose a different approach or ask the user.")
                case .needsUserReview(let fallbackReason):
                    logs.info("Permission", "Auto-reviewer delegated to human [\(fallbackReason)]; presenting approval sheet.")
                    return await requestHumanApproval(request: request, reason: "\(reason) (Auto-review fallback: \(fallbackReason))")
                }
            } else if mode == .helpMeApprove {
                logs.info("Permission", "Auto-reviewer unavailable; falling back to human approval for \(request.toolName).")
                return await requestHumanApproval(request: request, reason: reason)
            } else {
                return await requestHumanApproval(request: request, reason: reason)
            }
        }
    }

    private func requestHumanApproval(
        request: ToolPermissionRequest,
        reason: String
    ) async -> ToolApprovalState {
        let details = approvalDetails(for: request)
        let id = UUID()
        let approval = PendingApproval(
            id: id,
            requestID: request.requestID,
            conversationID: request.conversationID,
            runID: request.runID,
            conversationTitle: request.conversationTitle,
            toolName: request.toolName,
            summary: request.summary,
            reason: reason,
            details: details,
            command: request.command,
            affectedPaths: request.affectedURLs.map(\.path),
            environmentKeys: request.environmentKeys,
            requestsNetwork: request.requestsNetwork,
            isHighRisk: request.isHighRisk
        )

        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                enqueueApproval(id: id, approval: approval, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueuedApproval(id: id)
            }
        }

        return approved ? .approved : denied(request, Task.isCancelled
            ? "The approval request was cancelled because the run is stopping."
            : "The user denied this \(request.toolName) call. Do not retry it; continue without it or ask the user how to proceed.")
    }

    private func enqueueApproval(id: UUID, approval: PendingApproval, continuation: CheckedContinuation<Bool, Never>) {
        let item = QueuedApproval(id: id, approval: approval, continuation: continuation)
        approvalQueue.append(item)
        if pendingApproval == nil {
            presentNextApproval()
        }
    }

    private func presentNextApproval() {
        guard let first = approvalQueue.first else {
            pendingApproval = nil
            return
        }
        pendingApproval = first.approval
        onApprovalPresented?(first.approval)
    }

    func resolvePendingApproval(id: UUID? = nil, approved: Bool) {
        guard let first = approvalQueue.first else {
            pendingApproval = nil
            return
        }
        guard id == nil || first.id == id else {
            logs.info("Permission", "Ignored stale approval response for \(id!.uuidString).")
            return
        }
        let current = approvalQueue.removeFirst()
        let toolName = current.approval.toolName
        logs.info("Permission", "\(approved ? "Human Approved" : "Human Denied") \(toolName).")
        current.continuation.resume(returning: approved)
        presentNextApproval()
    }

    func cancelQueuedApproval(id: UUID) {
        if let index = approvalQueue.firstIndex(where: { $0.id == id }) {
            let removed = approvalQueue.remove(at: index)
            logs.info("Permission", "Cancelled approval for \(removed.approval.toolName).")
            removed.continuation.resume(returning: false)
            if index == 0 {
                presentNextApproval()
            }
        }
    }

    /// Cancels only this run's outstanding human decisions. Removed waiters
    /// resume denied, so they cannot later authorize a replacement run.
    func cancelQueuedApprovals(conversationID: UUID, runID: UUID) {
        let indexes = approvalQueue.enumerated()
            .filter { $0.element.approval.conversationID == conversationID && $0.element.approval.runID == runID }
            .map(\.offset)
            .reversed()
        for index in indexes {
            let removed = approvalQueue.remove(at: index)
            logs.info("Permission", "Cancelled approval '\(removed.approval.requestID)' for stopped run '\(runID)'.")
            removed.continuation.resume(returning: false)
        }
        presentNextApproval()
    }

    private func approvalDetails(for request: ToolPermissionRequest) -> String {
        var lines = [request.summary]
        if let command = request.command {
            lines.append("Command: \(command)")
        }
        if !request.environmentKeys.isEmpty {
            lines.append("Environment keys: \(request.environmentKeys.joined(separator: ", ")) (values hidden)")
        }
        if !request.affectedURLs.isEmpty {
            lines.append("Paths: \(request.affectedURLs.map(\.path).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
