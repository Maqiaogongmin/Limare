import SwiftUI
import AppKit

/// The question card a run of this window's conversation waits on (`ask_user_question`): each
/// question's options, an Other answer in the user's own words, Skip and Submit. The selections
/// and Other text live in `UserQuestionStore.drafts`, so they survive switching away and back.
struct UserQuestionCard: View {
    @Environment(AppState.self) private var appState
    let question: PendingUserQuestion
    /// The question area scrolls past this height; the buttons stay visible.
    let maximumHeight: CGFloat
    @State private var isResolving = false
    @FocusState private var focusedOther: Int?
    /// Takes the key focus into the card when an option is clicked, since a click on an option
    /// row leaves it where it was (often the composer).
    @State private var focus = CardFocus()

    private var store: UserQuestionStore { appState.userQuestions }

    private var draft: [UserQuestionAnswer] {
        store.drafts[question.id] ?? question.questions.map { _ in UserQuestionAnswer() }
    }

    private var canSubmit: Bool {
        draft.count == question.questions.count && zip(draft, question.questions).allSatisfy { $0.answers($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.standard) {
                    ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
                        questionBlock(index: index, item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maximumHeight)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: AppSpacing.small) {
                Spacer()
                Button("跳过", action: skip)
                    .buttonStyle(GhostTextButtonStyle())
                    .disabled(isResolving)
                    .help("不回答，结束这一轮，等你发消息")
                    .accessibilityIdentifier("question.skip")
                Button(action: submit) {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text("提交")
                        Text("⌘↩").opacity(0.6)
                    }
                }
                .buttonStyle(.charcoalProminent)
                .disabled(isResolving || !canSubmit)
                .accessibilityIdentifier("question.submit")
            }
        }
        // The rows reach 8pt from the card's edge; the text in them, and the question above
        // them, start 16pt in, level with the composer's draft below.
        .padding(.horizontal, AppSpacing.small)
        .padding(.top, AppSpacing.medium)
        .padding(.bottom, AppSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The composer's own material: the card reads as a drawer above it, not an alert.
        .raisedCardSurface()
        .accessibilityElement(children: .contain)
        // ⌘↩ submits only while the key focus is inside the card; the composer keeps its own.
        .background(CommandReturnCatcher(focus: focus, otherFieldIsFocused: focusedOther != nil, action: submit))
        .accessibilityIdentifier("question.card")
    }

    @ViewBuilder
    private func questionBlock(index: Int, item: UserQuestion) -> some View {
        let answer = index < draft.count ? draft[index] : UserQuestionAnswer()
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            if question.questions.count > 1, !item.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(Self.chipText(item.header))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.vertical, AppSpacing.xxxSmall)
                    .background(AppColors.quietLinkFill, in: RoundedRectangle(cornerRadius: AppRadius.small))
                    .padding(.horizontal, AppSpacing.small)
            }
            Text(item.question)
                .font(AppTypography.interfaceSemibold)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, AppSpacing.small)

            VStack(spacing: AppSpacing.xxxSmall) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { optionIndex, option in
                    optionRow(index: index, optionIndex: optionIndex, option: option, item: item,
                              isSelected: answer.selectedLabels.contains(option.label))
                }
                otherRow(index: index, item: item, answer: answer)
            }
        }
    }

    private func optionRow(index: Int, optionIndex: Int, option: UserQuestion.Option, item: UserQuestion, isSelected: Bool) -> some View {
        Button {
            update(index) { $0.toggle(option.label, multiSelect: item.multiSelect) }
            // A multiple choice keeps the Other field it is typed in; otherwise the card takes the focus.
            if item.multiSelect, focusedOther != nil { return }
            focus.take()
        } label: {
            QuestionChoiceRow(isSelected: isSelected, isEnabled: !isResolving) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    selectionMark(isSelected: isSelected, multiSelect: item.multiSelect)
                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        Text(option.label)
                            .font(AppTypography.interface)
                            .fixedSize(horizontal: false, vertical: true)
                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(AppTypography.interfaceSubheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isResolving)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("question.option.\(index + 1).\(optionIndex + 1)")
    }

    /// Other is a field always in the row: typing selects it, emptying it deselects it. A click
    /// on its mark or the row only puts the caret in the field.
    private func otherRow(index: Int, item: UserQuestion, answer: UserQuestionAnswer) -> some View {
        let isSelected = answer.otherText != nil
        return QuestionChoiceRow(isSelected: isSelected, isEnabled: !isResolving) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Button {
                    focusedOther = index
                } label: {
                    selectionMark(isSelected: isSelected, multiSelect: item.multiSelect)
                }
                .buttonStyle(.plain)
                .disabled(isResolving)
                .accessibilityLabel("其他")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("question.other.\(index + 1)")

                TextField("其他回答…", text: Binding(
                    get: { draft[safe: index]?.otherText ?? "" },
                    set: { text in update(index) { $0.setOtherText(text, multiSelect: item.multiSelect) } }
                ), axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppTypography.interface)
                .lineLimit(1...6)
                .focused($focusedOther, equals: index)
                .disabled(isResolving)
                .accessibilityIdentifier("question.other.\(index + 1).text")
            }
        }
        .onTapGesture {
            guard !isResolving else { return }
            focusedOther = index
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectionMark(isSelected: Bool, multiSelect: Bool) -> some View {
        let symbol = multiSelect
            ? (isSelected ? "checkmark.square.fill" : "square")
            : (isSelected ? "largecircle.fill.circle" : "circle")
        // Charcoal, like the composer's send button and Submit: no system blue in the card.
        return Image(systemName: symbol)
            .foregroundStyle(isSelected ? AppColors.sendFill : Color.primary.opacity(0.35))
            .accessibilityHidden(true)
    }

    private func update(_ index: Int, _ change: (inout UserQuestionAnswer) -> Void) {
        var answers = draft
        guard index < answers.count, store.question(id: question.id) != nil else { return }
        change(&answers[index])
        store.drafts[question.id] = answers
    }

    private func submit() {
        guard !isResolving, canSubmit else { return }
        isResolving = true
        do {
            try store.answer(id: question.id, answers: draft)
        } catch {
            isResolving = false
            appState.logs.info("Questions", "Answer not taken: \(error.localizedDescription)")
        }
    }

    private func skip() {
        guard !isResolving else { return }
        isResolving = true
        do {
            try store.skip(id: question.id)
        } catch {
            isResolving = false
            appState.logs.info("Questions", "Skip not taken: \(error.localizedDescription)")
        }
    }

    /// A header longer than a chip holds ends in an ellipsis.
    static func chipText(_ header: String) -> String {
        header.count > 12 ? String(header.prefix(12)) + "…" : header
    }
}

/// One row of a question, an option or the Other field: a rounded tint marks the selection, a
/// fainter one the pointer. Each row tracks its own hover.
private struct QuestionChoiceRow<Content: View>: View {
    let isSelected: Bool
    let isEnabled: Bool
    @ViewBuilder let content: Content
    @State private var isHovering = false

    private var fill: Color {
        if isSelected { return AppColors.choiceSelected }
        return isHovering && isEnabled ? AppColors.choiceHover : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
        content
            .padding(AppSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(fill)
                    .animation(AppMotion.resolved(AppMotion.quick), value: fill)
            }
            .contentShape(shape)
            .onHover { isHovering = $0 }
    }
}

/// The card's own place for the key focus: the catcher view behind it.
@MainActor
private final class CardFocus {
    weak var view: CommandReturnCatcher.CatcherView?

    func take() { view?.takeFocus() }
}

/// Runs `action` on ⌘↩ while the key focus is in the card: on the catcher itself (after a click
/// on an option) or in an Other field. A key equivalent reaches every view in the window before
/// the focused field's own keyDown, so the card takes ⌘↩ without a window-wide shortcut.
private struct CommandReturnCatcher: NSViewRepresentable {
    let focus: CardFocus
    let otherFieldIsFocused: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        focus.view = view
        view.otherFieldIsFocused = otherFieldIsFocused
        view.action = action
    }

    final class CatcherView: NSView {
        var otherFieldIsFocused = false
        var action: (() -> Void)?
        /// Only a click in the card makes this view the first responder; the window never picks
        /// it on its own, so the card's arrival leaves the focus where it is.
        private var isTakingFocus = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { isTakingFocus }
        override var canBecomeKeyView: Bool { false }

        func takeFocus() {
            guard let window, window.firstResponder !== self else { return }
            isTakingFocus = true
            window.makeFirstResponder(self)
            isTakingFocus = false
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  window?.firstResponder === self || otherFieldIsFocused else { return false }
            action?()
            return true
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
