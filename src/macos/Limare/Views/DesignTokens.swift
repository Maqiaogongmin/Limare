import SwiftUI
import AppKit

enum AppSpacing {
    static let xxxSmall: CGFloat = 2
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 6
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let standard: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 24
    static let chatHorizontal: CGFloat = 24
    static let chatVertical: CGFloat = 20
}

enum AppRadius {
    static let small: CGFloat = 4
    static let row: CGFloat = 6
    static let card: CGFloat = 8
    static let modal: CGFloat = 10
    static let bubble: CGFloat = 12
    static let composer: CGFloat = 14
    static let badge: CGFloat = 10
    static let full: CGFloat = 9999
}

enum AppControlHeight {
    static let mini: CGFloat = 18
    static let small: CGFloat = 22
    static let regular: CGFloat = 26
    static let row: CGFloat = 30
    static let button: CGFloat = 32
    static let composerButton: CGFloat = 28
}

enum AppLayout {
    static let workspaceHeaderHeight: CGFloat = 44
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 224
    static let sidebarMaximumWidth: CGFloat = 280
    static let transcriptMaximumWidth: CGFloat = 760
    static let userMessageMaximumWidth: CGFloat = 560
    static let settingsListMinimumWidth: CGFloat = 210
    static let settingsListIdealWidth: CGFloat = 230
    static let settingsListMaximumWidth: CGFloat = 280
    static let settingsDetailMinimumWidth: CGFloat = 480
    static let approvalMinimumWidth: CGFloat = 520
    static let approvalIdealWidth: CGFloat = 600
    static let messageGutterMinimumWidth: CGFloat = 80
    static let toolOutputMaximumHeight: CGFloat = 180
    static let workSurfaceMinimumWidth: CGFloat = 320
    static let workSurfaceIdealWidth: CGFloat = 460
    static let workSurfaceMaximumWidth: CGFloat = 700
    static let previewMinimumWidth: CGFloat = workSurfaceMinimumWidth
    static let previewIdealWidth: CGFloat = workSurfaceIdealWidth
    static let previewMaximumWidth: CGFloat = workSurfaceMaximumWidth
    static let filesTreeMinimumWidth: CGFloat = 180
    static let filesTreeIdealWidth: CGFloat = 190
    static let filesTreeMaximumWidth: CGFloat = 360
    static let filesPreviewMinimumWidth: CGFloat = 240
    static let chatMinimumWidth: CGFloat = 380
    static let composerDraftMinimumHeight: CGFloat = 32
    static let composerDraftNormalMaximumHeight: CGFloat = 200
    static let composerDraftExpandedMaximumHeight: CGFloat = 420
    static let userMessageCollapsedMaximumHeight: CGFloat = 130
    static let userMessageExpandedMaximumHeight: CGFloat = 360
}

// MARK: - Semantic Design Tokens

enum AppSemanticSpacing {
    static let settingsPageInset: CGFloat = 20
    static let settingsSectionGap: CGFloat = 16
    static let settingsRowGap: CGFloat = 8
    static let settingsFieldGap: CGFloat = 6
    static let settingsRowVerticalPadding: CGFloat = 4
    static let settingsRowControlGap: CGFloat = 16
    static let resourceListRowPaddingVertical: CGFloat = 6
    static let resourceListRowPaddingHorizontal: CGFloat = 8
    static let badgePaddingVertical: CGFloat = 2
    static let badgePaddingHorizontal: CGFloat = 6
}

enum AppSemanticLayout {
    static let resourceSidebarMinimumWidth: CGFloat = 220
    static let resourceSidebarIdealWidth: CGFloat = 250
    static let resourceSidebarMaximumWidth: CGFloat = 300
    static let settingsDetailContentMaxWidth: CGFloat = 720
}

enum AppColors {
    static var surfacePrimary: Color { Color(nsColor: .windowBackgroundColor) }
    static var surfaceSecondary: Color { Color(nsColor: .controlBackgroundColor) }
    static var surfaceElevated: Color { Color.secondary.opacity(0.06) }
    static var surfaceInteractive: Color { Color.secondary.opacity(0.08) }

    static var textPrimary: Color { Color.primary }
    static var textSecondary: Color { Color.secondary }
    static var textMuted: Color { Color.secondary.opacity(0.7) }

    static var statusSuccess: Color { Color.green }
    static var statusWarning: Color { Color.orange }
    static var statusError: Color { Color.red }
    static var statusInfo: Color { Color.blue }

    static var selection: Color { Color.accentColor.opacity(0.14) }
    static var separator: Color { Color.secondary.opacity(0.15) }
    static var borderMuted: Color { Color.secondary.opacity(0.18) }
}

// MARK: - Semantic Typography Tokens

@MainActor
public enum AppTypography {
    // MARK: - Point Sizes (Derived live from TypographyPreferences)
    public static var interfacePointSize: CGFloat {
        CGFloat(TypographyPreferences.shared.interfaceSize)
    }

    public static var conversationPointSize: CGFloat {
        CGFloat(TypographyPreferences.shared.conversationSize)
    }

    public static var codePointSize: CGFloat {
        CGFloat(TypographyPreferences.shared.codeSize)
    }

    // MARK: - Interface Semantic Tokens
    public static var interface: Font {
        .system(size: interfacePointSize)
    }

    public static var interfaceMedium: Font {
        .system(size: interfacePointSize, weight: .medium)
    }

    public static var interfaceSemibold: Font {
        .system(size: interfacePointSize, weight: .semibold)
    }

    public static var interfaceBold: Font {
        .system(size: interfacePointSize, weight: .bold)
    }

    public static var interfaceSubheadline: Font {
        .system(size: max(11, interfacePointSize - 1))
    }

    public static var interfaceSecondary: Font {
        .system(size: max(10, interfacePointSize - 2))
    }

    public static var interfaceCaption: Font {
        .system(size: max(10, interfacePointSize - 3))
    }

    public static var interfaceCaption2: Font {
        .system(size: max(9, interfacePointSize - 4))
    }

    public static var interfaceHeadline: Font {
        .system(size: interfacePointSize + 1, weight: .semibold)
    }

    public static var interfaceTitle: Font {
        .system(size: interfacePointSize + 4, weight: .semibold)
    }

    public static var interfaceTitle2: Font {
        .system(size: interfacePointSize + 2, weight: .semibold)
    }

    public static var interfaceNSFont: NSFont {
        NSFont.systemFont(ofSize: interfacePointSize, weight: .regular)
    }

    // MARK: - Conversation Semantic Tokens
    public static var chatBody: Font {
        .system(size: conversationPointSize)
    }

    public static var chatBodyItalic: Font {
        .system(size: conversationPointSize).italic()
    }

    public static var chatSecondary: Font {
        .system(size: max(11, conversationPointSize - 2))
    }

    public static var chatLineSpacing: CGFloat {
        3.0
    }

    public static var chatNSFont: NSFont {
        NSFont.systemFont(ofSize: conversationPointSize, weight: .regular)
    }

    // MARK: - Code Semantic Tokens
    public static var code: Font {
        .system(size: codePointSize, design: .monospaced)
    }

    public static var codeBold: Font {
        .system(size: codePointSize, weight: .bold, design: .monospaced)
    }

    public static var codeNSFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: codePointSize, weight: .regular)
    }

    public static var codeMeta: Font {
        .system(size: max(10, min(12, interfacePointSize - 2)), weight: .medium, design: .monospaced)
    }
}
