import Foundation

enum ConversationRunStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case paused
    case interrupted
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .queued, .running, .paused:
            return false
        case .interrupted, .completed, .failed, .cancelled:
            return true
        }
    }
}

enum RunStartReason: String, Codable, Sendable, Equatable {
    case userPrompt
    case systemNotice
    case recovery
}

struct ConversationRun: Identifiable, Sendable, Equatable {
    let id: UUID
    let conversationID: UUID
    var status: ConversationRunStatus
    let startedAt: Date
    var completedAt: Date?
    var error: String?
    var recoveredFromRunID: UUID?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        status: ConversationRunStatus = .queued,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        error: String? = nil,
        recoveredFromRunID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
        self.recoveredFromRunID = recoveredFromRunID
    }
}

/// A user instruction waiting for the current conversation run to finish.
/// It deliberately owns the original message payload so attachments survive
/// until the queued run actually begins.
struct QueuedConversationInput: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let conversationID: UUID
    let message: ChatMessage
    let modelSource: ConversationModelSource
    let createdAt: Date
    let isSystemNotice: Bool?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        message: ChatMessage,
        modelSource: ConversationModelSource,
        createdAt: Date = Date(),
        isSystemNotice: Bool? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.message = message
        self.modelSource = modelSource
        self.createdAt = createdAt
        self.isSystemNotice = isSystemNotice
    }
}
