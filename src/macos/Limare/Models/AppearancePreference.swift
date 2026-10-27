import Foundation
import AppKit

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public static let storageKey = "app_appearance_preference"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    @MainActor
    public func apply() {
        let appAppearance: NSAppearance? = {
            switch self {
            case .system:
                return nil
            case .light:
                return NSAppearance(named: .aqua)
            case .dark:
                return NSAppearance(named: .darkAqua)
            }
        }()
        NSApp.appearance = appAppearance
        for window in NSApplication.shared.windows {
            window.appearance = appAppearance
        }
    }
}

