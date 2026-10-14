import Foundation

// MARK: - Layer 2 App Authorization States (Doc 68 §4, §10, CU-OQ-05, CU-I53)

/// Ephemeral Layer-2 app authorization status for active desktop control.
/// Scoped strictly to conversationID × bundleID.
public enum ComputerUseAppAuthorizationState: String, Codable, Sendable, Equatable {
    case unknown
    case allowedForConversation
    case blockedForConversation
}

/// Explicit pending Layer-2 resolution result to distinguish cancellation from human decision.
public enum ComputerUseAppApprovalResolution: String, Codable, Sendable, Equatable {
    case allowedForConversation
    case blockedForConversation
    case cancelled
}

/// Presentation payload for a pending human Layer-2 App authorization decision.
public struct ComputerUseAppApprovalPending: Identifiable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let bundleID: String
    public let appLocalizedName: String

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        bundleID: String,
        appLocalizedName: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.bundleID = bundleID
        let trimmedName = appLocalizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appLocalizedName = (trimmedName?.isEmpty == false) ? trimmedName! : bundleID
    }
}
