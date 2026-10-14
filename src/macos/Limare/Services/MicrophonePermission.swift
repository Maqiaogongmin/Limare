import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif

public enum MicrophonePermissionStatus: String, Sendable, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

public protocol MicrophonePermissionAuthorizing: AnyObject, Sendable {
    func authorizationStatus() -> MicrophonePermissionStatus
    func requestAccess() async -> Bool
}

public final class MacMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing, @unchecked Sendable {
    public init() {}

    public func authorizationStatus() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public enum PrivacySettingsOpener: Sendable {
    public static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    public static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    public static let privacySecuritySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Security")

    @MainActor
    public static func openMicrophoneSettings() {
        #if canImport(AppKit)
        if let url = microphoneSettingsURL,
           NSWorkspace.shared.open(url) {
            return
        }
        if let url = privacySecuritySettingsURL {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    @MainActor
    public static func openScreenRecordingSettings() {
        #if canImport(AppKit)
        if let url = screenRecordingSettingsURL,
           NSWorkspace.shared.open(url) {
            return
        }
        if let url = privacySecuritySettingsURL {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
