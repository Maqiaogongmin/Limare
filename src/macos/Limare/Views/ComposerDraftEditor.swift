import SwiftUI
import AppKit

/// A key the composer's open command menu may take before the editor does.
public enum ComposerMenuKey {
    case up, down, accept, complete, dismiss
}

public struct ComposerDraftEditor: View {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void
    var onFocusChange: ((Bool) -> Void)?
    var onFilesDropped: (([URL]) -> Void)? = nil
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// Offered navigation keys first; returns whether it used the key.
    var onMenuKey: ((ComposerMenuKey) -> Bool)? = nil
    /// A change makes the editor first responder (the Focus Composer command).
    var focusToken: Int = 0

    public init(
        text: Binding<String>,
        placeholder: String = "Message Limare… (Shift+Return for new line)",
        onSend: @escaping () -> Void,
        onFocusChange: ((Bool) -> Void)? = nil,
        onContentHeightChange: ((CGFloat) -> Void)? = nil,
        onFilesDropped: (([URL]) -> Void)? = nil,
        onMenuKey: ((ComposerMenuKey) -> Bool)? = nil,
        focusToken: Int = 0
    ) {
        self._text = text
        self.onMenuKey = onMenuKey
        self.focusToken = focusToken
        self.placeholder = placeholder
        self.onFilesDropped = onFilesDropped
        self.onSend = onSend
        self.onFocusChange = onFocusChange
        self.onContentHeightChange = onContentHeightChange
    }

    public var body: some View {
        NativeDraftTextViewRepresentable(
            text: $text,
            placeholder: placeholder,
            font: AppTypography.chatNSFont,
            onFilesDropped: onFilesDropped,
            onSend: onSend,
            onFocusChange: { isFocused in
                onFocusChange?(isFocused)
            },
            onContentHeightChange: onContentHeightChange,
            onMenuKey: onMenuKey,
            focusToken: focusToken
        )
    }
}

// MARK: - AppKit Representable

@MainActor
private struct NativeDraftTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let onFilesDropped: (([URL]) -> Void)?
    let onSend: () -> Void
    let onFocusChange: (Bool) -> Void
    let onContentHeightChange: ((CGFloat) -> Void)?
    let onMenuKey: ((ComposerMenuKey) -> Bool)?
    let focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .automatic

        scrollView.postsFrameChangedNotifications = true

        let contentSize = scrollView.contentSize
        // TextKit 2, the platform's text system. AppKit's click-to-place selection is built on
        // it; under TextKit 1 a click on the empty last line put the caret back on the line above.
        // Nothing here may touch `layoutManager`, which would switch the view back to TextKit 1.
        let textView = NativeAppKitDraftTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onFilesDropped = onFilesDropped
        textView.onSend = onSend
        textView.onFocusChange = onFocusChange
        textView.onMenuKey = onMenuKey
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = NSColor.labelColor
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.lastFocusToken = focusToken
        context.coordinator.setupScrollViewObserver(scrollView)

        DispatchQueue.main.async {
            context.coordinator.measureAndReportHeight()
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NativeAppKitDraftTextView else { return }
        context.coordinator.parent = self
        textView.onFilesDropped = onFilesDropped
        textView.onSend = onSend
        textView.onFocusChange = onFocusChange
        textView.onMenuKey = onMenuKey
        textView.placeholder = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            // A composer that just appeared is not in its window until this update ends.
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }

        // The height is reported through a callback that sets SwiftUI state, which must not
        // happen during this update: report it on the next main-loop turn.
        var heightMayHaveChanged = false
        if textView.font != font {
            textView.font = font
            heightMayHaveChanged = true
        }

        // Marked text belongs to the input method until it is committed. A
        // SwiftUI update must not replace it with the still-empty draft binding.
        if !textView.hasMarkedText(), textView.string != text {
            let selectedRanges = textView.selectedRanges.map(\.rangeValue)
            let caretWasAtEnd = selectedRanges.count == 1
                && selectedRanges[0].length == 0
                && selectedRanges[0].location == (textView.string as NSString).length
            textView.string = text
            textView.needsDisplay = true
            // A caret at the end stays at the end (a completed command); any other selection
            // keeps its place, within the new text.
            let length = (text as NSString).length
            if caretWasAtEnd {
                textView.setSelectedRange(NSRange(location: length, length: 0))
            } else if !selectedRanges.isEmpty {
                textView.selectedRanges = selectedRanges.map { range in
                    let location = min(range.location, length)
                    return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
                }
            }
            heightMayHaveChanged = true
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        if heightMayHaveChanged {
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.measureAndReportHeight() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeDraftTextViewRepresentable
        weak var textView: NativeAppKitDraftTextView?
        weak var scrollView: NSScrollView?
        var lastFocusToken = 0
        nonisolated(unsafe) private var frameObserver: (any NSObjectProtocol)?

        init(_ parent: NativeDraftTextViewRepresentable) {
            self.parent = parent
            super.init()
        }

        func setupScrollViewObserver(_ sv: NSScrollView) {
            if let obs = frameObserver {
                NotificationCenter.default.removeObserver(obs)
            }
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: sv,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.measureAndReportHeight()
                }
            }
        }

        deinit {
            if let obs = frameObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            textView.needsDisplay = true
            if parent.text != textView.string {
                parent.text = textView.string
            }
            measureAndReportHeight()
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func measureAndReportHeight() {
            guard let textView,
                  let textLayoutManager = textView.textLayoutManager,
                  let textContainer = textView.textContainer else { return }

            let viewportWidth = scrollView?.contentSize.width ?? textView.frame.width

            // 1. Guard empty text: Immediately snap to composerDraftMinimumHeight (32pt)
            if textView.string.isEmpty {
                let minHeight = AppLayout.composerDraftMinimumHeight
                if viewportWidth > 0 {
                    textView.setFrameSize(NSSize(width: viewportWidth, height: minHeight))
                }
                if let sv = scrollView {
                    sv.contentView.scroll(to: .zero)
                    sv.reflectScrolledClipView(sv.contentView)
                }
                parent.onContentHeightChange?(minHeight)
                return
            }

            // 2. Synchronize container and textview width to current viewport BEFORE layout pass
            if viewportWidth > 0 {
                let insetW = textView.textContainerInset.width * 2
                let effectiveWidth = max(1, viewportWidth - insetW)
                if abs(textContainer.containerSize.width - effectiveWidth) > 0.5 {
                    textContainer.containerSize = NSSize(width: effectiveWidth, height: CGFloat.greatestFiniteMagnitude)
                }
                if abs(textView.frame.width - viewportWidth) > 0.5 {
                    textView.setFrameSize(NSSize(width: viewportWidth, height: textView.frame.height))
                }
            }

            // 3. Ensure layout with accurate container width
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
            let usedHeight = textLayoutManager.usageBoundsForTextContainer.height
            let calculated = max(AppLayout.composerDraftMinimumHeight, ceil(usedHeight + textView.textContainerInset.height * 2))

            // 4. Update document frame size and prevent stranded scroll offsets
            if viewportWidth > 0 {
                let targetHeight = max(calculated, scrollView?.contentSize.height ?? calculated)
                if abs(textView.frame.height - targetHeight) > 0.5 || abs(textView.frame.width - viewportWidth) > 0.5 {
                    textView.setFrameSize(NSSize(width: viewportWidth, height: targetHeight))
                }
                if let sv = scrollView, calculated <= sv.contentSize.height {
                    sv.contentView.scroll(to: .zero)
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }

            parent.onContentHeightChange?(calculated)
        }
    }
}

// MARK: - AppKit TextView Subclass

final class NativeAppKitDraftTextView: NSTextView {
    var onFilesDropped: (([URL]) -> Void)?

    private func droppedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if receiveFileDrop(sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Single native file-drop ingress; ordinary text drops continue through NSTextView.
    func receiveFileDrop(_ pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty, let onFilesDropped else { return false }
        onFilesDropped(urls)
        return true
    }

    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onMenuKey: ((ComposerMenuKey) -> Bool)?
    var placeholder = "" {
        didSet {
            if placeholder != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }

        let placeholderFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6),
            .paragraphStyle: paragraphStyle
        ]
        let horizontalInset = textContainerInset.width
        let lineHeight = ceil(placeholderFont.ascender - placeholderFont.descender + placeholderFont.leading) + 2
        let placeholderRect = NSRect(
            x: horizontalInset,
            y: textContainerInset.height,
            width: max(0, bounds.width - horizontalInset * 2),
            height: lineHeight
        )
        (placeholder as NSString).draw(in: placeholderRect, withAttributes: attributes)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    /// Up and Down move through the menu, Return runs its command, Tab completes it, Escape
    /// closes it. Keys with ⌘, ⌥ or ⌃ stay with the editor, as does Shift-Return (a new line).
    private static func menuKey(for event: NSEvent) -> ComposerMenuKey? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .accept
        case 48: return .complete
        case 53: return .dismiss
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        let isCommand = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)

        // An open command menu takes its keys first; the input method keeps its own.
        if !hasMarkedText(), let onMenuKey, let key = Self.menuKey(for: event), onMenuKey(key) {
            return
        }

        // Let Tab leave the editor; keep IME candidate navigation with AppKit.
        if event.keyCode == 48 && !hasMarkedText() && !isCommand &&
            !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control) {
            if isShift {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }

        // ⌘Return -> Send always
        if isCommand && (event.keyCode == 36 || event.charactersIgnoringModifiers == "\r") {
            onSend?()
            return
        }

        // Return key (keyCode 36)
        if event.keyCode == 36 {
            // If IME candidate selection is active (e.g. Chinese/Japanese composition),
            // pass event to system so Return confirms the candidate text without sending.
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }

            if isShift {
                // Shift+Return -> insert newline
                insertNewlineIgnoringFieldEditor(nil)
                return
            } else {
                // Return -> Send
                onSend?()
                return
            }
        }

        super.keyDown(with: event)
    }
}
