import Foundation

public enum AgentRunStatus: String, Codable, Sendable, Equatable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    case timedOut

    public var displayName: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .timedOut: String(localized: "Timed Out")
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            false
        case .completed, .failed, .cancelled, .timedOut:
            true
        }
    }
}
