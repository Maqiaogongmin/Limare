import AppKit
import UserNotifications

/// Posts a local notification when a run ends or a tool needs approval while Limare is in the
/// background, if the user turned Background Alerts on. Clicking one brings its conversation
/// into view. Only the Limare app itself talks to the notification center; test runners and
/// XCTest hosts never do.
@MainActor
final class BackgroundActivityNotifier {
    static let enabledKey = "limare.notifications.backgroundAlerts"
    nonisolated static let conversationKey = "conversationID"

    private weak var appState: AppState?
    private var subscription: ConversationRunSubscription?
    private var notifiedRunIDs: Set<UUID> = []
    private var lastApprovalNotice: [UUID: Date] = [:]
    /// Approvals outside any conversation share one throttle.
    private static let noConversation = UUID()
    private let clickHandler = NotificationClickHandler()

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func start(appState: AppState) {
        guard LimareStorage.isLimareApp, subscription == nil else { return }
        self.appState = appState
        clickHandler.onClick = { [weak appState] conversationID in
            appState?.reveal(conversationID: conversationID)
        }
        UNUserNotificationCenter.current().delegate = clickHandler
        subscription = appState.conversationRuns.observe { [weak self] event in
            guard case .runFinished(let conversationID, let runID, let status, _) = event else { return }
            self?.runFinished(conversationID: conversationID, runID: runID, status: status)
        }
        appState.permissions.onApprovalPresented = { [weak self] approval in
            self?.approvalPresented(approval)
        }
        // A scheduled run gets its own notice from the scheduler and never the generic one too.
        appState.scheduled.onRunEnded = { [weak self] task, run in
            self?.scheduledRunEnded(task: task, run: run)
        }
        appState.scheduled.onOneTimeMissed = { [weak self] task in
            self?.post(event: .scheduledMissed(taskName: task.name), identifier: "scheduled-missed-\(task.id.uuidString)", conversationID: nil)
        }
    }

    private func scheduledRunEnded(task: ScheduledTask?, run: ScheduledRun) {
        guard let task else { return }
        let event = BackgroundNotificationPolicy.Event.scheduledRunFinished(
            taskName: task.name, status: run.status, isCatchUp: run.trigger == .catchUp, notifyOn: task.notifyOn)
        post(event: event, identifier: "scheduled-\(run.id.uuidString)", conversationID: run.conversationID)
    }

    private func post(event: BackgroundNotificationPolicy.Event, identifier: String, conversationID: UUID?) {
        guard BackgroundNotificationPolicy.shouldNotify(event: event, isAppActive: NSApp.isActive, isEnabled: isEnabled) else { return }
        post(body: BackgroundNotificationPolicy.body(for: event), identifier: identifier, conversationID: conversationID)
    }

    /// Asks once; false when the user has denied notifications (or this is not the app).
    func requestAuthorizationIfNeeded() async -> Bool {
        guard LimareStorage.isLimareApp else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    func isDenied() async -> Bool {
        guard LimareStorage.isLimareApp else { return false }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    private func runFinished(conversationID: UUID, runID: UUID, status: ConversationRunStatus) {
        guard let appState, !notifiedRunIDs.contains(runID),
              !appState.scheduled.store.runs.contains(where: { $0.runID == runID }),
              let run = appState.conversationRuns.run(for: conversationID), run.id == runID else { return }
        let duration = (run.completedAt ?? Date()).timeIntervalSince(run.startedAt)
        let event = BackgroundNotificationPolicy.Event.runFinished(status: status, duration: duration)
        guard BackgroundNotificationPolicy.shouldNotify(event: event, isAppActive: NSApp.isActive, isEnabled: isEnabled) else { return }
        notifiedRunIDs.insert(runID)
        post(body: BackgroundNotificationPolicy.body(for: event), identifier: "run-\(runID.uuidString)", conversationID: conversationID)
    }

    private func approvalPresented(_ approval: PendingApproval) {
        let event = BackgroundNotificationPolicy.Event.approvalRequested
        guard BackgroundNotificationPolicy.shouldNotify(event: event, isAppActive: NSApp.isActive, isEnabled: isEnabled) else { return }
        let key = approval.conversationID ?? Self.noConversation
        let now = Date()
        guard !BackgroundNotificationPolicy.isApprovalThrottled(lastNotice: lastApprovalNotice[key], now: now) else { return }
        lastApprovalNotice[key] = now
        post(body: BackgroundNotificationPolicy.body(for: event), identifier: "approval-\(approval.id.uuidString)", conversationID: approval.conversationID)
    }

    private func post(body: String, identifier: String, conversationID: UUID?) {
        guard LimareStorage.isLimareApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "Limare"
        content.body = body
        content.sound = .default
        if let conversationID {
            content.userInfo = [Self.conversationKey: conversationID.uuidString]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}


/// Receives clicks on Limare's notifications and passes on the conversation each one is about.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    @MainActor var onClick: ((UUID?) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let conversationID = Self.conversationID(in: response.notification.request.content.userInfo)
        await MainActor.run { self.onClick?(conversationID) }
    }

    nonisolated static func conversationID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo[BackgroundActivityNotifier.conversationKey] as? String).flatMap(UUID.init(uuidString:))
    }
}
