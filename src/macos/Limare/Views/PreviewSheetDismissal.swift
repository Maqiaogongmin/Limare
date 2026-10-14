import SwiftUI
import AppKit

extension View {
    /// Closes the sheet this view is shown in when the window behind it is clicked, the way the
    /// code and table sheets in messages close. That click only closes the sheet; it does not
    /// also act on what is under it. Clicks in the title bar still move the window.
    func closesOnClickOutside(_ close: @escaping () -> Void) -> some View {
        background(OutsideClickCloser(close: close))
    }
}

private struct OutsideClickCloser: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> OutsideClickCloserView {
        let view = OutsideClickCloserView()
        view.close = close
        return view
    }

    func updateNSView(_ nsView: OutsideClickCloserView, context: Context) {
        nsView.close = close
    }
}

final class OutsideClickCloserView: NSView {
    var close: (() -> Void)?
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self,
                  let sheet = self.window,
                  let parent = sheet.sheetParent,
                  parent.attachedSheet === sheet,
                  event.window === parent,
                  parent.contentLayoutRect.contains(event.locationInWindow)
            else { return event }
            self.close?()
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
