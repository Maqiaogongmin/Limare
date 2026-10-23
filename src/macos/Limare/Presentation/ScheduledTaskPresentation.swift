import Foundation

/// Fixed wording of the scheduled-task UI (§5.14). None of it promises that a task runs while
/// Limare is closed, or that a run is always sandboxed.
enum ScheduledTaskCopy {
    static let fullAccessWarning = "当前权限模式为 Full Access：该任务无人值守运行时，可在工作区之外读写文件、执行不受沙箱限制的命令。"
    static let unattendedNote = "运行时没有人可以批准操作：需要批准的步骤会被跳过，结果写在会话里。"
    static let keepRunningNote = "Limare 需要保持运行，任务才会按时执行；关掉窗口不影响，退出 Limare 后不会运行。"
    static let shortPeriodWarning = "周期比一次运行的常见时长还短，可能连续跳过。"
    static let notificationsOff = "后台通知已关闭，不会收到提醒"
    static let openSettings = "打开设置"
    static let anotherRunActive = "另一个定时任务正在运行"
    static let conversationTargetNote = "这是接着聊：每次运行把指令作为一条消息发到这个会话。"
    static let manyEnabledThreshold = 30

    static func manyEnabled(_ count: Int) -> String { "你有 \(count) 个启用中的任务；建议暂停不再需要的。" }
    static func unreadable(path: String) -> String { "定时任务数据无法读取，调度已暂停。文件未被修改：\(path)" }
    static func followsConversation(model: String, effort: String) -> String { "跟随会话：\(model) · \(effort)" }
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
        case .paused: return "已暂停"
        case .next(let date): return "下次运行 \(shortDate(date, timeZoneID: timeZoneID))"
        case .completed: return "已完成"
        case .ended(let reason): return "已结束（\(reason)）"
        case .missed: return "已错过"
        case .running: return "运行中"
        case .idle: return "无计划"
        }
    }

    static func runStatusText(_ status: ScheduledRun.Status) -> String {
        switch status {
        case .pending: return "运行中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "取消"
        case .interrupted: return "中断"
        case .skipped: return "跳过"
        }
    }

    static func runSummary(_ run: ScheduledRun) -> String {
        var text = runStatusText(run.status)
        if let reason = run.skipReason { text += " · " + skipReasonText(reason, missedCount: run.missedCount) }
        if run.failureDetail == .notAdmitted { text += " · 运行未能开始" }
        return text
    }

    static func skipReasonText(_ reason: ScheduledRun.SkipReason, missedCount: Int?) -> String {
        switch reason {
        case .previousSlotPending: return "上一次运行还没结束"
        case .targetConversationBusy: return "目标会话正忙"
        case .conversationGone: return "目标会话已删除"
        case .projectGone: return "目标项目已删除"
        case .modelUnavailable: return "没有可用模型"
        // Limare was closed or asleep, or another scheduled run held the one slot; which is not recorded.
        case .missedSlots: return "错过 \(missedCount ?? 1) 次（Limare 未运行或另一任务正在运行）"
        }
    }

    static func triggerText(_ trigger: ScheduledRun.Trigger) -> String {
        switch trigger {
        case .scheduled: return "按时"
        case .catchUp: return "补跑"
        case .manual: return "立即运行"
        }
    }

    /// `09:00 (Asia/Shanghai)`, plus `= 本地 21:00` when the system time zone differs.
    static func timeWithZone(_ date: Date, timeZoneID: String, local: TimeZone = .current) -> String {
        var text = "\(clock(date, timeZone: TimeZone(identifier: timeZoneID) ?? local)) (\(timeZoneID))"
        if local.identifier != timeZoneID, (TimeZone(identifier: timeZoneID)?.secondsFromGMT(for: date) ?? 0) != local.secondsFromGMT(for: date) {
            text += " = 本地 \(clock(date, timeZone: local))"
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
            case .once: "一次"
            case .daily: "每天"
            case .weekdays: "工作日"
            case .weekly: "每周"
            case .everyNHours: "每 N 小时"
            case .monthly: "每月"
            }
        }
    }

    /// 1 = Sunday … 7 = Saturday, as Calendar numbers weekdays.
    static let weekdayTitles: [(Int, String)] = [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")]

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

    /// A plain-words rule, in the task's time zone: `每天 09:00 · Asia/Shanghai`.
    func summary(timeZoneID: String) -> String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .once: return "一次 · \(ScheduledTaskPresentation.fullDate(fireAt, timeZoneID: timeZoneID)) · \(timeZoneID)"
        case .daily: return "每天 \(time) · \(timeZoneID)"
        case .weekdays: return "工作日 \(time) · \(timeZoneID)"
        case .weekly:
            let days = Self.weekdayTitles.filter { weekdays.contains($0.0) }.map(\.1).joined(separator: "、")
            return "每周\(days) \(time) · \(timeZoneID)"
        case .everyNHours: return "每 \(intervalHours) 小时（第 \(minute) 分）· \(timeZoneID)"
        case .monthly: return "每月 \(dayOfMonth) 日 \(time) · \(timeZoneID)"
        }
    }
}
