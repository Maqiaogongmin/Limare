import SwiftUI

#if canImport(MarkdownView)
import AppKit
import MarkdownView
import MarkdownParser
import Litext

public struct LimareMarkdownView: View {
    public enum Profile: Equatable, Sendable {
        case chat(isStreaming: Bool, messageId: String)
        case document
        /// Text a person typed: a single newline starts a new line, as it did in the composer.
        case typed
    }

    public let source: String
    public let profile: Profile
    public let onSelectionBecameActive: (@MainActor () -> Void)?

    public init(
        source: String,
        profile: Profile,
        onSelectionBecameActive: (@MainActor () -> Void)? = nil
    ) {
        self.source = source
        self.profile = profile
        self.onSelectionBecameActive = onSelectionBecameActive
    }

    /// Where a clicked link goes: the surrounding view's `openURL` (the chat routes web links
    /// to the Work Surface browser; elsewhere the system opens them).
    @Environment(\.openURL) private var openURL

    public var body: some View {
        // Reading the sizes here makes them dependencies of this body (TypographyPreferences
        // is @Observable): a change in Settings re-evaluates it, and the representable gets
        // the new sizes through `updateNSView`.
        let typography = TypographyPreferences.shared
        LimareMarkdownRepresentable(
            source: source,
            profile: profile,
            conversationPointSize: CGFloat(typography.conversationSize),
            codePointSize: CGFloat(typography.codeSize),
            onSelectionBecameActive: onSelectionBecameActive,
            openURL: openURL
        )
        // A reply fills the column; what a person typed hugs its text, so a two-word message
        // sits in a two-word bubble.
        .frame(maxWidth: profile == .typed ? nil : .infinity, alignment: .topLeading)
    }
}

@MainActor
final class LimareStreamView: MarkdownStreamView {
    var onSelectionBecameActive: (@MainActor () -> Void)?

    override func textLabelView(_ label: TextLabelView, didChangeSelection selection: NSRange?) {
        super.textLabelView(label, didChangeSelection: selection)
        if let selection, selection.length > 0 {
            onSelectionBecameActive?()
        }
    }
}

@MainActor
struct LimareMarkdownRepresentable: NSViewRepresentable {
    let source: String
    let profile: LimareMarkdownView.Profile
    let conversationPointSize: CGFloat
    let codePointSize: CGFloat
    let onSelectionBecameActive: (@MainActor () -> Void)?
    let openURL: OpenURLAction

    /// The theme for the given sizes. The sizes come in explicitly (from the observing body),
    /// never read from the preferences here.
    ///
    /// Two tracks share one body: a conversation keeps its headings within a few points of the
    /// text, so they never crowd a narrow column; a document (a README in the Work Surface)
    /// gives them a wider ladder and more room above.
    ///
    /// Replies and documents are read in the bundled serif (`ReadingFont`); what a person typed
    /// stays in the system font, so the two voices differ. Code is monospaced in all three.
    static func makeTheme(
        conversationPointSize: CGFloat,
        codePointSize: CGFloat,
        profile: LimareMarkdownView.Profile = .document
    ) -> MarkdownTheme {
        let size = conversationPointSize
        let isDocument = profile == .document
        let isTyped = profile == .typed
        var theme = MarkdownTheme.default
        theme.softBreaksAreLineBreaks = isTyped

        // Inline code a step under the body, on a faint tint.
        theme.fonts.codeInline = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        theme.fonts.code = NSFont.monospacedSystemFont(ofSize: codePointSize, weight: .regular)
        theme.fonts.codeBlockLabel = NSFont.monospacedSystemFont(ofSize: codePointSize - 1.5, weight: .regular)
        // The heading ladders, as offsets from the text size.
        let headingSizes: [CGFloat] = isDocument ? [8, 3.5, 1, 0] : [3, 1.5, 0.5, 0]
        if isTyped {
            theme.fonts.body = NSFont.systemFont(ofSize: size)
            theme.fonts.bold = NSFont.boldSystemFont(ofSize: size)
            theme.fonts.italic = theme.fonts.italic.withSize(size)
            theme.headings = headingSizes.enumerated().map { level, offset in
                .init(font: .systemFont(ofSize: size + offset, weight: level == 3 ? .medium : .semibold))
            }
        } else {
            theme.fonts.body = ReadingFont.regular(size: size)
            theme.fonts.bold = ReadingFont.semibold(size: size)
            // Upright: Chinese has no italic, and emphasis keeps its underline.
            theme.fonts.italic = ReadingFont.regular(size: size)
            // No tightened letter spacing: serif CJK crowds when kerned in.
            theme.headings = headingSizes.map { .init(font: ReadingFont.semibold(size: size + $0)) }
        }
        theme.fonts.title = theme.headings[0].font
        theme.fonts.largeTitle = theme.headings[0].font

        theme.colors.body = Self.bodyInk
        theme.colors.selectionBackground = Self.selectionInk
        // Links are the text's own charcoal with a faint underline, not a saturated accent
        // blue; the underline the package draws under *emphasis* stays neutral and heavier, so
        // it does not read as a link.
        theme.colors.link = Self.linkInk
        theme.colors.linkUnderline = Self.linkUnderlineInk
        theme.colors.emphasis = .tertiaryLabelColor
        theme.colors.code = Self.codeInk
        theme.colors.codeBackground = Self.inlineCodeInk
        // Code blocks are quiet on the paper: no fill, edge or bar, only a faint rule down the
        // left; the language and the buttons appear while the pointer is over the block.
        theme.codeBlockStyle = .rule
        theme.showsCodeLineNumbers = false
        theme.colors.codeBlockRule = Self.codeBlockRuleInk
        theme.sizes.bullet = 5

        theme.table.cornerRadius = 8
        theme.table.borderWidth = 1
        theme.table.borderColor = Self.hairlineInk
        theme.table.headerBackgroundColor = Self.tableHeaderInk
        theme.table.stripeCellBackgroundColor = Self.tableStripeInk

        let rhythm = Rhythm.of(profile)
        theme.spacings.line = rhythm.lineSpacing(for: theme.fonts.body)
        theme.spacings.paragraph = (size * rhythm.paragraph).rounded()
        theme.spacings.list = (size * rhythm.list).rounded()
        theme.spacings.headingBefore = (size * rhythm.headingBefore).rounded()
        return theme
    }

    /// How loosely a profile is set, in multiples of the text size, so the spacing follows the
    /// font and its size instead of fixed points. CJK reads best with lines about 1.7 times the
    /// size apart; a typed bubble is a little tighter.
    struct Rhythm {
        /// The line height the leading makes up to.
        let lineHeight: CGFloat
        let paragraph: CGFloat
        let list: CGFloat
        let headingBefore: CGFloat

        static func of(_ profile: LimareMarkdownView.Profile) -> Rhythm {
            switch profile {
            case .chat: Rhythm(lineHeight: 1.70, paragraph: 0.9, list: 0.45, headingBefore: 1.3)
            case .document: Rhythm(lineHeight: 1.70, paragraph: 1.0, list: 0.45, headingBefore: 1.6)
            case .typed: Rhythm(lineHeight: 1.50, paragraph: 0.9, list: 0.45, headingBefore: 1.3)
            }
        }

        /// The leading that brings `font`'s own line height up to `lineHeight` times its size.
        func lineSpacing(for font: NSFont) -> CGFloat {
            max(0, (font.pointSize * lineHeight - Self.naturalLineHeight(of: font)).rounded())
        }

        static func naturalLineHeight(of font: NSFont) -> CGFloat {
            font.ascender + abs(font.descender) + font.leading
        }
    }

    // Made once. A colour that follows the appearance is equal only to itself: made afresh on
    // every update, the theme never matched the last one, and every message on screen rebuilt
    // its text whenever SwiftUI updated it (a Work Surface toggle, a window resize).
    /// Soft charcoal rather than pure black (and soft white in dark), easier on a long read.
    private static let bodyInk = AppColors.dynamicNSColor(light: 0x1F2024, dark: 0xECECEF)
    private static let codeInk = AppColors.dynamicNSColor(light: 0x27272A, dark: 0xE4E4E7)
    // Not `labelColor.withAlphaComponent(_:)`: kept in a constant, that colour stays in the
    // appearance it was made in, and links went black on a dark page.
    private static let linkInk = ink(light: 0.88, dark: 0.88)
    private static let linkUnderlineInk = ink(light: 0.28, dark: 0.28)
    private static let inlineCodeInk = ink(light: 0.04, dark: 0.07)
    /// Selected text is shaded in the text's own ink, not the accent blue.
    private static let selectionInk = ink(light: 0.12, dark: 0.12)
    private static let hairlineInk = ink(light: 0.08, dark: 0.08)
    /// Fainter than a quote's bar (18%), so a code block does not read as a quote.
    private static let codeBlockRuleInk = ink(light: 0.12, dark: 0.16)
    private static let tableHeaderInk = ink(light: 0.035, dark: 0.035)
    private static let tableStripeInk = ink(light: 0.015, dark: 0.015)

    /// The text colour at an alpha per appearance: black in light, white in dark.
    private static func ink(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LimareStreamView {
        let view = LimareStreamView()
        let theme = Self.makeTheme(
            conversationPointSize: conversationPointSize,
            codePointSize: codePointSize,
            profile: profile
        )
        view.theme = theme
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.onSelectionBecameActive = onSelectionBecameActive
        context.coordinator.openURL = openURL
        // Set once: the handler reads the coordinator, so updates never re-sync it into every
        // table and code block.
        view.linkHandler = { [weak coordinator = context.coordinator] payload, _, _ in
            let url: URL? = switch payload {
            case let .url(url): url
            case let .string(destination): MessageLinks.url(forDestination: destination)
            }
            guard let url else { return }
            coordinator?.openURL?(url)
        }

        context.coordinator.apply(
            source: source,
            profile: profile,
            theme: theme,
            to: view,
            isInitial: true
        )
        return view
    }

    func updateNSView(_ nsView: LimareStreamView, context: Context) {
        nsView.onSelectionBecameActive = onSelectionBecameActive
        context.coordinator.openURL = openURL
        let theme = Self.makeTheme(
            conversationPointSize: conversationPointSize,
            codePointSize: codePointSize,
            profile: profile
        )
        context.coordinator.apply(
            source: source,
            profile: profile,
            theme: theme,
            to: nsView,
            isInitial: false
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LimareStreamView, context: Context) -> CGSize? {
        context.coordinator.sizeThatFits(proposal, for: nsView, hugsText: profile == .typed)
    }

    @MainActor
    final class Coordinator {
        var openURL: OpenURLAction?
        var width: CGFloat = 0
        var lastSource: String = ""
        var lastParsedSource: String = ""
        var lastParseResult: MarkdownParser.ParseResult?
        var lastProfile: LimareMarkdownView.Profile?
        var lastTheme: MarkdownTheme = .default

        /// `hugsText` reports the width the wrapped text uses, at most the proposed one;
        /// otherwise the view takes the whole proposed width.
        func sizeThatFits(_ proposal: ProposedViewSize, for view: MarkdownTextView, hugsText: Bool) -> CGSize? {
            if proposal.width == 0 {
                return .zero
            }
            let fittingWidth: CGFloat
            if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
                fittingWidth = proposed
                width = proposed
            } else if width > 0 {
                fittingWidth = width
            } else if view.bounds.width > 0 {
                fittingWidth = view.bounds.width
            } else {
                return nil
            }
            let size = view.boundingSize(for: fittingWidth)
            // Measuring again at the hugged width wraps the same lines: the label rounds its
            // width up, never past the width it measured at.
            let width = hugsText ? min(fittingWidth, ceil(size.width)) : fittingWidth
            return CGSize(width: width, height: ceil(size.height))
        }

        func apply(
            source: String,
            profile: LimareMarkdownView.Profile,
            theme: MarkdownTheme,
            to view: LimareStreamView,
            isInitial: Bool
        ) {
            let (isStreaming, messageId) = switch profile {
            case let .chat(streaming, id): (streaming, Optional(id))
            case .document, .typed: (false, nil as String?)
            }

            view.streamIdentity = messageId
            view.isStreaming = isStreaming

            let parsedSource = isStreaming
                ? MarkdownParser.StreamingTail(closing: source).applied(to: source)
                : source

            if !isInitial,
               lastSource == source,
               lastProfile == profile,
               lastTheme == theme {
                return
            }

            let parseResult = (lastParsedSource == parsedSource && lastParseResult != nil)
                ? lastParseResult!
                : MarkdownParser().parse(parsedSource)

            let content = MarkdownContent(parserResult: parseResult, theme: theme)

            lastSource = source
            lastParsedSource = parsedSource
            lastParseResult = parseResult
            lastProfile = profile
            lastTheme = theme

            if isStreaming && !isInitial && view.isStreaming {
                view.setContent(content)
            } else {
                view.setContentImmediately(content, theme: theme)
            }
        }
    }
}

#else

// Track A: Bare swiftc fallback stub
/// Test builds only: the stub's text cannot report a selection, so a harness reports one through
/// the callback the real view calls when the reader selects text in a message.
@MainActor
enum LimareMarkdownSelectionProbe {
    static var callbacks: [String: @MainActor () -> Void] = [:]
}

public struct LimareMarkdownView: View {
    public enum Profile: Equatable, Sendable {
        case chat(isStreaming: Bool, messageId: String)
        case document
        /// Text a person typed: a single newline starts a new line, as it did in the composer.
        case typed
    }

    public let source: String
    public let profile: Profile
    public let onSelectionBecameActive: (@MainActor () -> Void)?

    public init(
        source: String,
        profile: Profile,
        onSelectionBecameActive: (@MainActor () -> Void)? = nil
    ) {
        self.source = source
        self.profile = profile
        self.onSelectionBecameActive = onSelectionBecameActive
    }

    public var body: some View {
        Text(source)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onAppear {
                if let onSelectionBecameActive { LimareMarkdownSelectionProbe.callbacks[source] = onSelectionBecameActive }
            }
    }
}

#endif
