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
    /// The air between sidebar sections, which replaces the rules that used to divide them.
    static let sidebarSectionGap: CGFloat = 18
    /// Between the composer and the window's bottom edge.
    static let composerBottom: CGFloat = 14
    /// Between the composer's draft and its button row; with the editor's own 6pt inset, 22pt
    /// between the text and the buttons.
    static let composerDraftToolbarGap: CGFloat = 16
    /// The same in a new conversation's fuller composer.
    static let emptyStateDraftToolbarGap: CGFloat = 28
    /// A new conversation: between the greeting's line and the composer card.
    static let emptyStateGreetingGap: CGFloat = 30
    /// The Work Surface sheet's inset from the window's edges and the chat beside it.
    static let workSurfaceInset: CGFloat = 8
    /// The sheet's top in the title bar, level with the sidebar's.
    static let workSurfaceTopInset: CGFloat = 10
}

enum AppRadius {
    static let small: CGFloat = 4
    static let row: CGFloat = 6
    static let card: CGFloat = 8
    static let modal: CGFloat = 10
    static let bubble: CGFloat = 12
    /// A file card in the transcript, and the tile its icon sits in.
    static let fileCard: CGFloat = 10
    static let fileIconTile: CGFloat = 7
    static let composer: CGFloat = 14
    /// The composer card itself (its menus keep `composer`).
    static let composerCard: CGFloat = 12
    /// The composer's send, stop and pause tiles, in step with the card's corners.
    static let runButton: CGFloat = 8
    /// Ghost icon buttons' hover fill, the composer's pills and the sidebar's card button.
    static let control: CGFloat = 8
    static let badge: CGFloat = 10
    /// The inset Work Surface sheet.
    static let workSurfaceSheet: CGFloat = 14
    /// Settings cards and the log table.
    static let settingsCard: CGFloat = 12
    static let full: CGFloat = 9999
}

enum AppControlHeight {
    /// The hit size of a toolbar icon button.
    static let iconSmall: CGFloat = 20
    static let mini: CGFloat = 18
    static let small: CGFloat = 22
    static let regular: CGFloat = 26
    static let row: CGFloat = 30
    static let button: CGFloat = 32
    static let composerButton: CGFloat = 28
    /// The composer's send, stop and pause tiles.
    static let runButton: CGFloat = 28
    /// The composer's thinking and model pills.
    static let pill: CGFloat = 26
}

enum AppLayout {
    static let workspaceHeaderHeight: CGFloat = 44
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 224
    static let sidebarMaximumWidth: CGFloat = 280
    static let transcriptMaximumWidth: CGFloat = 760
    /// A user's message wraps past this width; a shorter one hugs its text.
    static let userMessageMaximumWidth: CGFloat = 460
    static let settingsListMinimumWidth: CGFloat = 210
    static let settingsListIdealWidth: CGFloat = 230
    static let settingsListMaximumWidth: CGFloat = 280
    static let settingsDetailMinimumWidth: CGFloat = 480
    static let approvalMinimumWidth: CGFloat = 520
    static let approvalIdealWidth: CGFloat = 600
    static let messageGutterMinimumWidth: CGFloat = 100
    /// A file card in the transcript: compact, never the column's whole width.
    static let fileCardMinimumWidth: CGFloat = 220
    static let fileCardMaximumWidth: CGFloat = 320
    static let toolOutputMaximumHeight: CGFloat = 180
    /// Long tool arguments (a large file_write, for example) scroll inside this height,
    /// as the tool output already does.
    static let toolInputMaximumHeight: CGFloat = 180
    /// The `/` and `@` menus scroll past this height instead of running off the window.
    static let composerMenuMaximumHeight: CGFloat = 240
    /// The composer's model button text, beyond which it truncates in the middle; room for a
    /// group name with the model it uses.
    static let composerModelLabelMaximumWidth: CGFloat = 240
    /// A new conversation gathers its greeting and the composer in a column this
    /// wide, centred at `emptyStateCenterFraction` of the chat's height.
    static let emptyStateMaximumWidth: CGFloat = 680
    static let emptyStateCenterFraction: CGFloat = 0.45
    /// A new conversation's composer card, at least this tall.
    static let emptyStateComposerMinimumHeight: CGFloat = 110
    /// Below this chat width the greeting steps down from its full size.
    static let emptyStateCompactWidth: CGFloat = 540
    /// The fade at a scrolling transcript's or document's edges, where lines leave the view.
    static let scrollEdgeFade: CGFloat = 18
    /// The transcript's top edge, under the title bar: fully clear, then a fade to full ink.
    static let transcriptTopClear: CGFloat = 12
    static let transcriptTopFade: CGFloat = 20
    static let workSurfaceMinimumWidth: CGFloat = 320
    static let workSurfaceIdealWidth: CGFloat = 460
    static let workSurfaceMaximumWidth: CGFloat = 700
    /// A pointer must move this far before the divider starts resizing: a stray click
    /// near the panel edge must not change its width.
    static let workSurfaceDragDeadZone: CGFloat = 4
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
    /// The fade at the bottom of a collapsed user message.
    static let userMessageCollapseFadeHeight: CGFloat = 28
}

// MARK: - Motion

@MainActor
enum AppMotion {
    /// Small state changes: hover reveals, icon toggles. 0.12s.
    static let quick = Animation.easeInOut(duration: 0.12)
    /// The drag handles' hover highlight, which eases out. 0.12s.
    static let quickOut = Animation.easeOut(duration: 0.12)
    /// The common disclosure/expand curve. 0.15s.
    static let standard = Animation.easeInOut(duration: 0.15)
    /// Layout changes that move more than a few points. 0.18s.
    static let layout = Animation.easeInOut(duration: 0.18)
    /// Column/coverage changes. 0.25s.
    static let panel = Animation.easeInOut(duration: 0.25)
    /// Confirmation feedback (short) and its hold (longer).
    static let confirm = Animation.easeOut(duration: 0.2)
    static let confirmHold = Animation.easeOut(duration: 0.4)
    /// The message navigator's pointer spring. Slower curves stay here, not inline.
    static let pointer = Animation.spring(response: 0.22, dampingFraction: 0.85)
    /// The composer settling from the empty state's centre to the bottom on the first message.
    static let composerSettle = Animation.spring(response: 0.36, dampingFraction: 0.84)

    /// Reduce Motion reads the system setting at call time: animations are then skipped
    /// entirely (`nil`), which is what the setting asks for.
    static func resolved(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }
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
    /// Every settings page's column: this wide at most, this far from the sidebar, this far
    /// below the title bar, so switching pages never moves its left edge.
    static let settingsPageMaxWidth: CGFloat = 680
    static let settingsPageLeading: CGFloat = 36
    static let settingsPageTop: CGFloat = 28
    /// The master list of a two-column settings page (Providers, Model Groups).
    static let settingsMasterListWidth: CGFloat = 230
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

    // The appearance-dependent colours are made once: each `NSColor(name:dynamicProvider:)` is
    // equal only to itself, so one made per read never matches the last and every view that
    // compares it (a Markdown theme, a SwiftUI style) takes it for a change.
    /// The chat canvas: a cool neutral off-white in light mode rather than pure white, so the
    /// white composer card stands apart from it; no warm cast against the system sidebar.
    static let canvas: Color = dynamic(light: 0xF7F7F8, dark: 0x0D0E11)
    /// The composer card and the sidebar's New Conversation card, one step above the canvas.
    static let raisedSurface: Color = dynamic(light: 0xFFFFFF, dark: 0x17181E)
    static let raisedStroke = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.08)
    })
    /// The composer card's edge: a crisp 1pt line that marks the card, in place of a shadow.
    static let composerStroke = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.13)
    })
    /// The composer's thinking and model menus: bare text quieter than the draft, a tint only
    /// under the pointer.
    static var pillText: Color { Color.primary.opacity(0.60) }
    static var pillHover: Color { Color.primary.opacity(0.05) }
    /// A user's message on the canvas: a white card (a raised slate in dark), edged in
    /// `cardStroke`.
    static let userBubble: Color = dynamic(light: 0xFFFFFF, dark: 0x1C1D23)
    /// A file card in the transcript.
    static let fileCard: Color = dynamic(light: 0xFFFFFF, dark: 0x18191F)
    /// The 1pt edge of a card lying in the transcript: a user message, a file card.
    static let cardStroke = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.085)
    })
    /// The icons under a user message: faint, near full ink under the pointer.
    static var bubbleActionIdle: Color { Color.primary.opacity(0.38) }
    static var bubbleActionHover: Color { Color.primary.opacity(0.85) }
    /// A text action inside a status line ("View run details", "查看撤销"): charcoal on a faint
    /// tint, never the system link blue.
    static var quietLinkText: Color { Color.primary.opacity(0.78) }
    static var quietLinkFill: Color { Color.primary.opacity(0.05) }
    static var quietLinkHover: Color { Color.primary.opacity(0.09) }
    /// A reply the runtime wrote (a failed request, a stop): a small tinted status line.
    static var noticeFill: Color { Color.primary.opacity(0.04) }
    /// A white piece lying on the canvas (a launcher row, a settings card): its hairline edge.
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.07)
    })
    /// The Work Surface sheet, inset on the canvas, and what its surfaces paint.
    static let workSurface: Color = Color(nsColor: workSurfaceNSColor)
    static let workSurfaceNSColor: NSColor = dynamicNSColor(light: 0xFFFFFF, dark: 0x17181E)
    /// Ghost icon buttons: no fill at rest, this one under the pointer.
    static var ghostIdle: Color { Color.secondary.opacity(0.75) }
    static var ghostHover: Color { Color.primary.opacity(0.06) }
    /// The send button once there is something to send: near-black in light mode, near-white in dark.
    static let sendFill: Color = dynamic(light: 0x18181B, dark: 0xF4F4F5)
    static let sendGlyph: Color = dynamic(light: 0xFFFFFF, dark: 0x18181B)
    /// A switch that is on: charcoal in light mode; forest green in dark, where a near-white
    /// track would lose the white knob.
    /// Restrained status text: forest green for a healthy state, dark red for danger.
    static let positiveText: Color = dynamic(light: 0x15803D, dark: 0x4ADE80)
    static let dangerText: Color = dynamic(light: 0xB91C1C, dark: 0xF87171)
    /// A caution glyph beside quiet text (the scheduled editor's unattended note): dark amber.
    static let cautionIcon: Color = dynamic(light: 0xB45309, dark: 0xF59E0B)
    /// A destructive icon under the pointer (an archived row's trash).
    static let dangerHover: Color = dynamic(light: 0xDC2626, dark: 0xF87171)
    /// A text editor set into a white card: a shade warmer than the card.
    static let editorWell: Color = dynamic(light: 0xFAF9F7, dark: 0x121317)
    static let controlOn: Color = dynamic(light: 0x18181B, dark: 0x16A34A)

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    static func dynamicNSColor(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { isDark($0) ? color(dark) : color(light) }
    }
}

/// A borderless icon button: no fill at rest, a soft rounded fill and full-strength colour
/// under the pointer. The composer's tools and the window's toolbar buttons use it.
struct GhostIconButtonStyle: ButtonStyle {
    var size: CGFloat = AppControlHeight.composerButton
    var iconSize: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        GhostIconBody(configuration: configuration, size: size, iconSize: iconSize)
    }

    private struct GhostIconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let iconSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: iconSize))
                .foregroundStyle(isHovering && isEnabled ? AppColors.textPrimary : AppColors.ghostIdle)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovering && isEnabled || configuration.isPressed ? AppColors.ghostHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
                .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
        }
    }
}

/// A text action set in a status line: 12pt medium charcoal on a faint 6pt tint, a step
/// darker under the pointer.
struct QuietLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietLinkBody(configuration: configuration)
    }

    private struct QuietLinkBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.quietLinkText)
                .padding(.horizontal, AppSpacing.xSmall)
                .padding(.vertical, AppSpacing.xxxSmall)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .fill(isHovering || configuration.isPressed ? AppColors.quietLinkHover : AppColors.quietLinkFill)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
        }
    }
}

extension View {
    /// The composer's thinking and model menus: quiet bare text, a faint rounded tint under the
    /// pointer.
    func composerPill() -> some View {
        modifier(ComposerPill())
    }
}

private struct ComposerPill: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(AppColors.pillText)
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .fill(isHovering ? AppColors.pillHover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
    }
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
