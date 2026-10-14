import Foundation

public enum AgentTaskEffortProfile: String, Codable, Sendable, Equatable, CaseIterable {
    case quick = "quick"
    case standard = "standard"
    case deep = "deep"

    public var maximumRuntimeSeconds: TimeInterval {
        switch self {
        case .quick: return 120
        case .standard: return 300
        case .deep: return 600
        }
    }

    public var maximumTurns: Int {
        switch self {
        case .quick: return 8
        case .standard: return 15
        case .deep: return 25
        }
    }

    public static let globalHardCeilingSeconds: TimeInterval = 720

    public static func resolve(from string: String?) -> AgentTaskEffortProfile {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let profile = AgentTaskEffortProfile(rawValue: s) else {
            return .standard
        }
        return profile
    }
}
