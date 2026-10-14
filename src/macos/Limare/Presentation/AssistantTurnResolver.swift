import Foundation

enum AssistantTurnResolver {

    // MARK: - Assistant Turn Communication Semantics (RP-I15)

    /// Determines whether the message renders as Level 1 primary prose in the transcript.
    ///
    /// Under RP-I15.A, `ChatMessage.content` is the primary conversational channel between Agent and User.
    /// Non-empty assistant prose is ALWAYS Level 1 visible regardless of whether `toolCalls` are present.
    /// Tool presence does NOT downgrade prose to "execution narration" or hide it.
    ///
    /// For tool-only assistant messages (empty content with toolCalls), returns `false` to avoid
    /// synthesizing empty text blocks, placeholder text, or phantom communication bubbles (RP-I15.C).
    static func shouldShowPrimaryProse(message: ChatMessage) -> Bool {
        guard message.role == .assistant else { return false }
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // When content is empty: only show streaming or interrupted status indicator if there are no tools
        if message.toolCalls.isEmpty {
            if message.state == .streaming || message.state == .interrupted {
                return true
            }
        }
        return false
    }

    // MARK: - Turn Structure

    /// Returns whether the given message is the terminal (last) Assistant message in its Assistant Turn.
    static func isTerminalAssistantMessage(messageID: UUID, in messages: [ChatMessage]) -> Bool {
        guard let currentIndex = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        let currentMessage = messages[currentIndex]
        guard currentMessage.role == .assistant else { return false }

        // Check subsequent messages: if there is another assistant message before the next user message, this is NOT terminal
        for i in (currentIndex + 1)..<messages.count {
            let nextMsg = messages[i]
            if nextMsg.role == .user {
                return true
            }
            if nextMsg.role == .assistant {
                return false
            }
        }
        return true
    }

    /// Returns all Assistant messages belonging to the same Logical Turn as `messageID`.
    ///
    /// A Logical Turn is defined as the contiguous sequence of Assistant messages between two User messages
    /// (or between conversation start/user message and the next user message / conversation end).
    static func turnMessages(for messageID: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        guard let currentIndex = messages.firstIndex(where: { $0.id == messageID }) else { return [] }
        let currentMessage = messages[currentIndex]
        guard currentMessage.role == .assistant else { return [] }

        // Find the start of this turn (first assistant message after previous user message)
        var startIndex = currentIndex
        while startIndex > 0 && messages[startIndex - 1].role == .assistant {
            startIndex -= 1
        }

        // Find the end of this turn (last assistant message before next user message)
        var endIndex = currentIndex
        while endIndex + 1 < messages.count && messages[endIndex + 1].role == .assistant {
            endIndex += 1
        }

        return Array(messages[startIndex...endIndex])
    }

    // MARK: - Turn-Level Action Completion Authority Sentinel (RP-I06, RP-I15.H)

    /// Evaluates whether the given assistant message serves as the terminal completed action anchor for its turn.
    ///
    /// Under RP-I06 and RP-I15.H, turn-level actions (Copy Response and Read Aloud) require:
    /// 1. The message is the positional terminal Assistant message of the logical turn.
    /// 2. `state == .complete`.
    /// 3. `toolCalls.isEmpty` (Agent Loop completion sentinel certifying the run has concluded).
    ///
    /// NOTE on Action Authority vs. Visibility Orthogonality:
    /// `toolCalls.isEmpty` here acts solely as an Agent Loop completion sentinel / action authority evidence.
    /// It MUST NOT be reused to classify prose, determine Level 1 visibility, or hide intermediate assistant prose.
    static func isTerminalCompletedTurnActionAnchor(messageID: UUID, in messages: [ChatMessage]) -> Bool {
        guard isTerminalAssistantMessage(messageID: messageID, in: messages) else { return false }
        guard let target = messages.first(where: { $0.id == messageID }) else { return false }
        guard target.state == .complete else { return false }
        guard target.toolCalls.isEmpty else { return false }
        return true
    }

    // MARK: - Final Answer Payload

    /// Resolves the final answer of the logical turn containing `messageID`.
    ///
    /// The final answer is the content of the last assistant message in the turn that carries non-empty
    /// prose. Intermediate prose emitted while tools ran (progress reports such as "let me check…") is
    /// excluded, as are reasoning content, tool records, runtime notes, and metadata.
    static func turnFinalAnswerPayload(for messageID: UUID, in messages: [ChatMessage]) -> String? {
        turnMessages(for: messageID, in: messages).last { msg in
            msg.role == .assistant && !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.content
    }

    // MARK: - Copy Response (RP-I06)

    /// Determines whether a turn can show the formal Turn-level Copy action.
    ///
    /// Requires the message to be the terminal completed turn action anchor (`terminal + complete + toolCalls.isEmpty`)
    /// and a non-empty final answer. Intermediate execution messages—even if temporarily terminal
    /// while tools run—strictly yield `false`.
    static func canCopyTurn(for messageID: UUID, in messages: [ChatMessage]) -> Bool {
        guard isTerminalCompletedTurnActionAnchor(messageID: messageID, in: messages) else { return false }
        guard let payload = turnFinalAnswerPayload(for: messageID, in: messages), !payload.isEmpty else {
            return false
        }
        return true
    }

    /// Resolves the raw Markdown of the turn's final answer.
    static func turnCopyPayload(for messageID: UUID, in messages: [ChatMessage]) -> String? {
        turnFinalAnswerPayload(for: messageID, in: messages)
    }

    /// Single authority for the formal Copy Response action.
    ///
    /// Returns the payload ONLY when `canCopyTurn` has granted eligibility, and `nil` otherwise.
    /// Every Copy Response UI entry point (inline button and assistant context menu) consumes this.
    static func authorizedTurnCopyPayload(for messageID: UUID, in messages: [ChatMessage]) -> String? {
        guard canCopyTurn(for: messageID, in: messages) else { return nil }
        return turnFinalAnswerPayload(for: messageID, in: messages)
    }

    // MARK: - Formal Read Aloud / Speaker (RP-I15.H)

    /// Determines whether a turn can expose the Speaker / Read Aloud action.
    ///
    /// Evaluated independently from Copy Response, but requires the identical completion sentinel
    /// (`terminal + complete + toolCalls.isEmpty`) and a non-empty final answer.
    static func canReadAloudTurn(for messageID: UUID, in messages: [ChatMessage]) -> Bool {
        guard isTerminalCompletedTurnActionAnchor(messageID: messageID, in: messages) else { return false }
        guard let payload = turnFinalAnswerPayload(for: messageID, in: messages), !payload.isEmpty else {
            return false
        }
        return true
    }

    /// Single authority for the formal Read Aloud action.
    ///
    /// Returns the turn's final answer as the spoken payload ONLY when `canReadAloudTurn` has granted
    /// eligibility, strictly excluding intermediate prose, reasoning, and tool details.
    static func authorizedTurnReadAloudPayload(for messageID: UUID, in messages: [ChatMessage]) -> String? {
        guard canReadAloudTurn(for: messageID, in: messages) else { return nil }
        return turnFinalAnswerPayload(for: messageID, in: messages)
    }
}
