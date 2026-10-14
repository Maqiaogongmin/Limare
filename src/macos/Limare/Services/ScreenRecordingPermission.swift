import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

public enum ScreenRecordingPermissionStatus: String, Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

public protocol ScreenRecordingPermissionAuthorizing: AnyObject, Sendable {
    func authorizationStatus() -> ScreenRecordingPermissionStatus
    func requestAccess() async -> Bool
}

public final class MacScreenRecordingPermissionAuthorizer: ScreenRecordingPermissionAuthorizing, @unchecked Sendable {
    public init() {}

    public func authorizationStatus() -> ScreenRecordingPermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        } else {
            return .denied
        }
    }

    public func requestAccess() async -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if granted { return true }
        return CGPreflightScreenCaptureAccess()
    }
}
