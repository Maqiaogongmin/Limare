import Foundation

/// The presentation projection of an Assistant turn message.
///
/// This is the seam the transcript renders from: `MessageRow` resolves one of these per message
/// to determine Level 1 communication visibility and Turn-level action affordances.
struct AssistantTurnPresentation: Sendable, Equatable {
    let messageID: UUID
    /// Whether the assistant message renders as Level 1 primary prose in the transcript.
    let showsPrimaryProse: Bool
    /// Whether the assistant message serves as the terminal action anchor exposing Turn Read Aloud.
    let showsSpeakerAction: Bool
    /// Spoken payload for Read Aloud (the turn's final answer only).
    let authorizedSpeakerPayload: String?

    init(
        messageID: UUID,
        showsPrimaryProse: Bool,
        showsSpeakerAction: Bool,
        authorizedSpeakerPayload: String? = nil
    ) {
        self.messageID = messageID
        self.showsPrimaryProse = showsPrimaryProse
        self.showsSpeakerAction = showsSpeakerAction
        self.authorizedSpeakerPayload = authorizedSpeakerPayload
    }
}

/// Projects a `ChatMessage` into the transcript presentation model.
enum AssistantTurnProjector {

    /// Resolves the presentation for one message in the context of the conversation.
    static func project(message: ChatMessage, allMessages: [ChatMessage]) -> AssistantTurnPresentation {
        guard message.role == .assistant else {
            return AssistantTurnPresentation(
                messageID: message.id,
                showsPrimaryProse: false,
                showsSpeakerAction: false,
                authorizedSpeakerPayload: nil
            )
        }

        let showsProse = AssistantTurnResolver.shouldShowPrimaryProse(message: message)
        let canSpeaker = AssistantTurnResolver.canReadAloudTurn(for: message.id, in: allMessages)
        let speakerPayload = canSpeaker ? AssistantTurnResolver.authorizedTurnReadAloudPayload(for: message.id, in: allMessages) : nil

        return AssistantTurnPresentation(
            messageID: message.id,
            showsPrimaryProse: showsProse,
            showsSpeakerAction: canSpeaker,
            authorizedSpeakerPayload: speakerPayload
        )
    }
}
