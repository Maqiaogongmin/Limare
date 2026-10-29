import Foundation

/// Fixed wording of the scheduled-task UI (§5.14). None of it promises that a task runs while
/// Limare is closed, or that a run is always sandboxed.
enum ScheduledTaskCopy {
    static var fullAccessWarning: String { String(localized: "The permission mode is Full Access: when this task runs unattended, it can read and write files outside the workspace and run commands without sandbox limits.") }
    static var unattendedNote: String { String(localized: "No one is there to approve actions during a run: steps that need approval are skipped, and the result is written in the conversation.") }
    static var keepRunningNote: String { String(localized: "Limare must stay running for tasks to run on time. Closing the window is fine; after you quit Limare, tasks don't run.") }
    static var shortPeriodWarning: String { String(localized: "The period is shorter than a typical run, so runs may be skipped one after another.") }
    static var notificationsOff: String { String(localized: "Background notifications are off, so you won't be alerted") }
    static var openSettings: String { String(localized: "Open Settings") }
    static var anotherRunActive: String { String(localized: "Another scheduled task is running") }
    static var conversationTargetNote: String { String(localized: "This continues the conversation: each run sends the instruction to it as a message.") }
    static let manyEnabledThreshold = 30

    static func manyEnabled(_ count: Int) -> String { String(localized: "You have \(count) enabled tasks; consider pausing the ones you no longer need.") }
    static func unreadable(path: String) -> String { String(localized: "Scheduled task data can't be read, so scheduling is paused. The file was not changed: \(path)") }
    static func followsConversation(model: String, effort: String) -> String { String(localized: "Follows the conversation: \(model) · \(effort)") }
}

/// What the list and detail show, derived from the task and its runs; never stored (§5.2).
enum ScheduledTaskPresentation {
    enum Status: Equatable {
        case paused
        case next(Date)
        case completed
        /// A one-time task's only run ended without completing; the text says why.
        case ended(String)
        case missed
        /// A one-time task whose run is claimed and has no terminal status yet.
        case running
        /// Enabled, but nothing planned and no run to describe.
        case idle
    }

    /// `runs` newest first.
    static func status(task: ScheduledTask, runs: [ScheduledRun]) -> Status {
        if !task.isEnabled { return .paused }
        if let next = task.nextNominalAt { return .next(next) }
        if task.isOneTime, let latest = runs.first {
            switch latest.status {
            case .pending: return .running
            case .completed: return .completed
            case .skipped where latest.skipReason == .missedSlots: return .missed
            case .skipped: return .ended(latest.skipReason.map { skipReasonText($0, missedCount: latest.missedCount) } ?? runStatusText(.skipped))
            case .failed, .interrupted, .cancelled: return .ended(runStatusText(latest.status))
            }
        }
        return .idle
    }

    static func statusText(_ status: Status, timeZoneID: String) -> String {
        switch status {
        case .paused: return String(localized: "Paused")
        case .next(let date): return String(localized: "Next run \(shortDate(date, timeZoneID: timeZoneID))")
        case .completed: return String(localized: "Completed")
        case .ended(let reason): return String(localized: "Ended (\(reason))")
        case .missed: return String(localized: "Missed")
        case .running: return String(localized: "Running")
        case .idle: return String(localized: "Not scheduled")
        }
    }

    static func runStatusText(_ status: ScheduledRun.Status) -> String {
        switch status {
        case .pending: return String(localized: "Running")
        case .completed: return String(localized: "Done", comment: "A scheduled run's status")
        case .failed: return String(localized: "Failed")
        case .cancelled: return String(localized: "Cancelled")
        case .interrupted: return String(localized: "Interrupted")
        case .skipped: return String(localized: "Skipped")
        }
    }

    static func runSummary(_ run: ScheduledRun) -> String {
        var text = runStatusText(run.status)
        if let reason = run.skipReason { text += " · " + skipReasonText(reason, missedCount: run.missedCount) }
        if run.failureDetail == .notAdmitted { text += " · " + String(localized: "The run could not start") }
        return text
    }

    static func skipReasonText(_ reason: ScheduledRun.SkipReason, missedCount: Int?) -> String {
        switch reason {
        case .previousSlotPending: return String(localized: "The previous run hasn't finished")
        case .targetConversationBusy: return String(localized: "The target conversation is busy")
        case .conversationGone: return String(localized: "The target conversation was deleted")
        case .projectGone: return String(localized: "The target project was deleted")
        case .modelUnavailable: return String(localized: "No model is available")
        // Limare was closed or asleep, or another scheduled run held the one slot; which is not recorded.
        case .missedSlots: return String(localized: "Missed \(missedCount ?? 1) times (Limare wasn't running, or another task was)")
        case .worktreeUnavailable: return String(localized: "The task's worktree could not be prepared")
        }
    }

    static func triggerText(_ trigger: ScheduledRun.Trigger) -> String {
        switch trigger {
        case .scheduled: return String(localized: "On schedule")
        case .catchUp: return String(localized: "Catch-up")
        case .manual: return String(localized: "Run Now")
        }
    }

    /// `09:00 (Asia/Shanghai)`, plus `= 21:00 local` when the system time zone differs.
    static func timeWithZone(_ date: Date, timeZoneID: String, local: TimeZone = .current) -> String {
        var text = "\(clock(date, timeZone: TimeZone(identifier: timeZoneID) ?? local)) (\(timeZoneID))"
        if local.identifier != timeZoneID, (TimeZone(identifier: timeZoneID)?.secondsFromGMT(for: date) ?? 0) != local.secondsFromGMT(for: date) {
            text += " = " + String(localized: "\(clock(date, timeZone: local)) local", comment: "The same time in the Mac's own time zone")
        }
        return text
    }

    static func shortDate(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func fullDate(_ date: Date, timeZoneID: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The shortest gap between two of the next few slots, for the short-period warning.
    static func shortestPeriod(_ schedule: ScheduledTask.Schedule, timeZoneID: String, from now: Date = Date()) -> TimeInterval? {
        guard case .recurring = schedule else { return nil }
        var slots: [Date] = []
        var cursor = now
        for _ in 0..<6 {
            guard let next = ScheduledRecurrence.next(after: cursor, schedule: schedule, timeZoneID: timeZoneID) else { break }
            slots.append(next)
            cursor = next
        }
        return zip(slots, slots.dropFirst()).map { $1.timeIntervalSince($0) }.min()
    }

    static func isShortPeriod(_ schedule: ScheduledTask.Schedule, timeZoneID: String) -> Bool {
        (shortestPeriod(schedule, timeZoneID: timeZoneID) ?? .infinity) < 10 * 60
    }
}

/// The form's editable shape of a rule: once, daily, weekdays, weekly, every N hours, monthly.
struct ScheduledRuleDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case once, daily, weekdays, weekly, everyNHours, monthly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .once: String(localized: "Once")
            case .daily: String(localized: "Daily")
            case .weekdays: String(localized: "Weekdays")
            case .weekly: String(localized: "Weekly")
            case .everyNHours: String(localized: "Every N Hours")
            case .monthly: String(localized: "Monthly")
            }
        }
    }

    /// 1 = Sunday … 7 = Saturday, as Calendar numbers weekdays; the names and the first day of
    /// the week come from the current locale.
    static var weekdayTitles: [(Int, String)] {
        let calendar = Calendar.autoupdatingCurrent
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { offset in
            let number = (calendar.firstWeekday - 1 + offset) % 7 + 1
            return (number, symbols[number - 1])
        }
    }

    var kind: Kind = .daily
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = [2]
    var intervalHours = 1
    var dayOfMonth = 1
    var fireAt = Date().addingTimeInterval(3600)

    static func weekday(_ number: Int) -> Locale.Weekday {
        switch number {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        default: .saturday
        }
    }

    static func number(_ weekday: Locale.Weekday) -> Int {
        switch weekday {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        default: 7
        }
    }

    func schedule(timeZoneID: String) -> ScheduledTask.Schedule {
        let calendar = ScheduledRecurrence.calendar(timeZoneID: timeZoneID)
        var rule: Calendar.RecurrenceRule
        switch kind {
        case .once:
            return .once(fireAt: Date(timeIntervalSince1970: (fireAt.timeIntervalSince1970 / 60).rounded(.down) * 60))
        case .daily:
            rule = .daily(calendar: calendar)
        case .weekdays:
            rule = .weekly(calendar: calendar)
            rule.weekdays = (2...6).map { .every(Self.weekday($0)) }
        case .weekly:
            rule = .weekly(calendar: calendar)
            rule.weekdays = weekdays.sorted().map { .every(Self.weekday($0)) }
        case .everyNHours:
            rule = .hourly(calendar: calendar, interval: max(intervalHours, 1))
            rule.minutes = [minute]
            rule.seconds = [0]
            return .recurring(rule)
        case .monthly:
            rule = .monthly(calendar: calendar)
            rule.daysOfTheMonth = [dayOfMonth]
        }
        rule.hours = [hour]
        rule.minutes = [minute]
        rule.seconds = [0]
        return .recurring(rule)
    }

    init() {}

    init(schedule: ScheduledTask.Schedule) {
        switch schedule {
        case .once(let date):
            kind = .once
            fireAt = date
        case .recurring(let rule):
            hour = rule.hours.first ?? 9
            minute = rule.minutes.first ?? 0
            switch rule.frequency {
            case .hourly:
                kind = .everyNHours
                intervalHours = rule.interval
            case .monthly:
                kind = .monthly
                dayOfMonth = rule.daysOfTheMonth.first ?? 1
            case .weekly:
                let days = Set(rule.weekdays.compactMap { day -> Int? in
                    if case .every(let weekday) = day { return Self.number(weekday) }
                    return nil
                })
                if days == Set(2...6) { kind = .weekdays } else { kind = .weekly; weekdays = days }
            default:
                kind = .daily
            }
        }
    }

    /// A plain-words rule, in the task's time zone: `Daily 09:00 · Asia/Shanghai`.
    func summary(timeZoneID: String) -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .once: return String(localized: "Once · \(ScheduledTaskPresentation.fullDate(fireAt, timeZoneID: timeZoneID)) · \(timeZoneID)")
        case .daily: return String(localized: "Daily \(time) · \(timeZoneID)")
        case .weekdays: return String(localized: "Weekdays \(time) · \(timeZoneID)")
        case .weekly:
            let symbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
            let days = ListFormatter.localizedString(byJoining: Self.weekdayTitles.filter { weekdays.contains($0.0) }.map { symbols[$0.0 - 1] })
            return String(localized: "Weekly on \(days) \(time) · \(timeZoneID)")
        case .everyNHours: return String(localized: "Every \(intervalHours) hours (at minute \(minute)) · \(timeZoneID)")
        case .monthly: return String(localized: "Monthly on day \(dayOfMonth) \(time) · \(timeZoneID)")
        }
    }
}
