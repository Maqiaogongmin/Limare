import Foundation
import Observation

@Observable
@MainActor
public final class TypographyPreferences: @unchecked Sendable {
    public static let shared = TypographyPreferences()

    // MARK: - Default Constants
    public static let defaultInterfaceSize: Double = 14.0
    public static let defaultConversationSize: Double = 15.0
    public static let defaultCodeSize: Double = 13.0

    // MARK: - Allowed Options
    public static let interfaceSizeOptions: [Double] = [13.0, 14.0, 15.0, 16.0]
    public static let conversationSizeOptions: [Double] = [14.0, 15.0, 16.0, 17.0, 18.0]
    public static let codeSizeOptions: [Double] = [11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0]

    // MARK: - Storage Keys
    public static let interfaceStorageKey = "app_typography_interface_size"
    public static let conversationStorageKey = "app_typography_conversation_size"
    public static let codeStorageKey = "app_typography_code_size"

    // MARK: - Properties
    public var interfaceSize: Double {
        didSet {
            let clamped = Self.clamp(interfaceSize, to: Self.interfaceSizeOptions, fallback: Self.defaultInterfaceSize)
            if clamped != interfaceSize {
                interfaceSize = clamped
                return
            }
            UserDefaults.standard.set(interfaceSize, forKey: Self.interfaceStorageKey)
        }
    }

    public var conversationSize: Double {
        didSet {
            let clamped = Self.clamp(conversationSize, to: Self.conversationSizeOptions, fallback: Self.defaultConversationSize)
            if clamped != conversationSize {
                conversationSize = clamped
                return
            }
            UserDefaults.standard.set(conversationSize, forKey: Self.conversationStorageKey)
        }
    }

    public var codeSize: Double {
        didSet {
            let clamped = Self.clamp(codeSize, to: Self.codeSizeOptions, fallback: Self.defaultCodeSize)
            if clamped != codeSize {
                codeSize = clamped
                return
            }
            UserDefaults.standard.set(codeSize, forKey: Self.codeStorageKey)
        }
    }

    // MARK: - Initialization
    public init(userDefaults: UserDefaults = .standard) {
        let storedInterface = userDefaults.object(forKey: Self.interfaceStorageKey) as? Double
        let storedConversation = userDefaults.object(forKey: Self.conversationStorageKey) as? Double
        let storedCode = userDefaults.object(forKey: Self.codeStorageKey) as? Double

        self.interfaceSize = Self.clamp(storedInterface ?? Self.defaultInterfaceSize, to: Self.interfaceSizeOptions, fallback: Self.defaultInterfaceSize)
        self.conversationSize = Self.clamp(storedConversation ?? Self.defaultConversationSize, to: Self.conversationSizeOptions, fallback: Self.defaultConversationSize)
        self.codeSize = Self.clamp(storedCode ?? Self.defaultCodeSize, to: Self.codeSizeOptions, fallback: Self.defaultCodeSize)
    }

    // MARK: - Reset
    public func resetToDefaults() {
        interfaceSize = Self.defaultInterfaceSize
        conversationSize = Self.defaultConversationSize
        codeSize = Self.defaultCodeSize
    }

    // MARK: - Clamping & Validation
    public static func clamp(_ value: Double, to options: [Double], fallback: Double) -> Double {
        guard !options.isEmpty else { return fallback }
        if options.contains(value) {
            return value
        }
        guard let minVal = options.min(), let maxVal = options.max() else { return fallback }
        if value < minVal {
            return minVal
        }
        if value > maxVal {
            return maxVal
        }
        // If between bounds but not matching an exact option, find closest
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? fallback
    }

    public static func formatSize(_ size: Double) -> String {
        "\(Int(size)) pt"
    }
}
