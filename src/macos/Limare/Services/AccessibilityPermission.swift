import Foundation
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Accessibility Permission Status & Protocol (Section 13, CU-I47, CU-I48, CU-I49)

public enum AccessibilityPermissionStatus: String, Codable, Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
}

public protocol AccessibilityPermissionAuthorizing: Sendable {
    /// Queries the live macOS Accessibility TCC status.
    /// Status is never cached indefinitely (CU-I49).
    func authorizationStatus() -> AccessibilityPermissionStatus
}

// MARK: - Mac Production Authorizer

public final class MacAccessibilityPermissionAuthorizer: AccessibilityPermissionAuthorizing, @unchecked Sendable {
    public init() {}

    public func authorizationStatus() -> AccessibilityPermissionStatus {
        #if canImport(ApplicationServices)
        // Pass prompt: false so checking status never automatically triggers an OS dialog (CU-I48)
        let options = ["AXTrustedCheckOptionPrompt" as CFString: kCFBooleanFalse] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        return isTrusted ? .authorized : .denied
        #else
        return .denied
        #endif
    }
}

// MARK: - Accessibility Settings Helper (Section 15)

public enum AccessibilitySettingsOpener: Sendable {
    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    public static let privacySecuritySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Security")

    @MainActor
    public static func openAccessibilitySettings() {
        #if canImport(AppKit)
        if let url = accessibilitySettingsURL,
           NSWorkspace.shared.open(url) {
            return
        }
        if let url = privacySecuritySettingsURL {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
