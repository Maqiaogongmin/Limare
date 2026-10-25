import Foundation

/// One multiple-choice question `ask_user_question` shows the user.
struct UserQuestion: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable {
        let label: String
        let description: String
    }

    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool

    init(question: String, header: String, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// Why these questions cannot be answered in a card, or nil when they can. Only inputs that
    /// break the card are refused; a long header is truncated by the card instead.
    static func validationProblem(_ questions: [UserQuestion]) -> String? {
        guard (1...4).contains(questions.count) else {
            return "Ask 1–4 questions; this call has \(questions.count)."
        }
        var seenQuestions: Set<String> = []
        for (index, question) in questions.enumerated() {
            let number = index + 1
            if question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Question \(number) has no question text."
            }
            guard seenQuestions.insert(question.question).inserted else {
                return "Question \(number) repeats the text of an earlier question."
            }
            guard (2...4).contains(question.options.count) else {
                return "Question \(number) has \(question.options.count) options; give 2–4."
            }
            var seenLabels: Set<String> = []
            for (optionIndex, option) in question.options.enumerated() {
                if option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Option \(optionIndex + 1) of question \(number) has no label."
                }
                guard seenLabels.insert(option.label).inserted else {
                    return "Question \(number) has two options labelled \"\(option.label)\"."
                }
            }
        }
        return nil
    }
}

/// The user's answer to one question: the options they selected and, when they chose Other,
/// their own words. `otherText` is non-nil while Other is selected, even before they type.
struct UserQuestionAnswer: Codable, Equatable, Sendable {
    var selectedLabels: [String]
    var otherText: String?

    init(selectedLabels: [String] = [], otherText: String? = nil) {
        self.selectedLabels = selectedLabels
        self.otherText = otherText
    }

    /// The Other text when it holds more than whitespace.
    var filledOtherText: String? {
        guard let otherText, !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return otherText
    }

    /// Why this answer does not answer `question`, or nil when it does.
    func problem(for question: UserQuestion) -> String? {
        let labels = Set(question.options.map(\.label))
        if let unknown = selectedLabels.first(where: { !labels.contains($0) }) {
            return "\"\(unknown)\" is not an option of \"\(question.question)\"."
        }
        if Set(selectedLabels).count != selectedLabels.count {
            return "An option of \"\(question.question)\" is selected twice."
        }
        if question.multiSelect {
            return selectedLabels.isEmpty && filledOtherText == nil ? "\"\(question.question)\" has no answer." : nil
        }
        switch (selectedLabels.count, filledOtherText) {
        case (1, nil), (0, .some): return nil
        case (0, nil): return "\"\(question.question)\" has no answer."
        default: return "\"\(question.question)\" takes one answer: one option or the user's own words."
        }
    }

    /// Whether this draft can be submitted for `question`.
    func answers(_ question: UserQuestion) -> Bool { problem(for: question) == nil }

    /// The selected labels in the order the question lists its options.
    func orderedLabels(for question: UserQuestion) -> [String] {
        question.options.map(\.label).filter(selectedLabels.contains)
    }
}

/// A question card a run waits on.
struct PendingUserQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    let runID: UUID
    let providerCallID: String
    let conversationTitle: String?
    let questions: [UserQuestion]
    let presentedAt: Date

    init(id: UUID = UUID(), conversationID: UUID, runID: UUID, providerCallID: String,
         conversationTitle: String?, questions: [UserQuestion], presentedAt: Date = Date()) {
        self.id = id
        self.conversationID = conversationID
        self.runID = runID
        self.providerCallID = providerCallID
        self.conversationTitle = conversationTitle
        self.questions = questions
        self.presentedAt = presentedAt
    }
}

/// How a question card ended.
enum UserQuestionResolution: Equatable, Sendable {
    /// One answer per question, in question order.
    case answered([UserQuestionAnswer])
    case skipped
    /// The user sent a new message instead of answering.
    case superseded
    /// The run stopped.
    case cancelled
}

enum UserQuestionError: LocalizedError, Equatable {
    /// The card is not (or no longer) waiting for an answer.
    case notPending
    case invalidAnswer(String)

    var errorDescription: String? {
        switch self {
        case .notPending: "This question is no longer waiting for an answer."
        case .invalidAnswer(let reason): reason
        }
    }
}

/// The fixed texts of `ask_user_question`: what the model reads and what the transcript shows.
enum UserQuestionText {
    static let refusal = "ask_user_question is not available in this run: no one can answer questions here. Continue with your best judgment and say in your final reply which decisions you assumed."

    /// The tool result the model reads. Nil for `.cancelled`, which takes the cancellation path.
    static func modelContent(questions: [UserQuestion], resolution: UserQuestionResolution) -> String? {
        switch resolution {
        case .answered(let answers):
            var lines = ["The user answered your questions:"]
            for (index, question) in questions.enumerated() {
                let answer = index < answers.count ? answers[index] : UserQuestionAnswer()
                lines.append("\(index + 1). \"\(question.question)\" → \(modelAnswer(answer, for: question))")
            }
            lines.append("Continue with these answers.")
            return lines.joined(separator: "\n")
        case .skipped:
            return "The user skipped these questions without answering. Continue with your best judgment, state the assumptions you make, and do not ask the same questions again."
        case .superseded:
            return "The user did not answer these questions and sent a new message instead, which follows. Treat the questions as unanswered and follow the new message."
        case .cancelled:
            return nil
        }
    }

    private static func modelAnswer(_ answer: UserQuestionAnswer, for question: UserQuestion) -> String {
        let labels = answer.orderedLabels(for: question).joined(separator: ", ")
        switch (labels.isEmpty, answer.filledOtherText) {
        case (false, nil): return "\"\(labels)\""
        case (true, .some(let text)): return "their own answer: \"\(text)\""
        case (false, .some(let text)): return "\"\(labels)\", plus their own answer: \"\(text)\""
        case (true, nil): return "\"\""
        }
    }

    /// The transcript's Markdown while the card waits: one paragraph per question.
    static func pendingOutput(questions: [UserQuestion]) -> String {
        questions.map { "**\($0.header)** \($0.question)" }.joined(separator: "\n\n")
    }
}
