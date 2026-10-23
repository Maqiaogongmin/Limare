import Foundation

/// Slot arithmetic for scheduled tasks: Foundation `Calendar.RecurrenceRule`, evaluated in the
/// task's fixed time zone. `alignedSlot` is the only place missed slots are decided; startup and
/// every tick use it, and it never looks at when the last tick ran.
enum ScheduledRecurrence {
    /// A slot older than this is not caught up; it is recorded as missed.
    static let catchUpWindow: TimeInterval = 7 * 24 * 60 * 60

    struct Alignment: Equatable {
        /// The slot to run now, if any.
        var slot: Date?
        /// Slots folded into one `missedSlots` record.
        var missed: Int
        /// The task's next planned slot after this alignment.
        var nextAfter: Date?
    }

    static func calendar(timeZoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar
    }

    /// The rule re-anchored to the task's calendar, whatever calendar it was built with. Slots fall
    /// on whole minutes: without explicit seconds the rule would keep the search start's seconds.
    static func rule(_ rule: Calendar.RecurrenceRule, timeZoneID: String) -> Calendar.RecurrenceRule {
        var rule = rule
        rule.calendar = calendar(timeZoneID: timeZoneID)
        if rule.seconds.isEmpty { rule.seconds = [0] }
        return rule
    }

    /// The first slot strictly after `date`. `recurrences(of:)` includes its start, so the search starts 1 s later.
    /// The rule keeps its start's fraction of a second, so the start is a whole second.
    static func next(after date: Date, schedule: ScheduledTask.Schedule, timeZoneID: String) -> Date? {
        switch schedule {
        case .once(let fireAt):
            return fireAt > date ? fireAt : nil
        case .recurring(let recurrence):
            let start = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).addingTimeInterval(1)
            return rule(recurrence, timeZoneID: timeZoneID).recurrences(of: start).first { $0 > date }
        }
    }

    /// The slot a task plans next when it is created, resumed, or its rule is edited: strictly after `now`.
    static func firstSlot(for task: ScheduledTask, now: Date) -> Date? {
        next(after: now, schedule: task.schedule, timeZoneID: task.timeZoneID)
    }

    /// Slots in `from...through`, both ends included.
    static func slots(from start: Date, through end: Date, schedule: ScheduledTask.Schedule, timeZoneID: String) -> [Date] {
        guard start <= end else { return [] }
        switch schedule {
        case .once(let fireAt):
            return (start...end).contains(fireAt) ? [fireAt] : []
        case .recurring(let recurrence):
            var result: [Date] = []
            let wholeStart = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.up))
            for date in rule(recurrence, timeZoneID: timeZoneID).recurrences(of: wholeStart) {
                if date > end { break }
                result.append(date)
            }
            return result
        }
    }

    /// §5.7: from the task's `nextNominalAt` and the current time, which slot runs now, how many
    /// are folded as missed, and what the next planned slot becomes.
    static func alignedSlot(task: ScheduledTask, now: Date) -> Alignment {
        guard let nominal = task.nextNominalAt, nominal <= now else {
            return Alignment(slot: nil, missed: 0, nextAfter: task.nextNominalAt)
        }
        if case .once = task.schedule {
            return now.timeIntervalSince(nominal) <= catchUpWindow
                ? Alignment(slot: nominal, missed: 0, nextAfter: nil)
                : Alignment(slot: nil, missed: 1, nextAfter: nil)
        }
        let due = slots(from: nominal, through: now, schedule: task.schedule, timeZoneID: task.timeZoneID)
        // `nominal` is itself a slot of the rule; if the rule changed under it, it still counts once.
        let latest = due.last ?? nominal
        let count = max(due.count, 1)
        if now.timeIntervalSince(latest) > catchUpWindow {
            return Alignment(slot: nil, missed: count,
                             nextAfter: next(after: now, schedule: task.schedule, timeZoneID: task.timeZoneID))
        }
        return Alignment(slot: latest, missed: count - 1,
                         nextAfter: next(after: latest, schedule: task.schedule, timeZoneID: task.timeZoneID))
    }
}
