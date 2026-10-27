import Foundation
import Observation

/// Owns file restore for undo: builds previews, runs persistent restore plans step by step,
/// and offers the three exits when a step fails (continue, keep what was restored and retract
/// the message, or cancel and keep the files as they are). The message retraction itself stays with
/// `ChatStore` and `ConversationRunCoordinator`; this type only says when it may happen.
@MainActor
@Observable
final class UndoCoordinator {
    enum ResolveAction: Sendable {
        /// Retry the failed steps.
        case retry
        /// Keep the steps that succeeded, leave the failed paths as they are, retract the message.
        case keepAndRetract
        /// Stop where the restore is: restored files stay restored, the rest stay as they are,
        /// and the message stays.
        case cancel
    }

    @ObservationIgnored let journal: UndoJournalStore
    @ObservationIgnored private weak var conversationStore: ConversationStore?
    @ObservationIgnored private let logs: DebugLogStore
    /// Fault injection for tests: called before a step is applied; throwing fails that step.
    @ObservationIgnored var onWillApplyStep: ((UndoRestoreStep) throws -> Void)?
    /// Called when an undo plan closes, so held inputs can proceed.
    @ObservationIgnored var onHoldCleared: ((UUID) -> Void)?

    init(journal: UndoJournalStore, conversationStore: ConversationStore?, logs: DebugLogStore) {
        self.journal = journal
        self.conversationStore = conversationStore
        self.logs = logs
    }

    // MARK: - Preview

    func preview(conversationID: UUID, messageID: UUID, includeLeftovers: Bool = false) -> UndoPreview {
        let transcript = conversationStore?.conversations.first(where: { $0.id == conversationID })?.messages ?? []
        let blobs = journal.blobs
        return UndoRestorePlanner.preview(
            conversationID: conversationID, messageID: messageID, transcript: transcript,
            records: journal.records(for: conversationID), includeLeftovers: includeLeftovers,
            currentState: { location in try blobs.captureState(at: location, backup: false) })
    }

    func openPlan(for conversationID: UUID) -> UndoRestorePlan? {
        journal.openPlan(for: conversationID)
    }

    /// Why a new run must wait in this conversation, if it must.
    func admissionHoldReason(conversationID: UUID) -> String? {
        guard let plan = journal.openPlan(for: conversationID) else { return nil }
        switch plan.phase {
        case .partiallyFailed: return String(localized: "Some files from the last undo couldn't be restored. Resolve that first: continue, keep the restored files, or cancel.")
        case .filesRestored: return String(localized: "The last undo restored its files but hasn't retracted the message yet. Finish that undo first.")
        default: return String(localized: "The last undo isn't finished.")
        }
    }

    // MARK: - Restore

    /// Persists a plan for the preview's restorable items (required items plus the chosen
    /// optional ones) and runs it. Refuses a blocked preview; throws without writing anything
    /// when the plan cannot be saved, and stops writing as soon as progress cannot be saved.
    func restore(_ preview: UndoPreview, selectedOptionalPaths: Set<String> = [], retractsMessage: Bool = true) throws -> UndoRestorePlan {
        guard !preview.isBlocked else { throw UndoFileSystemError.restoreFailed("", String(localized: "There are conflicts, so files can't be restored")) }
        let items = preview.willRestore + preview.optional.filter { selectedOptionalPaths.contains($0.path) }
        let now = Date()
        let plan = UndoRestorePlan(
            id: UUID(), conversationID: preview.conversationID, messageID: preview.messageID,
            steps: items.map {
                UndoRestoreStep(path: $0.path, location: $0.location, expected: $0.expected, target: $0.target, recordIDs: $0.recordIDs,
                                createdDirectories: $0.createdDirectories, state: .pending, replaced: nil, failure: nil)
            },
            phase: .restoring, retractsMessage: retractsMessage, createdAt: now, updatedAt: now)
        try journal.savePlan(plan)
        return try run(plan.id) ?? plan
    }

    /// Applies the plan's pending (and, on retry, failed) steps. Each step is idempotent: a path
    /// already at its target counts as done, a path still at the expected state is restored
    /// (after backing up what it held), anything else fails the step as a conflict.
    ///
    /// Throws when the plan's progress cannot be saved: nothing more is written, and the plan
    /// stays open in the state last saved (re-running it is safe). The plan reaches
    /// `filesRestored` only once the restored records and the plan itself are saved.
    @discardableResult
    func run(_ planID: UUID) throws -> UndoRestorePlan? {
        guard var plan = journal.plans[planID] else { return nil }
        guard plan.phase == .restoring || plan.phase == .partiallyFailed else { return plan }
        for index in plan.steps.indices where plan.steps[index].state == .pending || plan.steps[index].state == .failed {
            var step = plan.steps[index]
            let location = step.anchoredLocation
            do {
                try onWillApplyStep?(step)
                let current = try journal.blobs.captureState(at: location, backup: false)
                if current.sameState(as: step.target) {
                    step.state = .done
                } else if current.sameState(as: step.expected) {
                    if step.replaced == nil {
                        step.replaced = try journal.blobs.captureState(at: location, backup: true)
                        plan.steps[index] = step
                        // The replaced content is safe before it is overwritten; if this save
                        // fails, the write does not happen (the error propagates).
                        try persist(&plan)
                    }
                    CrashInjection.point("undo.beforeApply")
                    try journal.blobs.apply(step.target, at: location)
                    CrashInjection.point("undo.afterApply")
                    if case .absent = step.target { journal.blobs.removeEmptyDirectories(step.createdDirectories, root: location.root) }
                    step.state = .done
                } else {
                    step.state = .failed
                    step.failure = String(localized: "The file was modified after the undo started")
                }
                step.failure = step.state == .done ? nil : step.failure
            } catch let error as UndoPersistenceError {
                throw error
            } catch AnchoredFileError.redirected(_), AnchoredFileError.rootMoved(_) {
                step.state = .failed
                step.failure = String(localized: "Conflict: a parent folder was replaced by a symbolic link or file, so restoring would write elsewhere")
            } catch {
                step.state = .failed
                step.failure = error.localizedDescription
            }
            plan.steps[index] = step
            try persist(&plan)
        }
        if plan.failedSteps.isEmpty {
            try markRestoredRecords(plan)
            plan.phase = .filesRestored
        } else {
            plan.phase = .partiallyFailed
        }
        try persist(&plan)
        CrashInjection.point("undo.filesRestored")
        return plan
    }

    /// What a cancelled undo left: the files it had restored (they stay restored) and the ones
    /// it had not reached (they stay as the turn left them). The message stays.
    struct Cancellation: Equatable, Sendable {
        let conversationID: UUID
        let messageID: UUID
        let restoredPaths: [String]
        let unrestoredPaths: [String]
    }

    /// The last cancellation per conversation, shown until dismissed.
    private(set) var cancellations: [UUID: Cancellation] = [:]

    func dismissCancellation(conversationID: UUID) { cancellations[conversationID] = nil }

    /// Resolves an open plan. `cancel` stops the restore where it is: files already restored
    /// stay restored, the rest stay as they are, and the message is kept. It is also the exit
    /// for a plan whose files are restored but whose message retraction keeps failing.
    /// Throws when the decision cannot be saved; the plan then stays open (and holds new runs).
    func resolve(_ planID: UUID, action: ResolveAction) throws -> UndoRestorePlan? {
        guard var plan = journal.plans[planID], plan.isOpen else { return nil }
        switch action {
        case .retry:
            return try run(planID)
        case .keepAndRetract:
            try markRestoredRecords(plan)
            plan.phase = .filesRestored
            try persist(&plan)
            return plan
        case .cancel:
            for index in plan.steps.indices where plan.steps[index].state != .done {
                plan.steps[index].state = .skipped
            }
            // Restored files keep their records' "reverted" status; the skipped ones stay
            // applied, so a later undo of this message can still restore them.
            try markRestoredRecords(plan)
            plan.phase = .cancelled
            try persist(&plan)
            let cancellation = Cancellation(
                conversationID: plan.conversationID, messageID: plan.messageID,
                restoredPaths: plan.steps.filter { $0.state == .done }.map(\.path),
                unrestoredPaths: plan.steps.filter { $0.state == .skipped }.map(\.path))
            journal.closePlan(plan.id)
            cancellations[plan.conversationID] = cancellation
            onHoldCleared?(plan.conversationID)
            return plan
        }
    }

    /// The message retraction of a `filesRestored` plan was committed (or the plan was a
    /// file-only restore): close it. Throws when the plan cannot be closed durably; it then
    /// stays open, and completing it again is safe.
    func complete(_ planID: UUID) throws {
        guard var plan = journal.plans[planID] else { return }
        plan.phase = .completed
        try persist(&plan)
        journal.closePlan(planID)
        onHoldCleared?(plan.conversationID)
    }

    /// Startup: re-runs plans interrupted mid-restore. Plans whose files are restored are
    /// returned so the caller can commit their pending message retraction.
    func reconcileStartup() -> [UndoRestorePlan] {
        journal.reconcileStartup()
        var awaitingRetraction: [UndoRestorePlan] = []
        for plan in journal.plans.values.sorted(by: { $0.createdAt < $1.createdAt }) where plan.isOpen {
            var current = plan
            if plan.phase == .restoring {
                do {
                    current = try run(plan.id) ?? plan
                } catch {
                    logs.error("Undo", "Could not resume restore plan '\(plan.id)': \(error.localizedDescription)")
                }
            }
            if current.phase == .filesRestored { awaitingRetraction.append(current) }
        }
        return awaitingRetraction
    }

    // MARK: - Internals

    private func markRestoredRecords(_ plan: UndoRestorePlan) throws {
        let ids = Set(plan.steps.filter { $0.state == .done }.flatMap(\.recordIDs))
        do {
            try journal.setStatus(.reverted, for: ids, conversationID: plan.conversationID)
        } catch {
            throw UndoPersistenceError.journal(error.localizedDescription)
        }
    }

    private func persist(_ plan: inout UndoRestorePlan) throws {
        do {
            try journal.savePlan(plan)
        } catch {
            logs.error("Undo", "Failed to persist restore plan '\(plan.id)': \(error.localizedDescription)")
            throw UndoPersistenceError.plan(error.localizedDescription)
        }
        plan = journal.plans[plan.id] ?? plan
    }
}

/// Undo state could not be saved; whatever depended on it did not happen.
enum UndoPersistenceError: LocalizedError, Equatable {
    case plan(String)
    case journal(String)

    var errorDescription: String? {
        switch self {
        case .plan(let reason): String(localized: "Couldn't save the undo progress: \(reason)")
        case .journal(let reason): String(localized: "Couldn't save the undo record: \(reason)")
        }
    }
}
