import Foundation

/// A durable "prompt + time rule + target" record. It owns no run state: when a slot is due the
/// scheduler asks the normal run system for one run (ConversationInteractionService.submit).
struct ScheduledTask: Codable, Identifiable, Equatable, Sendable {
    enum Schedule: Codable, Equatable, Sendable {
        /// One absolute moment.
        case once(fireAt: Date)
        /// A structured rule; evaluated in the task's own time zone (`timeZoneID`), never stored as RRULE text.
        case recurring(Calendar.RecurrenceRule)
    }

    enum Target: Codable, Equatable, Hashable, Sendable {
        /// Every run creates a conversation, in this project or (nil) the default workspace.
        case newConversation(projectID: UUID?)
        /// Every run appends its prompt to this conversation as a user message.
        case conversation(id: UUID)

        var isNewConversation: Bool {
            if case .newConversation = self { return true }
            return false
        }
    }

    enum NotifyOn: String, Codable, Sendable, CaseIterable {
        case completionAndFailure
        case failureOnly
    }

    var id: UUID
    var name: String
    var prompt: String
    var schedule: Schedule
    /// Fixed at creation (`TimeZone.current.identifier`); a later system time zone change does not move the task.
    var timeZoneID: String
    /// The only persistent switch. "Completed" for a one-time task is derived from its runs.
    var isEnabled: Bool
    var target: Target
    /// Only for `.newConversation`; nil is the default Model Group.
    var modelSource: ConversationModelSource?
    /// Only for `.newConversation`; nil is the default thinking level.
    var thinkingLevel: ThinkingLevel?
    var notifyOn: NotifyOn
    /// The next planned slot; nil when there is none (paused, or a one-time task already consumed).
    var nextNominalAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        schedule: Schedule,
        timeZoneID: String = TimeZone.current.identifier,
        isEnabled: Bool = true,
        target: Target,
        modelSource: ConversationModelSource? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        notifyOn: NotifyOn = .completionAndFailure,
        nextNominalAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.timeZoneID = timeZoneID
        self.isEnabled = isEnabled
        self.target = target
        self.modelSource = modelSource
        self.thinkingLevel = thinkingLevel
        self.notifyOn = notifyOn
        self.nextNominalAt = nextNominalAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isOneTime: Bool {
        if case .once = schedule { return true }
        return false
    }
}

/// One attempt of a task at one slot. Durably claimed before it executes; every claim ends in a terminal status.
struct ScheduledRun: Codable, Identifiable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case scheduled
        case catchUp
        case manual
    }

    /// Only `pending` and terminal values persist; `pending` is split by whether `runID` is bound.
    enum Status: String, Codable, Sendable {
        case pending
        case completed
        case failed
        case cancelled
        case interrupted
        case skipped

        var isTerminal: Bool { self != .pending }
    }

    /// Exhaustive; stored as an enum, never as display text.
    enum SkipReason: String, Codable, Sendable {
        case previousSlotPending
        case targetConversationBusy
        case conversationGone
        case projectGone
        case modelUnavailable
        case missedSlots
    }

    enum FailureDetail: String, Codable, Sendable {
        /// The execution Task was never created.
        case notAdmitted
        case runFailed
    }

    enum Outcome: Equatable, Sendable {
        case completed
        case failed(FailureDetail)
        case cancelled
        case interrupted
        case skipped(SkipReason, missedCount: Int? = nil)

        var status: Status {
            switch self {
            case .completed: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            case .interrupted: .interrupted
            case .skipped: .skipped
            }
        }
    }

    var id: UUID
    var taskID: UUID
    /// Unique per task for every record whose trigger is not `.manual`; a manual run uses its claim time.
    var slotNominalAt: Date
    var trigger: Trigger
    var status: Status
    var skipReason: SkipReason?
    var missedCount: Int?
    var failureDetail: FailureDetail?
    /// Written together, once, by the binding (W2): `runID != nil` means the binding reached disk.
    var conversationID: UUID?
    var runID: UUID?
    var boundAt: Date?
    var claimedAt: Date
    var finishedAt: Date?

    var isBound: Bool { runID != nil }

    init(
        id: UUID = UUID(),
        taskID: UUID,
        slotNominalAt: Date,
        trigger: Trigger,
        status: Status,
        skipReason: SkipReason? = nil,
        missedCount: Int? = nil,
        failureDetail: FailureDetail? = nil,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        boundAt: Date? = nil,
        claimedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.slotNominalAt = slotNominalAt
        self.trigger = trigger
        self.status = status
        self.skipReason = skipReason
        self.missedCount = missedCount
        self.failureDetail = failureDetail
        self.conversationID = conversationID
        self.runID = runID
        self.boundAt = boundAt
        self.claimedAt = claimedAt
        self.finishedAt = finishedAt
    }
}
