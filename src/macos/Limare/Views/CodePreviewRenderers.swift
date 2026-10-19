import SwiftUI
import AppKit
#if canImport(MarkdownView)
import MarkdownView
#endif

/// Highlighting runs synchronously on the main thread when the shared cache misses, so files
/// past these sizes are shown as plain text with line numbers instead of stalling the window.
enum CodePreviewHighlightPolicy {
    static let maximumBytes = 256 * 1024
    static let maximumLines = 10_000

    static func shouldHighlight(byteCount: Int, lineCount: Int) -> Bool {
        byteCount <= maximumBytes && lineCount <= maximumLines
    }
}

/// UTF-16 offsets where each line starts; the line of an offset is found by binary search.
struct CodeLineIndex: Equatable {
    let lineStarts: [Int]

    init(_ text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    /// Zero-based line containing `offset`.
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

/// Read-only code with syntax highlighting (when the file is small enough) and a line-number
/// gutter. Code lines never wrap and the text scrolls both ways while the gutter stays put;
/// prose sources (Markdown) wrap to the width, numbered by their source lines.
struct CodePreviewTextView: View {
    let code: String
    let language: String
    let wrapsLines: Bool

    init(code: String, language: String, wrapsLines: Bool = false) {
        self.code = code
        self.language = language
        self.wrapsLines = wrapsLines
    }

    var body: some View {
        CodePreviewTextRepresentable(
            code: code,
            language: language,
            wrapsLines: wrapsLines,
            codePointSize: CGFloat(TypographyPreferences.shared.codeSize),
            conversationPointSize: CGFloat(TypographyPreferences.shared.conversationSize)
        )
    }
}

private struct CodePreviewTextRepresentable: NSViewRepresentable {
    let code: String
    let language: String
    let wrapsLines: Bool
    let codePointSize: CGFloat
    let conversationPointSize: CGFloat

    final class Coordinator {
        var renderedCode: String?
        var renderedLanguage: String?
        var renderedPointSize: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = !wrapsLines
        textView.isVerticallyResizable = true
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? scrollView.contentSize.width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 0, height: AppSpacing.small)

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        apply(to: textView, ruler: ruler, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let ruler = scrollView.verticalRulerView as? LineNumberRulerView else { return }
        apply(to: textView, ruler: ruler, coordinator: context.coordinator)
    }

    private func apply(to textView: NSTextView, ruler: LineNumberRulerView, coordinator: Coordinator) {
        guard coordinator.renderedCode != code
            || coordinator.renderedLanguage != language
            || coordinator.renderedPointSize != codePointSize else { return }
        coordinator.renderedCode = code
        coordinator.renderedLanguage = language
        coordinator.renderedPointSize = codePointSize

        let font = NSFont.monospacedSystemFont(ofSize: codePointSize, weight: .regular)
        let index = CodeLineIndex(code)
        textView.textStorage?.setAttributedString(
            Self.attributedCode(code, language: language, font: font, lineCount: index.lineCount,
                                codePointSize: codePointSize, conversationPointSize: conversationPointSize)
        )
        textView.sizeToFit()
        ruler.update(index: index, font: font)
    }

    @MainActor
    static func attributedCode(
        _ code: String, language: String, font: NSFont, lineCount: Int,
        codePointSize: CGFloat, conversationPointSize: CGFloat
    ) -> NSAttributedString {
        #if canImport(MarkdownView)
        if CodePreviewHighlightPolicy.shouldHighlight(byteCount: code.utf8.count, lineCount: lineCount) {
            let theme = LimareMarkdownRepresentable.makeTheme(
                conversationPointSize: conversationPointSize,
                codePointSize: codePointSize,
                profile: .document
            )
            let map = CodeHighlighter.current.highlight(key: nil, content: code, language: language, theme: theme)
            return Self.fillingMissingFont(map.apply(to: code, with: theme), with: font)
        }
        #endif
        return NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    /// Runs the highlighter left without a font (blank lines among them) take the code font, so
    /// every line, empty or not, is as tall as the others and its number lines up.
    static func fillingMissingFont(_ text: NSAttributedString, with font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value == nil { result.addAttribute(.font, value: font, range: range) }
        }
        return result
    }
}

/// Draws the line numbers of the visible lines beside a TextKit 2 text view.
final class LineNumberRulerView: NSRulerView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 8
        static let minimumDigits = 2
    }

    private weak var textView: NSTextView?
    private var index = CodeLineIndex("")
    private var font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    private var observesScrolling = false

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard !observesScrolling, let clipView = scrollView?.contentView else { return }
        observesScrolling = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: clipView
        )
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    func update(index: CodeLineIndex, font: NSFont) {
        self.index = index
        self.font = font
        let digits = max(Metrics.minimumDigits, String(index.lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        ruleThickness = ceil(CGFloat(digits) * digitWidth + Metrics.horizontalPadding * 2)
        needsDisplay = true
    }

    /// The ruler paints itself, inside its own bounds: the stock drawing filled the dirty rect,
    /// which since macOS 14 may reach past the view, so its divider ran up through the header
    /// rows above the code, and its translucent fill let code scrolled sideways show through.
    /// It fills with the Work Surface sheet's colour, which the code lies on.
    override func draw(_ dirtyRect: NSRect) {
        AppColors.workSurfaceNSColor.setFill()
        bounds.fill()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - hairline, y: bounds.minY, width: hairline, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let start = layoutManager.textViewportLayoutController.viewportRange?.location ?? layoutManager.documentRange.location

        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            guard frame.maxY + origin.y >= visible.minY else { return true }
            let offset = contentManager.offset(from: layoutManager.documentRange.location, to: fragment.rangeInElement.location)
            let label = String(index.line(containing: offset) + 1) as NSString
            // Each number sits on its line's baseline: an empty line's typographic bounds start
            // higher than a filled one's, so aligning tops drew blank lines' numbers too high.
            let line = fragment.textLineFragments.first
            let baseline = frame.minY + (line?.typographicBounds.minY ?? 0) + (line?.glyphOrigin.y ?? font.ascender)
            let pointInRuler = convert(NSPoint(x: 0, y: baseline - font.ascender + origin.y), from: textView)
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - Metrics.horizontalPadding - size.width, y: pointInRuler.y), withAttributes: attributes)
            return true
        }
    }
}
