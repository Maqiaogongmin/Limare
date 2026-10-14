import Foundation
import Observation

// MARK: - Layer 2 App Authorization Store (Doc 68 §4, §10, Section 16, 17, 18)

@MainActor
@Observable
final class ComputerUseAppAuthorizationStore {
    @ObservationIgnored
    private var grants: [String: ComputerUseAppAuthorizationState] = [:]

    private(set) var pendingApproval: ComputerUseAppApprovalPending?

    private struct QueuedAppApproval {
        let id: UUID
        let pending: ComputerUseAppApprovalPending
        let continuation: CheckedContinuation<ComputerUseAppApprovalResolution, Never>
    }

    @ObservationIgnored
    private var approvalQueue: [QueuedAppApproval] = []

    @ObservationIgnored
    private let logs: DebugLogStore?

    init(logs: DebugLogStore? = nil) {
        self.logs = logs
    }

    private func makeKey(conversationID: UUID, bundleID: String) -> String {
        "\(conversationID.uuidString.lowercased()):\(bundleID.lowercased())"
    }

    /// Queries the current authorization status for a conversation × bundleID pair.
    func authorizationStatus(conversationID: UUID, bundleID: String) -> ComputerUseAppAuthorizationState {
        let key = makeKey(conversationID: conversationID, bundleID: bundleID)
        return grants[key] ?? .unknown
    }

    /// Sets the authorization status directly (e.g. for testing or explicit revocation).
    func setAuthorizationStatus(
        conversationID: UUID,
        bundleID: String,
        state: ComputerUseAppAuthorizationState
    ) {
        let key = makeKey(conversationID: conversationID, bundleID: bundleID)
        grants[key] = state
        logs?.info("ComputerUse", "Layer-2 App authorization set for [\(bundleID)] in conversation [\(conversationID.uuidString.prefix(8))]: \(state.rawValue)")
    }

    /// Requests human Layer-2 App authorization.
    /// Strictly human-only: AutoPermissionReviewer, helpMeApprove, and fullAccess cannot bypass this (Doc 68 §6, §17).
    func requestAppApprovalWithResolution(
        conversationID: UUID,
        bundleID: String,
        appLocalizedName: String? = nil
    ) async -> ComputerUseAppApprovalResolution {
        let current = authorizationStatus(conversationID: conversationID, bundleID: bundleID)
        if current == .allowedForConversation {
            return .allowedForConversation
        }
        if current == .blockedForConversation {
            return .blockedForConversation
        }

        let pending = ComputerUseAppApprovalPending(
            conversationID: conversationID,
            bundleID: bundleID,
            appLocalizedName: appLocalizedName
        )
        logs?.info("ComputerUse", "Layer-2 App authorization requested from human for '\(pending.appLocalizedName)' [\(bundleID)].")

        let resolution = await withCheckedContinuation { (continuation: CheckedContinuation<ComputerUseAppApprovalResolution, Never>) in
            let queued = QueuedAppApproval(id: pending.id, pending: pending, continuation: continuation)
            approvalQueue.append(queued)
            if self.pendingApproval == nil {
                self.presentNextApproval()
            }
        }

        return resolution
    }

    func requestAppApproval(
        conversationID: UUID,
        bundleID: String,
        appLocalizedName: String? = nil
    ) async -> ComputerUseAppApprovalResolution {
        await requestAppApprovalWithResolution(
            conversationID: conversationID,
            bundleID: bundleID,
            appLocalizedName: appLocalizedName
        )
    }

    private func presentNextApproval() {
        guard let first = approvalQueue.first else {
            pendingApproval = nil
            return
        }
        pendingApproval = first.pending
    }

    /// Resolves the specific Layer-2 approval request by unique ID.
    /// Stale sheet responses cannot resolve newer queued requests.
    func resolvePendingApproval(id: UUID, approved: Bool) {
        guard let index = approvalQueue.firstIndex(where: { $0.id == id }) else {
            logs?.error("ComputerUse", "Stale or unknown Layer-2 approval ID '\(id)' ignored.")
            return
        }
        let item = approvalQueue.remove(at: index)
        let resolvedState: ComputerUseAppAuthorizationState = approved ? .allowedForConversation : .blockedForConversation
        setAuthorizationStatus(
            conversationID: item.pending.conversationID,
            bundleID: item.pending.bundleID,
            state: resolvedState
        )
        let resolution: ComputerUseAppApprovalResolution = approved ? .allowedForConversation : .blockedForConversation
        item.continuation.resume(returning: resolution)
        presentNextApproval()
    }

    /// Resolves the currently presented Layer-2 approval decision.
    func resolvePendingApproval(approved: Bool) {
        guard let current = pendingApproval else { return }
        resolvePendingApproval(id: current.id, approved: approved)
    }

    // MARK: - Lifecycle Management (Doc 68 §10, Section 16, 46, 48)

    /// An app approved in a conversation stays approved there until the conversation is cleared or
    /// deleted, or Limare quits. Switching to another conversation and back does not ask again.
    func forget(conversationID: UUID) {
        let prefix = conversationID.uuidString.lowercased() + ":"
        grants = grants.filter { !$0.key.hasPrefix(prefix) }
        cancelPendingApprovals(for: conversationID)
        logs?.info("ComputerUse", "App approvals cleared for conversation [\(conversationID.uuidString.prefix(8))].")
    }

    /// Clear grants for a single conversation.
    func resetForConversation(conversationID: UUID) {
        let prefix = "\(conversationID.uuidString.lowercased()):"
        grants = grants.filter { !$0.key.hasPrefix(prefix) }
        cancelPendingApprovals(for: conversationID)
        logs?.info("ComputerUse", "Layer-2 App authorization grants cleared for conversation '\(conversationID.uuidString.prefix(8))'.")
    }

    /// Run finished: KEEP grants.
    func onRunFinished(conversationID: UUID) {
        // Doc 68 §10.1: normal run completion KEEP, generic run failure KEEP.
    }

    /// Run cancelled / stopped: KEEP grants.
    func onRunCancelled(conversationID: UUID) {
        // Doc 68 §10.1: Stop / cancellation KEEP grants (inoperative while CU is off).
        cancelPendingApprovals(for: conversationID)
    }

    /// PermissionMode changed: KEEP grants.
    func onPermissionModeChanged(newMode: PermissionMode) {
        // Doc 68 §10.1: PermissionMode change KEEP grants (inoperative while CU is off).
    }

    private func cancelPendingApprovals(for conversationID: UUID) {
        let matching = approvalQueue.filter { $0.pending.conversationID == conversationID }
        approvalQueue.removeAll(where: { $0.pending.conversationID == conversationID })
        for item in matching {
            item.continuation.resume(returning: .cancelled)
        }
        if pendingApproval?.conversationID == conversationID {
            presentNextApproval()
        }
    }
}
