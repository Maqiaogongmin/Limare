import Foundation
import Observation

/// The question cards runs wait on (`ask_user_question`), one per conversation at most.
///
/// It is the one place that knows a conversation waits for the user's answer: the card, the
/// sidebar mark, the elsewhere notice and Remote all read `pending`. A run waits here with the
/// same continuation-and-cancellation pattern PermissionStore uses for approvals, but cards are
/// kept per conversation rather than in one global queue, so one conversation's card never waits
/// behind another's. Each card ends exactly once, and its runtime events are recorded where it ends.
@MainActor
@Observable
final class UserQuestionStore {
    /// Called when a card is shown (the Background Alerts notifier listens).
    @ObservationIgnored var onQuestionPresented: ((PendingUserQuestion) -> Void)?
    /// Whether a run is an unattended scheduled run (ConversationRunCoordinator.isUnattended);
    /// set by the composition root. No one can answer such a run's questions.
    @ObservationIgnored var isUnattendedRun: ((UUID) -> Bool)?

    /// Waiting cards by conversation ID.
    private(set) var pending: [UUID: PendingUserQuestion] = [:]
    /// The user's unsent answers by card ID, one per question. Kept in memory only while the card
    /// waits, so switching away and back (or a second window) shows the same draft.
    var drafts: [UUID: [UserQuestionAnswer]] = [:]

    @ObservationIgnored
    private var continuations: [UUID: CheckedContinuation<UserQuestionResolution, Never>] = [:]

    private let logs: DebugLogStore
    private let runtimeEvents: RuntimeEventStore?

    init(logs: DebugLogStore, runtimeEvents: RuntimeEventStore? = nil) {
        self.logs = logs
        self.runtimeEvents = runtimeEvents
    }

    /// The waiting card with this ID, if any.
    func question(id: UUID) -> PendingUserQuestion? {
        pending.values.first { $0.id == id }
    }

    /// Shows `question` and waits until the user answers, skips, sends a new message, or the run stops.
    func ask(_ question: PendingUserQuestion) async -> UserQuestionResolution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UserQuestionResolution, Never>) in
                present(question, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(id: question.id, with: .cancelled)
            }
        }
    }

    private func present(_ question: PendingUserQuestion, continuation: CheckedContinuation<UserQuestionResolution, Never>) {
        // A run asks one question at a time; a card left behind by an earlier run ends here.
        if let stale = pending[question.conversationID] {
            logs.error("Questions", "Conversation '\(question.conversationID)' already waited on question '\(stale.id)'; cancelling it.")
            resolve(id: stale.id, with: .cancelled)
        }
        pending[question.conversationID] = question
        drafts[question.id] = question.questions.map { _ in UserQuestionAnswer() }
        continuations[question.id] = continuation
        record(question, kind: "question.presented", summary: "Waiting for your answer")
        logs.info("Questions", "Asked \(question.questions.count) question(s) in conversation '\(question.conversationID)'.")
        onQuestionPresented?(question)
    }

    /// Answers the waiting card `id`; one answer per question, in question order.
    func answer(id: UUID, answers: [UserQuestionAnswer]) throws {
        guard let question = question(id: id) else { throw UserQuestionError.notPending }
        guard answers.count == question.questions.count else {
            throw UserQuestionError.invalidAnswer("Give one answer per question: \(question.questions.count) expected, \(answers.count) given.")
        }
        for (answer, item) in zip(answers, question.questions) {
            if let problem = answer.problem(for: item) { throw UserQuestionError.invalidAnswer(problem) }
        }
        resolve(id: id, with: .answered(answers))
    }

    func skip(id: UUID) throws {
        guard question(id: id) != nil else { throw UserQuestionError.notPending }
        resolve(id: id, with: .skipped)
    }

    /// The user sent a new message to this conversation instead of answering.
    func supersede(conversationID: UUID) {
        guard let question = pending[conversationID] else { return }
        resolve(id: question.id, with: .superseded)
    }

    /// The run stopped: its card ends without an answer.
    func cancel(conversationID: UUID, runID: UUID) {
        guard let question = pending[conversationID], question.runID == runID else { return }
        resolve(id: question.id, with: .cancelled)
    }

    /// Ends card `id` once: whichever path arrives later finds nothing to end.
    private func resolve(id: UUID, with resolution: UserQuestionResolution) {
        guard let question = question(id: id), let continuation = continuations.removeValue(forKey: id) else { return }
        pending[question.conversationID] = nil
        drafts[id] = nil
        let (kind, summary) = switch resolution {
        case .answered: ("question.answered", "Question answered")
        case .skipped: ("question.skipped", "Question skipped")
        case .superseded: ("question.superseded", "Question left for a new message")
        case .cancelled: ("question.cancelled", "Question cancelled")
        }
        record(question, kind: kind, summary: summary)
        logs.info("Questions", "\(summary) in conversation '\(question.conversationID)'.")
        continuation.resume(returning: resolution)
    }

    private func record(_ question: PendingUserQuestion, kind: String, summary: String) {
        runtimeEvents?.record(conversationID: question.conversationID, runID: question.runID, domain: .tool, kind: kind,
                              summary: summary, metadata: ["tool": "ask_user_question", "toolCallID": question.providerCallID])
    }
}
