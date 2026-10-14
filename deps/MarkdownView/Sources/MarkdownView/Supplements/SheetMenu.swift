//
//  SheetMenu.swift
//  MarkdownView
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// What the menu at the top trailing corner of a code or table sheet does.
///
/// The block in the document keeps only Copy and Expand; saving a file and
/// closing the sheet happen from here.
struct SheetMenuActions {
    let copy: () -> Void
    let download: () -> Void
    let close: () -> Void
}

enum SheetMenuText {
    static var more: String {
        String(localized: "More", bundle: .module, comment: "Button that opens a sheet's menu of actions.")
    }

    static var close: String {
        String(localized: "Close", bundle: .module, comment: "Menu item that closes a code or table sheet.")
    }
}

enum SheetMenuSymbol {
    static let menu = "ellipsis"
    static let close = "chevron.down"
    /// The close button at the trailing end of a macOS sheet's bar.
    static let dismiss = "xmark"
}

#if canImport(UIKit)
    extension UIBarButtonItem {
        /// A bar button that opens Copy, Download and Close.
        @MainActor
        static func sheetMenu(_ actions: SheetMenuActions) -> UIBarButtonItem {
            let menu = UIMenu(children: [
                UIAction(title: TableTitleText.copy, image: UIImage(systemName: TableSymbol.copy)) { _ in
                    actions.copy()
                },
                UIAction(title: TableTitleText.download, image: UIImage(systemName: TableSymbol.download)) { _ in
                    actions.download()
                },
                UIAction(title: SheetMenuText.close, image: UIImage(systemName: SheetMenuSymbol.close)) { _ in
                    actions.close()
                },
            ])
            let item = UIBarButtonItem(image: UIImage(systemName: SheetMenuSymbol.menu), menu: menu)
            item.accessibilityLabel = SheetMenuText.more
            return item
        }
    }

#elseif canImport(AppKit)
    /// The name at the leading end of a sheet's bar, opposite its menu; a
    /// sheet draws no window title.
    final class SheetTitleLabel: NSTextField {
        convenience init(_ title: String) {
            self.init(labelWithString: title)
            font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            textColor = .labelColor
            lineBreakMode = .byTruncatingTail
            sizeToFit()
        }

        /// Places the label in a bar of `barHeight` along the top of
        /// `bounds`, from `margin` to just short of `trailing`.
        func place(in bounds: CGRect, barHeight: CGFloat, margin: CGFloat, trailing: CGFloat) {
            let height = intrinsicContentSize.height
            frame = CGRect(
                x: margin,
                y: bounds.height - barHeight + (barHeight - height) / 2,
                width: max(0, trailing - margin * 2),
                height: height,
            )
        }
    }

    /// A borderless button that opens Copy, Download and Close below itself.
    final class SheetMenuButton: NSButton {
        private let actions: SheetMenuActions

        init(actions: SheetMenuActions) {
            self.actions = actions
            super.init(frame: .zero)
            image = NSImage(systemSymbolName: SheetMenuSymbol.menu, accessibilityDescription: SheetMenuText.more)
            imagePosition = .imageOnly
            isBordered = false
            contentTintColor = .labelColor
            toolTip = SheetMenuText.more
            target = self
            action = #selector(showMenu(_:))
            sizeToFit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func showMenu(_: Any?) {
            let menu = NSMenu()
            menu.addItem(item(TableTitleText.copy, symbol: TableSymbol.copy, action: #selector(copyItem(_:))))
            menu.addItem(item(TableTitleText.download, symbol: TableSymbol.download, action: #selector(downloadItem(_:))))
            menu.addItem(.separator())
            menu.addItem(item(SheetMenuText.close, symbol: SheetMenuSymbol.close, action: #selector(closeItem(_:))))
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height + 4), in: self)
        }

        private func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }

        @objc private func copyItem(_: Any?) {
            actions.copy()
        }

        @objc private func downloadItem(_: Any?) {
            actions.download()
        }

        @objc private func closeItem(_: Any?) {
            actions.close()
        }
    }

    /// A borderless ✕ at the trailing end of a sheet's bar that closes the
    /// sheet, so closing never goes through the menu.
    final class SheetCloseButton: NSButton {
        private let onClose: () -> Void

        init(close: @escaping () -> Void) {
            onClose = close
            super.init(frame: .zero)
            image = NSImage(systemSymbolName: SheetMenuSymbol.dismiss, accessibilityDescription: SheetMenuText.close)
            imagePosition = .imageOnly
            isBordered = false
            contentTintColor = .labelColor
            toolTip = SheetMenuText.close
            target = self
            action = #selector(closeSheet(_:))
            sizeToFit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func closeSheet(_: Any?) {
            onClose()
        }
    }

    /// The trailing controls of a sheet's bar: the menu, then the close
    /// button at the very end.
    enum SheetBar {
        static let spacing: CGFloat = 12

        /// Places `menu` and `close` right to left in a bar of `barHeight`
        /// along the top of `bounds`, and returns where the title must stop.
        @discardableResult
        static func placeTrailingControls(
            menu: NSView,
            close: NSView,
            in bounds: CGRect,
            barHeight: CGFloat,
            margin: CGFloat,
        ) -> CGFloat {
            let barMinY = bounds.height - barHeight
            close.frame.origin = CGPoint(
                x: bounds.width - margin - close.frame.width,
                y: barMinY + (barHeight - close.frame.height) / 2,
            )
            menu.frame.origin = CGPoint(
                x: close.frame.minX - spacing - menu.frame.width,
                y: barMinY + (barHeight - menu.frame.height) / 2,
            )
            return menu.frame.minX
        }
    }

    /// Shows code and table sheets the way a preview behaves: besides the
    /// close button and Esc, a click on the window behind the sheet closes
    /// it. That click only closes; it does not also act on what is under it.
    @MainActor
    enum SheetPresenter {
        static func present(_ sheet: NSWindow, on window: NSWindow) {
            let monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            ) { [weak sheet, weak window] event in
                guard let sheet, let window,
                      window.attachedSheet === sheet,
                      event.window === window,
                      // The title bar still moves the window and keeps its buttons.
                      window.contentLayoutRect.contains(event.locationInWindow)
                else { return event }
                window.endSheet(sheet)
                return nil
            }
            window.beginSheet(sheet) { _ in
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
        }
    }
#endif
