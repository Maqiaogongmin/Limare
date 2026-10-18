import Foundation

/// When a background run or a pending approval is worth a system notification. Off by default;
/// only while Limare is not the active app.
enum BackgroundNotificationPolicy {
    enum Event: Equatable {
        case approvalRequested
        case runFinished(status: ConversationRunStatus, duration: TimeInterval)
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
        case .approvalRequested:
            return true
        case .runFinished(let status, let duration):
            switch status {
            case .completed, .failed, .interrupted:
                return duration >= minimumRunDuration
            case .cancelled, .queued, .running, .paused:
                return false
            }
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
            return "需要你的批准"
        case .runFinished(let status, _):
            switch status {
            case .failed: return "任务失败"
            case .interrupted: return "任务中断"
            default: return "任务完成"
            }
        }
    }
}
