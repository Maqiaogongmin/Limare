import Foundation

public enum AgentRunStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case timedOut

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .completed, .failed, .cancelled, .timedOut:
            true
        }
    }
}
