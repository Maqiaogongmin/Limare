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
/// gutter. Lines never wrap; the text scrolls both ways while the gutter stays put.
struct CodePreviewTextView: View {
    let code: String
    let language: String

    init(code: String, language: String) {
        self.code = code
        self.language = language
    }

    var body: some View {
        CodePreviewTextRepresentable(
            code: code,
            language: language,
            codePointSize: CGFloat(TypographyPreferences.shared.codeSize),
            conversationPointSize: CGFloat(TypographyPreferences.shared.conversationSize)
        )
    }
}

private struct CodePreviewTextRepresentable: NSViewRepresentable {
    let code: String
    let language: String
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
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
            return map.apply(to: code, with: theme)
        }
        #endif
        return NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
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
            let lineTop = frame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0)
            let pointInRuler = convert(NSPoint(x: 0, y: lineTop + origin.y), from: textView)
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - Metrics.horizontalPadding - size.width, y: pointInRuler.y), withAttributes: attributes)
            return true
        }
    }
}
