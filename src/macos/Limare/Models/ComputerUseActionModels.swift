import Foundation

/// Computer-use facts recorded on tool-call records (the action, its status, input release).
public enum ComputerUseActionKind: String, Codable, Sendable, CaseIterable {
    case moveCursor = "move_cursor"
    case click = "click"
    case typeText = "type_text"
    case hotkey = "hotkey"
    case drag = "drag"
    case scroll = "scroll"
    case wait = "wait"
}

public enum ComputerUseActionResultStatus: String, Codable, Sendable, Equatable {
    case dispatched = "dispatched"
    case denied = "denied"
    case blocked = "blocked"
    case unsupported = "unsupported"
    case permissionMissing = "permission_missing"
    case staleObservation = "stale_observation"
    case targetChanged = "target_changed"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case indeterminate = "indeterminate"
    case failed = "failed"
}

public enum ComputerUseTransientReleaseOutcome: Codable, Sendable, Equatable {
    case notApplicable
    case released
    case failed(String)
}
