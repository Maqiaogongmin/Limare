import Foundation

/// When a background run or a pending approval is worth a system notification. Off by default;
/// only while Limare is not the active app.
enum BackgroundNotificationPolicy {
    enum Event: Equatable {
        case approvalRequested
        /// A run waits for the user's answer to a question card.
        case questionRequested
        case runFinished(status: ConversationRunStatus, duration: TimeInterval)
        /// A scheduled run ended. Not held to `minimumRunDuration`: the user asked for this result.
        case scheduledRunFinished(taskName: String, status: ScheduledRun.Status, isCatchUp: Bool, notifyOn: ScheduledTask.NotifyOn)
        /// A one-time task could not run within the catch-up window.
        case scheduledMissed(taskName: String)
    }

    static let minimumRunDuration: TimeInterval = 20
    /// At most one approval notice per conversation in this window.
    static let approvalInterval: TimeInterval = 60

    static func shouldNotify(
        event: Event,
        isAppActive: Bool,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled, !isAppActive else { return false }
        switch event {
        case .approvalRequested, .questionRequested:
            return true
        case .runFinished(let status, let duration):
            switch status {
            case .completed, .failed, .interrupted:
                return duration >= minimumRunDuration
            case .cancelled, .queued, .running, .paused:
                return false
            }
        case .scheduledRunFinished(_, let status, _, let notifyOn):
            switch status {
            case .failed, .interrupted: return true
            case .completed, .cancelled: return notifyOn == .completionAndFailure
            case .pending, .skipped: return false
            }
        case .scheduledMissed:
            return true
        }
    }

    static func isApprovalThrottled(lastNotice: Date?, now: Date) -> Bool {
        guard let lastNotice else { return false }
        return now.timeIntervalSince(lastNotice) < approvalInterval
    }

    /// The notification body: only what happened, never a tool, command or path.
    static func body(for event: Event) -> String {
        switch event {
        case .approvalRequested:
            return String(localized: "Needs your approval")
        case .questionRequested:
            return String(localized: "Needs your decision")
        case .runFinished(let status, _):
            switch status {
            case .failed: return String(localized: "Task failed")
            case .interrupted: return String(localized: "Task interrupted")
            default: return String(localized: "Task finished")
            }
        case .scheduledRunFinished(let name, let status, let isCatchUp, _):
            switch (status, isCatchUp) {
            case (.failed, false): return String(localized: "“\(name)” failed")
            case (.failed, true): return String(localized: "“\(name)” failed (catch-up run)")
            case (.interrupted, false): return String(localized: "“\(name)” was interrupted")
            case (.interrupted, true): return String(localized: "“\(name)” was interrupted (catch-up run)")
            case (.cancelled, false): return String(localized: "“\(name)” was cancelled")
            case (.cancelled, true): return String(localized: "“\(name)” was cancelled (catch-up run)")
            case (_, false): return String(localized: "“\(name)” finished")
            case (_, true): return String(localized: "“\(name)” finished (catch-up run)")
            }
        case .scheduledMissed(let name):
            return String(localized: "“\(name)” was missed")
        }
    }
}
