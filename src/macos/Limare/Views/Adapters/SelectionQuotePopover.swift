import AppKit
import Litext

/// A short-lived native popover anchored to the selected reply, without replacing its text menu.
@MainActor
final class SelectionQuotePopover: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private let onQuote: (String) -> Void
    private weak var selectedLabel: TextLabelView?
    private var selectedText = ""
    private var refreshPending = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var scrollObserver: (any NSObjectProtocol)?

    init(onQuote: @escaping (String) -> Void) {
        self.onQuote = onQuote
        super.init()
        let button = NSButton(title: String(localized: "Quote"), target: self, action: #selector(quote))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("chat.selection.quote")
        button.sizeToFit()
        let size = NSSize(width: max(64, button.frame.width + 16), height: button.frame.height + 12)
        button.frame.origin = NSPoint(x: (size.width - button.frame.width) / 2, y: 6)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(button)
        let controller = NSViewController()
        controller.view = container
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        // Closing synchronously prevents an old close notification from cancelling a new drag.
        popover.animates = false
        popover.delegate = self
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    func selectionChanged(in label: TextLabelView) {
        selectedLabel = label
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshSelection()
        }
    }

    private func refreshSelection() {
        guard let label = selectedLabel, label.window != nil,
              let text = label.selectionGroup?.selectedPlainText() ?? label.selectedPlainText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dismiss()
            return
        }
        selectedText = text
        installEventMonitor()
        // Wait until the drag ends, so the button never covers the text being selected.
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            popover.close()
            return
        }
        let segments: [(label: TextLabelView, range: NSRange)]
        if let group = label.selectionGroup {
            segments = group.selectedSegments.map { (label: $0.label, range: $0.range) }
        } else if let range = label.selectionRange {
            segments = [(label: label, range: range)]
        } else {
            dismiss()
            return
        }
        // The end of a long selection may have scrolled away; anchor to its last visible line.
        var visibleAnchor: (TextLabelView, NSRect)?
        for segment in segments.reversed() {
            for rect in segment.label.textLayout.rects(for: segment.range).reversed() {
                let visible = segment.label.viewRect(fromLayoutRect: rect).intersection(segment.label.visibleRect)
                if !visible.isNull && !visible.isEmpty {
                    visibleAnchor = (segment.label, visible)
                    break
                }
            }
            if visibleAnchor != nil { break }
        }
        guard let (anchorLabel, anchor) = visibleAnchor else { dismiss(); return }
        popover.show(relativeTo: anchor, of: anchorLabel, preferredEdge: .maxY)
        observeScrolling(of: anchorLabel)
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseUp {
                self.scheduleRefresh()
            } else if event.window !== self.popover.contentViewController?.view.window {
                self.dismiss()
            }
            return event
        }
    }

    private func observeScrolling(of label: TextLabelView) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        guard let clip = label.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    @objc private func quote() {
        let text = selectedText
        dismiss()
        guard !text.isEmpty else { return }
        onQuote(text)
    }

    func popoverDidClose(_ notification: Notification) {
        stopObserving()
    }

    func dismiss() {
        selectedLabel = nil
        popover.close()
        stopObserving()
    }

    private func stopObserving() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
    }
}
