import SwiftUI

extension EnvironmentValues {
    /// The view sits inside a turn's folded execution history, whose answered questions the
    /// fold already shows outside it.
    @Entry var isInExecutionFold = false
}

/// What an `ask_user_question` card asked and how the user answered, kept in the conversation
/// once the card is gone: a quiet block on a left rule, the question over its answer.
struct AnsweredQuestionsView: View {
    let toolCall: ToolCallRecord

    var body: some View {
        if let resolution = toolCall.questionResolution,
           let questions = UserQuestionArguments.questions(from: toolCall.input) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        Text(question.question)
                            .font(AppTypography.interfaceSubheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .answered(let answers) = resolution, index < answers.count {
                            answerLines(answers[index], for: question)
                        }
                    }
                }
                if let status = Self.statusText(resolution) {
                    Text(status)
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(.tertiary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentRule()
            // Selectable text does not merge into a combined element, so the block says itself.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.spokenText(questions: questions, resolution: resolution))
            .accessibilityIdentifier("question.answered")
        }
    }

    @ViewBuilder
    private func answerLines(_ answer: UserQuestionAnswer, for question: UserQuestion) -> some View {
        let labels = answer.orderedLabels(for: question)
        if !labels.isEmpty {
            Text(labels.joined(separator: "、"))
                .font(AppTypography.interface)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let other = answer.filledOtherText {
            Text(other)
                .font(AppTypography.interface)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The block read as one sentence per question, then the closing line.
    static func spokenText(questions: [UserQuestion], resolution: RecordedQuestionResolution) -> String {
        var lines = questions.enumerated().map { index, question -> String in
            guard case .answered(let answers) = resolution, index < answers.count else { return question.question }
            let answer = answers[index]
            let parts = [answer.orderedLabels(for: question).joined(separator: "、"), answer.filledOtherText ?? ""].filter { !$0.isEmpty }
            return question.question + " " + parts.joined(separator: "；")
        }
        if let status = statusText(resolution) { lines.append(status) }
        return lines.joined(separator: "\n")
    }

    /// The closing line of a card that got no answer.
    static func statusText(_ resolution: RecordedQuestionResolution) -> String? {
        switch resolution {
        case .answered: nil
        case .skipped: String(localized: "Skipped without an answer")
        case .superseded: String(localized: "Not answered: you sent a new message")
        }
    }
}
