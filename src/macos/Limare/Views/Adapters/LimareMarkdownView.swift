import SwiftUI
import AppKit

#if canImport(MarkdownView)
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
    public let onQuote: (@MainActor (String) -> Void)?

    public init(
        source: String,
        profile: Profile,
        onSelectionBecameActive: (@MainActor () -> Void)? = nil,
        onQuote: (@MainActor (String) -> Void)? = nil
    ) {
        self.source = source
        self.profile = profile
        self.onSelectionBecameActive = onSelectionBecameActive
        self.onQuote = onQuote
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
            onQuote: onQuote,
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
    var onQuote: (@MainActor (String) -> Void)? {
        didSet {
            if onQuote == nil {
                quotePopover?.dismiss()
                quotePopover = nil
            }
        }
    }
    private(set) var quotePopover: SelectionQuotePopover?
    var openFileLink: ((URL) -> Void)?
    private var pendingFileOpen: DispatchWorkItem?

    override func textLabelView(_ label: TextLabelView, didChangeSelection selection: NSRange?) {
        super.textLabelView(label, didChangeSelection: selection)
        if let selection, selection.length > 0 {
            onSelectionBecameActive?()
        }
        guard onQuote != nil else { return }
        if quotePopover == nil, let selection, selection.length > 0 {
            quotePopover = SelectionQuotePopover { [weak self] text in self?.onQuote?(text) }
        }
        // A right click (or Control-click) may select a word before opening the native menu.
        // Do not put a popover over that menu.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            quotePopover?.dismiss()
        } else {
            quotePopover?.selectionChanged(in: label)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { quotePopover?.dismiss() }
    }

    override func textLabelView(_ label: TextLabelView, didTapHighlightRegion region: TextLabel.HighlightRegion, at location: CGPoint) {
        let value = region.attributes[.link]
        let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
        guard let url, url.isFileURL else {
            super.textLabelView(label, didTapHighlightRegion: region, at: location)
            return
        }
        pendingFileOpen?.cancel()
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
            filePathMenu(for: url).popUp(positioning: nil, at: location, in: label)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.openFileLink?(url) }
            pendingFileOpen = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    func filePathMenu(for url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let exists = FileManager.default.fileExists(atPath: url.path)
        let open = NSMenuItem(title: String(localized: "Open File"), action: #selector(openPath(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = url
        open.isEnabled = exists
        menu.addItem(open)
        let reveal = NSMenuItem(title: String(localized: "Reveal in Finder"), action: #selector(revealPath(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = url
        reveal.isEnabled = exists
        menu.addItem(reveal)
        let copy = NSMenuItem(title: String(localized: "Copy Path"), action: #selector(copyPath(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = url
        menu.addItem(copy)
        if !exists {
            menu.addItem(.separator())
            let missing = NSMenuItem(title: String(localized: "File not found"), action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        return menu
    }

    @objc private func openPath(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { openFileLink?(url) }
    }

    @objc private func revealPath(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func copyPath(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// Add links to complete local paths in chat without changing Markdown source or code blocks.
enum ChatFilePaths {
    static func url(_ value: String) -> URL? {
        guard !value.isEmpty, value.count <= 4096, !value.hasPrefix("//"),
              !value.contains("\n"), !value.contains("\r"),
              value.hasPrefix("/") || value.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    static func inline(_ nodes: [MarkdownInlineNode]) -> [MarkdownInlineNode] {
        nodes.map { node in
            switch node {
            case .code(let value), .text(let value):
                guard let url = url(value) else { return node }
                return .link(destination: url.absoluteString, children: [node])
            case .emphasis(let children): return .emphasis(children: inline(children))
            case .strong(let children): return .strong(children: inline(children))
            case .strikethrough(let children): return .strikethrough(children: inline(children))
            default: return node // Explicit links and images keep their original destination.
            }
        }
    }

    static func blocks(_ nodes: [MarkdownBlockNode]) -> [MarkdownBlockNode] {
        nodes.map { node in
            switch node {
            case .paragraph(let content): return .paragraph(content: inline(content))
            case .heading(let level, let content): return .heading(level: level, content: inline(content))
            case .blockquote(let children): return .blockquote(children: blocks(children))
            case .bulletedList(let tight, let items):
                return .bulletedList(isTight: tight, items: items.map { RawListItem(children: blocks($0.children)) })
            case .numberedList(let tight, let start, let items):
                return .numberedList(isTight: tight, start: start, items: items.map { RawListItem(children: blocks($0.children)) })
            case .taskList(let tight, let items):
                return .taskList(isTight: tight, items: items.map { RawTaskListItem(isCompleted: $0.isCompleted, children: blocks($0.children)) })
            case .table(let alignments, let rows):
                return .table(columnAlignments: alignments, rows: rows.map { row in
                    RawTableRow(cells: row.cells.map { RawTableCell(content: inline($0.content)) })
                })
            default: return node
            }
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
    let onQuote: (@MainActor (String) -> Void)?
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
        view.onQuote = onQuote
        context.coordinator.openURL = openURL
        view.openFileLink = { [weak coordinator = context.coordinator] url in coordinator?.openURL?(url) }
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
        nsView.onQuote = onQuote
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
            guard hugsText else {
                return CGSize(width: fittingWidth, height: ceil(size.height))
            }
            let huggedWidth = min(fittingWidth, ceil(size.width))
            // Re-measuring at `huggedWidth` keeps wrapped line count accurate and aligns Litext's
            // measurement fill width with the eventual bounds width so `layout()` reuses it.
            guard huggedWidth > 0, huggedWidth < fittingWidth else {
                return CGSize(width: huggedWidth, height: ceil(size.height))
            }
            let huggedSize = view.boundingSize(for: huggedWidth)
            return CGSize(width: huggedWidth, height: ceil(huggedSize.height))
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
            if case .chat = profile {
                view.recognizesStandaloneFilePaths = true
            } else {
                view.recognizesStandaloneFilePaths = false
            }

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

            let parsedContent = MarkdownContent(parserResult: parseResult, theme: theme)
            let content: MarkdownContent
            if case .chat = profile {
                content = MarkdownContent(blocks: ChatFilePaths.blocks(parsedContent.blocks),
                                          rendered: parsedContent.rendered, highlightMaps: parsedContent.highlightMaps,
                                          locale: parsedContent.locale)
            } else {
                content = parsedContent
            }

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
    public let onQuote: (@MainActor (String) -> Void)?

    public init(
        source: String,
        profile: Profile,
        onSelectionBecameActive: (@MainActor () -> Void)? = nil,
        onQuote: (@MainActor (String) -> Void)? = nil
    ) {
        self.source = source
        self.profile = profile
        self.onSelectionBecameActive = onSelectionBecameActive
        self.onQuote = onQuote
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

/// Hit-testing and selection queries used by collapsible user bubbles to tell a plain click on
/// a bubble or blank transcript area apart from selection drags, links, buttons, and editors.
@MainActor
enum LimareMarkdownInteractionProbe {
    private static let interactiveRoles: Set<NSAccessibility.Role> = [
        .button, .menuButton, .popUpButton, .checkBox, .radioButton,
        .slider, .incrementor, .link, .textField, .textArea,
        .disclosureTriangle, .tabGroup, .menuItem, .row, .cell,
    ]

    /// Whether any selectable text view intersecting `windowRect` currently holds a non-empty selection.
    static func hasSelection(withinWindowRect windowRect: CGRect, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        if let textView = window.firstResponder as? NSTextView,
           textView.selectedRange().length > 0,
           textView.convert(textView.bounds, to: nil).intersects(windowRect) {
            return true
        }
        #if canImport(MarkdownView)
        return hasSelectableLabelSelection(in: contentView, intersecting: windowRect)
        #else
        return false
        #endif
    }

    /// Whether the selectable view directly under `windowPoint` currently holds a non-empty selection.
    static func hasSelection(at windowPoint: CGPoint, in window: NSWindow) -> Bool {
        guard let (contentView, hitView) = hitTestContentView(at: windowPoint, in: window) else { return false }
        var current: NSView? = hitView
        while let node = current {
            if let textView = node as? NSTextView, textView.selectedRange().length > 0 {
                return true
            }
            if node === contentView { break }
            current = node.superview
        }
        #if canImport(MarkdownView)
        if let label = enclosingTextLabel(of: hitView, root: contentView) {
            return (label.selectionRange?.length ?? 0) > 0
        }
        #endif
        return false
    }

    /// Whether a click at `windowPoint` hit an interactive UI element, link, or (when `rejectTextContent`
    /// is true) non-blank message content such as text lines, code blocks, or tables.
    static func isInteractiveOrContentHit(
        at windowPoint: CGPoint,
        in window: NSWindow,
        rejectTextContent: Bool
    ) -> Bool {
        guard let (contentView, hitView) = hitTestContentView(at: windowPoint, in: window) else { return false }

        if isControlOrEditableText(hitView, root: contentView, rejectContextCards: rejectTextContent) {
            return true
        }

        #if canImport(MarkdownView)
        if let label = enclosingTextLabel(of: hitView, root: contentView) {
            let labelPoint = label.convert(windowPoint, from: nil)
            if label.highlightRegion(at: labelPoint) != nil {
                return true
            }
            if rejectTextContent {
                if (label.selectionRange?.length ?? 0) > 0 {
                    return true
                }
                if label.layoutLines.contains(where: {
                    label.viewRect(fromLayoutRect: $0.rect).insetBy(dx: -4, dy: -6).contains(labelPoint)
                }) {
                    return true
                }
            }
        }
        #endif

        return hasInteractiveAccessibilityElement(at: window.convertPoint(toScreen: windowPoint), in: window)
    }

    private static func hitTestContentView(at windowPoint: CGPoint, in window: NSWindow) -> (contentView: NSView, hitView: NSView)? {
        guard let contentView = window.contentView else { return nil }
        // `NSView.hitTest(_:)` takes a point in the receiver's superview coordinate space.
        let superviewPoint = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let hitView = contentView.hitTest(superviewPoint) else { return nil }
        return (contentView, hitView)
    }

    private static func isControlOrEditableText(_ view: NSView, root: NSView, rejectContextCards: Bool) -> Bool {
        var current: NSView? = view
        while let node = current {
            if node is NSControl {
                return true
            }
            if let textView = node as? NSTextView, textView.isEditable {
                return true
            }
            #if canImport(MarkdownView)
            if rejectContextCards,
               let markdownView = node as? MarkdownTextView,
               view !== markdownView,
               !view.isDescendant(of: markdownView.textLabelView) {
                return true
            }
            #endif
            if node === root { break }
            current = node.superview
        }
        return false
    }

    private static func hasInteractiveAccessibilityElement(at screenPoint: CGPoint, in window: NSWindow) -> Bool {
        var current: Any? = window.accessibilityHitTest(screenPoint)
        for _ in 0..<8 {
            guard let element = current as? NSAccessibilityProtocol else { break }
            if let role = element.accessibilityRole(), interactiveRoles.contains(role) {
                return true
            }
            current = element.accessibilityParent()
        }
        return false
    }

    #if canImport(MarkdownView)
    private static func hasSelectableLabelSelection(in view: NSView, intersecting windowRect: CGRect) -> Bool {
        if let label = view as? TextLabelView,
           (label.selectionRange?.length ?? 0) > 0,
           label.convert(label.bounds, to: nil).intersects(windowRect) {
            return true
        }
        return view.subviews.contains { hasSelectableLabelSelection(in: $0, intersecting: windowRect) }
    }

    private static func enclosingTextLabel(of view: NSView, root: NSView) -> TextLabelView? {
        var current: NSView? = view
        while let node = current {
            if let label = node as? TextLabelView {
                return label
            }
            if node === root { break }
            current = node.superview
        }
        return nil
    }
    #endif
}
