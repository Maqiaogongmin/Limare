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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
    static func makeTheme(
        conversationPointSize: CGFloat,
        codePointSize: CGFloat,
        profile: LimareMarkdownView.Profile = .document
    ) -> MarkdownTheme {
        var theme = MarkdownTheme.default
        theme.softBreaksAreLineBreaks = profile == .typed
        theme.align(to: conversationPointSize)
        theme.fonts.code = theme.fonts.code.withSize(codePointSize)
        theme.colors.selectionBackground = NSColor.controlAccentColor.withAlphaComponent(0.14)
        return theme
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
        context.coordinator.sizeThatFits(proposal, for: nsView)
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

        func sizeThatFits(_ proposal: ProposedViewSize, for view: MarkdownTextView) -> CGSize? {
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
            return CGSize(width: fittingWidth, height: ceil(size.height))
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
    }
}

#endif
