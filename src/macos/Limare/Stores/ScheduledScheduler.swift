import AppKit
import Foundation
import Observation

/// The message a scheduled run submits: a plain user message (a `.userPrompt` run, so hooks and the
/// mandatory user-message protection apply) with one visible header line.
enum ScheduledMessage {
    static func header(task: ScheduledTask, slot: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: task.timeZoneID) ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "[Scheduled task \"\(task.name)\" · \(formatter.string(from: slot)) \(task.timeZoneID) · unattended]"
    }

    static func text(task: ScheduledTask, slot: Date) -> String {
        header(task: task, slot: slot) + "\n\n" + task.prompt
    }

    /// A message `text(task:slot:)` wrote, read back for the transcript: the task's name, the
    /// slot's `HH:mm`, and the instruction without the header line.
    struct Parsed: Equatable {
        let taskName: String
        let time: String
        let body: String
    }

    // Mirrors `header`: the name is quoted, then `yyyy-MM-dd HH:mm <zone>`, then the run mode.
    nonisolated(unsafe) private static let headerPattern = #/^\[Scheduled task "(?<name>.*)" · \d{4}-\d{2}-\d{2} (?<time>\d{2}:\d{2}) [^\]·]+ · [^\]]+\]/#

    static func parse(_ text: String) -> Parsed? {
        guard text.hasPrefix("[Scheduled task \""), let match = text.prefixMatch(of: headerPattern) else { return nil }
        let body = text[match.range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(taskName: String(match.output.name), time: String(match.output.time), body: body)
    }
}

/// Wakes on a 30 s tick, decides from the ledger which slot is due, and asks the normal run system
/// for one run. It owns no run state: ScheduledStateStore owns the plan and the claims,
/// ConversationRunCoordinator owns the runs.
@MainActor
@Observable
final class ScheduledScheduler {
    static let tickInterval: TimeInterval = 30
    /// A slot started later than this after its time is a catch-up.
    static let catchUpThreshold: TimeInterval = 60

    enum ManualRunRefusal: Error, Equatable {
        case anotherRunActive
        case taskNotFound
        case notReadable
    }

    enum EditError: LocalizedError, Equatable {
        case oneTimeInPast
        case emptyPrompt

        var errorDescription: String? {
            switch self {
            case .oneTimeInPast: "The time must be in the future."
            case .emptyPrompt: "The instruction is empty."
            }
        }
    }

    let store: ScheduledStateStore
    /// True once A1 and A2 are on disk; no tick dispatches before.
    private(set) var startupReconciled = false

    @ObservationIgnored private let interaction: ConversationInteractionService
    @ObservationIgnored private let runs: ConversationRunCoordinator
    @ObservationIgnored private let conversations: ConversationStore
    @ObservationIgnored private let runtimeEvents: RuntimeEventStore
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored private var subscription: ConversationRunSubscription?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// A scheduled run reached a terminal status (not for skips). The task is nil when it was deleted.
    @ObservationIgnored var onRunEnded: ((ScheduledTask?, ScheduledRun) -> Void)? { didSet { deliverHeldNotices() } }
    /// A one-time task could not run within the catch-up window.
    @ObservationIgnored var onOneTimeMissed: ((ScheduledTask) -> Void)? { didSet { deliverHeldNotices() } }

    private enum Notice {
        case runEnded(ScheduledTask?, ScheduledRun)
        case oneTimeMissed(ScheduledTask)
    }

    /// Notices raised before anyone listens: startup reconciliation runs while AppState is being
    /// built, before the notifier attaches. Delivered when it does.
    @ObservationIgnored private var heldNotices: [Notice] = []

    init(
        store: ScheduledStateStore,
        interaction: ConversationInteractionService,
        runs: ConversationRunCoordinator,
        conversations: ConversationStore,
        runtimeEvents: RuntimeEventStore,
        logs: DebugLogStore
    ) {
        self.store = store
        self.interaction = interaction
        self.runs = runs
        self.conversations = conversations
        self.runtimeEvents = runtimeEvents
        self.logs = logs
    }

    // MARK: - Lifecycle

    /// Registers the run observer and the unattended lookup, reconciles the ledger, then (unless
    /// `startTimer` is false, for tests) starts the tick and the clock/wake observers.
    func start(now: Date = Date(), startTimer: Bool = true) {
        if subscription == nil {
            subscription = runs.observe { [weak self] event in
                guard case .runFinished(_, let runID, let status, _) = event else { return }
                self?.runFinished(runID: runID, status: status)
            }
        }
        runs.scheduledRunLookup = { [weak store] runID in store?.pendingRun(runID: runID) != nil }
        reconcileAtStartup(now: now)
        guard startTimer, timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NotificationCenter.default
        systemObservers.append((center, center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.realign(now: Date()) }
        }))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        systemObservers.append((workspaceCenter, workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick(now: Date()) }
        }))
    }

    private func notify(_ notice: Notice) {
        switch notice {
        case .runEnded(let task, let run):
            guard let onRunEnded else { return heldNotices.append(notice) }
            onRunEnded(task, run)
        case .oneTimeMissed(let task):
            guard let onOneTimeMissed else { return heldNotices.append(notice) }
            onOneTimeMissed(task)
        }
    }

    private func deliverHeldNotices() {
        let held = heldNotices
        heldNotices = []
        held.forEach(notify)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in systemObservers { center.removeObserver(token) }
        systemObservers.removeAll()
        subscription?.cancel()
        subscription = nil
    }

    // MARK: - Startup reconciliation (§5.7)

    func reconcileAtStartup(now: Date) {
        // A0: an unreadable ledger stops scheduling; nothing is inferred.
        guard store.isReadable else { return }
        // A1: every pending record belongs to an earlier process; it ends honestly and never reruns.
        let stale = store.runs.filter { $0.status == .pending }
        do {
            try store.mutate { s in
                for run in stale {
                    try s.finish(run.id, run.isBound ? .interrupted : .failed(.notAdmitted), at: now)
                }
            }
        } catch {
            logs.error("Scheduled", "Startup reconciliation (pending runs) failed: \(error.localizedDescription)")
            return
        }
        for run in stale {
            guard let ended = store.runs.first(where: { $0.id == run.id }) else { continue }
            record(kind: "scheduled.reconcile", task: store.task(id: run.taskID), claimID: run.id, conversationID: run.conversationID,
                   summary: "Previous-process run ended as \(ended.status.rawValue)")
            if ended.status == .interrupted { notify(.runEnded(store.task(id: run.taskID), ended)) }
        }
        // A2: missed slots are folded once, from the ledger and the current time.
        guard realign(now: now) else { return }
        startupReconciled = true
    }

    /// A2: folds missed slots of every enabled, overdue task. A slot still inside the catch-up
    /// window stays as `nextNominalAt`, for the next tick to run as a catch-up.
    @discardableResult
    func realign(now: Date) -> Bool {
        guard store.isReadable else { return false }
        var oneTimeMissed: [ScheduledTask] = []
        do {
            try store.mutate { s in
                for task in s.tasks where task.isEnabled {
                    guard let nominal = task.nextNominalAt, nominal <= now else { continue }
                    let alignment = ScheduledRecurrence.alignedSlot(task: task, now: now)
                    guard alignment.slot != nominal || alignment.missed > 0 else { continue }
                    if alignment.missed > 0 {
                        s.insertRun(taskID: task.id, slot: nominal, trigger: .scheduled, status: .skipped,
                                    skipReason: .missedSlots, missedCount: alignment.missed, at: now)
                        if task.isOneTime { oneTimeMissed.append(task) }
                    }
                    try s.advance(taskID: task.id, to: alignment.slot ?? alignment.nextAfter)
                }
            }
        } catch {
            logs.error("Scheduled", "Realigning missed slots failed: \(error.localizedDescription)")
            return false
        }
        oneTimeMissed.forEach { notify(.oneTimeMissed($0)) }
        return true
    }

    // MARK: - Tick

    func tick(now: Date) {
        guard store.isReadable else { return }
        if !startupReconciled {
            reconcileAtStartup(now: now)
            guard startupReconciled else { return }
        }
        let due = store.tasks
            .filter { $0.isEnabled && ($0.nextNominalAt.map { $0 <= now } ?? false) }
            .sorted { $0.nextNominalAt! < $1.nextNominalAt! }
        // Concurrency 1: while a scheduled run is pending, only a task whose own run is pending is
        // handled (its slot is skipped as previousSlotPending); every other due task waits unchanged.
        let hasPending = store.pendingCount > 0
        for task in due {
            if hasPending && !store.runs.contains(where: { $0.taskID == task.id && $0.status == .pending }) { continue }
            let alignment = ScheduledRecurrence.alignedSlot(task: task, now: now)
            guard let slot = alignment.slot, let nominal = task.nextNominalAt else {
                foldOnly(task, alignment: alignment, now: now)
                continue
            }
            let trigger: ScheduledRun.Trigger = now.timeIntervalSince(slot) > Self.catchUpThreshold ? .catchUp : .scheduled
            dispatch(task, slot: slot, trigger: trigger, nextAfter: alignment.nextAfter,
                     missed: alignment.missed > 0 ? (anchor: nominal, count: alignment.missed) : nil, now: now)
            return // one dispatch per tick
        }
    }

    private func foldOnly(_ task: ScheduledTask, alignment: ScheduledRecurrence.Alignment, now: Date) {
        guard let nominal = task.nextNominalAt else { return }
        do {
            try store.mutate { s in
                if alignment.missed > 0 {
                    s.insertRun(taskID: task.id, slot: nominal, trigger: .scheduled, status: .skipped,
                                skipReason: .missedSlots, missedCount: alignment.missed, at: now)
                }
                try s.advance(taskID: task.id, to: alignment.nextAfter)
            }
        } catch {
            logs.error("Scheduled", "Advancing task '\(task.id)' past missed slots failed: \(error.localizedDescription)")
            return
        }
        if task.isOneTime && alignment.missed > 0 { notify(.oneTimeMissed(task)) }
    }

    // MARK: - Dispatch (§5.4): one synchronous segment on the main actor, no await

    private struct ResolvedTarget {
        var conversationID: UUID?
        var projectID: UUID?
        var isNew: Bool
    }

    private func resolveTarget(_ task: ScheduledTask) -> ResolvedTarget {
        switch task.target {
        case .newConversation(let projectID): ResolvedTarget(conversationID: nil, projectID: projectID, isNew: true)
        case .conversation(let id): ResolvedTarget(conversationID: id, projectID: nil, isNew: false)
        }
    }

    /// Order: previousSlotPending → targetConversationBusy → conversationGone / projectGone → modelUnavailable.
    private func preflightRefusal(_ task: ScheduledTask, _ target: ResolvedTarget) -> ScheduledRun.SkipReason? {
        if store.runs.contains(where: { $0.taskID == task.id && $0.status == .pending }) { return .previousSlotPending }
        if let id = target.conversationID {
            if !runs.canStartRun(conversationID: id) || runs.admissionHoldReason(conversationID: id) != nil { return .targetConversationBusy }
            if !conversations.conversations.contains(where: { $0.id == id }) { return .conversationGone }
        }
        if let projectID = target.projectID, !conversations.projects.contains(where: { $0.id == projectID }) { return .projectGone }
        let model = target.isNew ? (task.modelSource ?? interaction.modelSource(for: nil)) : interaction.modelSource(for: target.conversationID)
        guard let model, interaction.isModelUsable(model) else { return .modelUnavailable }
        return nil
    }

    private func dispatch(
        _ task: ScheduledTask,
        slot: Date,
        trigger: ScheduledRun.Trigger,
        nextAfter: Date?,
        missed: (anchor: Date, count: Int)?,
        now: Date
    ) {
        let target = resolveTarget(task)
        let refusal = preflightRefusal(task, target)
        let claimID = UUID()

        // W1: the claim (or the skip) and the plan's advance live and die together.
        do {
            try store.mutate { s in
                if trigger != .manual { try s.advance(taskID: task.id, to: nextAfter) }
                if let missed {
                    s.insertRun(taskID: task.id, slot: missed.anchor, trigger: .scheduled, status: .skipped,
                                skipReason: .missedSlots, missedCount: missed.count, at: now)
                }
                s.insertRun(id: claimID, taskID: task.id, slot: slot, trigger: trigger,
                            status: refusal == nil ? .pending : .skipped, skipReason: refusal, at: now)
            }
        } catch {
            logs.error("Scheduled", "Claiming slot of task '\(task.id)' failed: \(error.localizedDescription)")
            return // nothing happened; the next tick tries again
        }
        guard store.runs.contains(where: { $0.id == claimID }) else { return } // the slot was already claimed
        if let refusal {
            record(kind: "scheduled.skip", task: task, claimID: claimID, conversationID: target.conversationID, summary: "Skipped: \(refusal.rawValue)")
            return
        }
        let store = self.store
        let admission = interaction.submit(.init(
            conversationID: target.conversationID,
            projectID: target.projectID,
            text: ScheduledMessage.text(task: task, slot: slot),
            attachments: [],
            mode: .steerOrSend,
            modelSource: target.isNew ? task.modelSource : nil,
            thinkingLevelOverride: target.isNew ? task.thinkingLevel : nil,
            onRunAdmitted: { conversationID, runID in
                // W2, called by startRun before the execution Task exists.
                try store.mutate { s in try s.bind(claimID, conversationID: conversationID, runID: runID, at: Date()) }
            }
        ))

        if case .started(let conversationID, let runID, _) = admission {
            record(kind: "scheduled.dispatch", task: task, claimID: claimID, conversationID: conversationID, runID: runID,
                   summary: "Started \(trigger.rawValue) run")
            return // the terminal status comes from runFinished
        }
        // W3: the outcome of a run that never entered execution.
        let outcome: ScheduledRun.Outcome
        switch admission {
        case .refused(.noModel): outcome = .skipped(.modelUnavailable)
        case .refused(.conversationNotFound): outcome = .skipped(.conversationGone)
        case .refused(.projectNotFound): outcome = .skipped(.projectGone)
        case .refused(.held): outcome = .skipped(.targetConversationBusy)
        case .steered, .queued:
            record(kind: "scheduled.unexpectedAdmission", task: task, claimID: claimID, conversationID: admission.conversationID,
                   severity: .warning, summary: "Submit absorbed the scheduled input instead of starting a run")
            outcome = .failed(.notAdmitted)
        default: outcome = .failed(.notAdmitted)
        }
        do {
            try store.mutate { s in try s.finish(claimID, outcome, at: Date()) }
        } catch {
            logs.error("Scheduled", "Recording the outcome of scheduled run '\(claimID)' failed: \(error.localizedDescription)")
        }
        if let ended = store.runs.first(where: { $0.id == claimID }) {
            if ended.status == .skipped {
                record(kind: "scheduled.skip", task: task, claimID: claimID, conversationID: admission.conversationID,
                       summary: "Skipped: \(ended.skipReason?.rawValue ?? "")")
            } else {
                notify(.runEnded(task, ended))
            }
        }
    }

    // MARK: - Terminal status by run id (§5.6)

    private func runFinished(runID: UUID, status: ConversationRunStatus) {
        guard let claim = store.pendingRun(runID: runID) else { return } // a manual or subagent run
        let outcome: ScheduledRun.Outcome
        switch status {
        case .completed: outcome = .completed
        case .failed: outcome = .failed(.runFailed)
        case .cancelled: outcome = .cancelled
        case .interrupted: outcome = .interrupted
        case .queued, .running, .paused: return
        }
        do {
            try store.mutate { s in try s.finish(claim.id, outcome, at: Date()) }
        } catch {
            // Left pending on purpose: later slots skip as previousSlotPending until the next launch
            // reconciles it as interrupted. Fewer runs, visibly, rather than a repeated one.
            logs.error("Scheduled", "Recording the end of scheduled run '\(claim.id)' failed: \(error.localizedDescription)")
            return
        }
        let task = store.task(id: claim.taskID)
        if let ended = store.runs.first(where: { $0.id == claim.id }) {
            record(kind: "scheduled.finish", task: task, claimID: claim.id, conversationID: claim.conversationID, runID: runID,
                   summary: "Scheduled run ended as \(ended.status.rawValue)")
            notify(.runEnded(task, ended))
        }
    }

    // MARK: - Task editing (S-I01, S-I14)

    @discardableResult
    func create(_ task: ScheduledTask, now: Date = Date()) throws -> ScheduledTask {
        var task = try validated(task, now: now)
        task.createdAt = now
        task.updatedAt = now
        task.nextNominalAt = task.isEnabled ? ScheduledRecurrence.firstSlot(for: task, now: now) : nil
        let created = task
        try store.mutate { s in s.upsertTask(created) }
        return created
    }

    /// Saves an edit; a run in progress is unaffected. The plan is recomputed from now when the
    /// rule, the time zone or the switch changed.
    @discardableResult
    func update(_ task: ScheduledTask, now: Date = Date()) throws -> ScheduledTask {
        guard let existing = store.task(id: task.id) else { throw ScheduledStateStore.StoreError.taskNotFound }
        var task = try validated(task, now: now, previous: existing)
        task.createdAt = existing.createdAt
        task.updatedAt = now
        if !task.isEnabled {
            task.nextNominalAt = nil
        } else if task.schedule != existing.schedule || task.timeZoneID != existing.timeZoneID || !existing.isEnabled {
            task.nextNominalAt = ScheduledRecurrence.firstSlot(for: task, now: now)
        } else {
            task.nextNominalAt = existing.nextNominalAt
        }
        let updated = task
        try store.mutate { s in s.upsertTask(updated) }
        return updated
    }

    /// Pause: no next slot. Resume: from now, without catching up the paused time.
    func setEnabled(_ enabled: Bool, taskID: UUID, now: Date = Date()) throws {
        guard var task = store.task(id: taskID), task.isEnabled != enabled else { return }
        task.isEnabled = enabled
        task.updatedAt = now
        task.nextNominalAt = enabled ? ScheduledRecurrence.firstSlot(for: task, now: now) : nil
        let changed = task
        try store.mutate { s in s.upsertTask(changed) }
    }

    /// The project of a conversation; a task created from it opens its new conversations there.
    func projectID(ofConversation id: UUID) -> UUID? {
        conversations.conversations.first { $0.id == id }?.projectID
    }

    /// Removes the task; its conversations and messages stay.
    func delete(taskID: UUID) throws {
        try store.mutate { s in s.removeTask(id: taskID) }
    }

    @discardableResult
    func duplicate(taskID: UUID, name: String, now: Date = Date()) throws -> ScheduledTask {
        guard let source = store.task(id: taskID) else { throw ScheduledStateStore.StoreError.taskNotFound }
        var copy = source
        copy.id = UUID()
        copy.name = name
        if case .once(let fireAt) = copy.schedule, fireAt <= now { copy.isEnabled = false }
        return try create(copy, now: now)
    }

    /// Runs the task once now, unattended like a scheduled run; the plan does not move.
    func runNow(taskID: UUID, now: Date = Date()) throws {
        guard store.isReadable, startupReconciled else { throw ManualRunRefusal.notReadable }
        guard let task = store.task(id: taskID) else { throw ManualRunRefusal.taskNotFound }
        guard store.pendingCount == 0 else { throw ManualRunRefusal.anotherRunActive }
        dispatch(task, slot: now, trigger: .manual, nextAfter: nil, missed: nil, now: now)
    }

    private func validated(_ task: ScheduledTask, now: Date, previous: ScheduledTask? = nil) throws -> ScheduledTask {
        var task = task
        task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditError.emptyPrompt }
        if task.name.isEmpty { task.name = String(task.prompt.prefix(40)) }
        // A one-time time must be in the future unless an edit leaves it unchanged.
        if case .once(let fireAt) = task.schedule, task.isEnabled, fireAt <= now, previous?.schedule != task.schedule {
            throw EditError.oneTimeInPast
        }
        // Only a new conversation chooses a model and effort; a conversation target follows the conversation.
        if !task.target.isNewConversation {
            task.modelSource = nil
            task.thinkingLevel = nil
        }
        return task
    }

    // MARK: - Observability

    private func record(
        kind: String,
        task: ScheduledTask?,
        claimID: UUID,
        conversationID: UUID?,
        runID: UUID? = nil,
        severity: RuntimeEventSeverity = .info,
        summary: String
    ) {
        // An event with no conversation yet (a skip before a new conversation exists) is grouped
        // under the task id.
        var metadata = ["scheduledRunID": claimID.uuidString]
        if let task { metadata["scheduledTaskID"] = task.id.uuidString }
        runtimeEvents.record(conversationID: conversationID ?? task?.id ?? claimID, runID: runID ?? claimID, domain: .run,
                             kind: kind, severity: severity, summary: summary, metadata: metadata)
    }
}
