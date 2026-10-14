import Foundation

public enum StreamingSendPreference: String, CaseIterable, Identifiable, Sendable {
    case queue = "queue"
    case steer = "steer"

    public static let storageKey = "limare.composer.streamingSendPreference"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .queue: "Queue for next turn"
        case .steer: "Steer active turn"
        }
    }

    public var detail: String {
        switch self {
        case .queue: "Appends the message to the queue to be processed after the current run completes."
        case .steer: "Injects the instruction immediately into the currently active run."
        }
    }
}
