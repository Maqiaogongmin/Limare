import Foundation
import Observation

@MainActor
@Observable
public final class ScrollFollowCoordinator {
    public enum DetachReason: String, Sendable, Equatable {
        case userScrolledAway
        case textSelectionActive
    }

    public private(set) var isNearBottom: Bool = true
    public private(set) var isFollowingTail: Bool = true
    public private(set) var detachReason: DetachReason? = nil
    public private(set) var isUserScrollInteractionActive: Bool = false
    private var lastObservedUserMessageID: UUID?

    public init(isNearBottom: Bool = true, isFollowingTail: Bool = true) {
        self.isNearBottom = isNearBottom
        self.isFollowingTail = isFollowingTail
    }

    /// User scroll gesture begins (e.g. tracking / interacting). Immediately detaches follow mode
    /// without relying on cached geometry, suppressing any in-flight streaming deltas.
    public func userScrollInteractionBegan() {
        isUserScrollInteractionActive = true
        isFollowingTail = false
        detachReason = .userScrolledAway
    }

    /// Viewport geometry update. Proximity truth only; does NOT alter user follow intent or detach reason.
    public func updateViewportProximity(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
    }

    /// User scroll gesture ended (e.g. returned to idle). Inspects the latest geometry truth.
    /// If near bottom, restores follow mode; otherwise maintains detached state.
    public func userScrollInteractionEnded(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
        self.isUserScrollInteractionActive = false
        if isNearBottom {
            self.isFollowingTail = true
            self.detachReason = nil
        } else {
            self.isFollowingTail = false
            self.detachReason = .userScrolledAway
        }
    }

    /// User scroll interaction truth. Called when user interaction changes the scroll position.
    public func userDidScroll(isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
        if !isNearBottom {
            self.isFollowingTail = false
            self.detachReason = .userScrolledAway
        } else {
            self.isFollowingTail = true
            self.detachReason = nil
        }
    }

    /// Scoped callback invoked when the user selects text inside this message list.
    public func textSelectionBecameActive() {
        isFollowingTail = false
        detachReason = .textSelectionActive
    }

    /// Explicit user action returning to bottom.
    public func userReturnedToBottom() {
        isNearBottom = true
        isFollowingTail = true
        detachReason = nil
    }

    /// Explicit user action scrolling away from bottom.
    public func userScrolledAway() {
        isNearBottom = false
        isFollowingTail = false
        detachReason = .userScrolledAway
    }

    public func recordUserMessageID(_ id: UUID?) {
        lastObservedUserMessageID = id
    }

    func shouldScrollOnMessageUpdate(messages: [ChatMessage]) -> Bool {
        let latestUserMessage = messages.last(where: { $0.role == .user })
        let latestUserMessageID = latestUserMessage?.id

        if let latestUserMessageID, latestUserMessageID != lastObservedUserMessageID {
            lastObservedUserMessageID = latestUserMessageID
            isFollowingTail = true
            detachReason = nil
            return true
        }

        return isFollowingTail
    }

    public func shouldScrollOnUserMessage(latestUserMessageID: UUID?) -> Bool {
        if let latestUserMessageID, latestUserMessageID != lastObservedUserMessageID {
            lastObservedUserMessageID = latestUserMessageID
            isFollowingTail = true
            detachReason = nil
            return true
        }

        return isFollowingTail
    }
}
