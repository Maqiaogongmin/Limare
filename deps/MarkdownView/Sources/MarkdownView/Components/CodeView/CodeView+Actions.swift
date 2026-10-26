//
//  CodeView+Actions.swift
//  MarkdownView
//

import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if canImport(UIKit)
    typealias PlatformButton = UIButton
#elseif canImport(AppKit)
    typealias PlatformButton = NSButton
#endif

extension CodeView {
    /// How long Copy shows a checkmark after it is tapped.
    static let copyFeedbackDuration: TimeInterval = 1.5

    static let copySymbol = TableSymbol.copy
    static let copiedSymbol = TableSymbol.copied
    static let expandSymbol = TableSymbol.expand

    #if canImport(AppKit)
        /// The bar's buttons are bare glyphs a step quieter than the code.
        static let barButtonTint = NSColor.secondaryLabelColor

        static func barSymbol(_ name: String, accessibilityDescription: String?) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
    #endif

    /// The bar's buttons from the trailing edge: Expand, Copy, Preview, then
    /// the host's actions — Copy, Expand reading left to right. Download is
    /// in the sheet Expand opens.
    var barButtons: [PlatformButton] {
        [expandButton, copyButton, previewButton] + actionButtons.reversed()
    }

    /// Swaps Copy for a checkmark, and back after `copyFeedbackDuration`;
    /// another tap restarts the wait.
    func showCopyFeedback() {
        setCopySymbol(Self.copiedSymbol)
        isShowingCopyFeedback = true
        schedule(#selector(resetCopyFeedback), after: Self.copyFeedbackDuration)
    }

    /// Puts Copy back and drops a pending reset, so a view reused for
    /// another block does not show — or later flip — the last one's state.
    @objc func resetCopyFeedback() {
        cancelScheduled(#selector(resetCopyFeedback))
        setCopySymbol(Self.copySymbol)
        // The controls stayed up for the checkmark; now they follow the pointer again.
        if isShowingCopyFeedback {
            isShowingCopyFeedback = false
            updateControlsVisibility(animated: true)
        }
    }

    /// Asks the provider for this block's buttons and rebuilds them.
    func reloadActions() {
        actions = actionProvider?.codeBlockActions(forLanguage: language.isEmpty ? nil : language) ?? []
        for button in actionButtons {
            button.removeFromSuperview()
        }
        actionButtons = actions.indices.map { makeActionButton(for: actions[$0], tag: $0) }
        for button in actionButtons {
            barView.addSubview(button)
        }
        markNeedsLayout()
    }

    @objc func handleAction(_ sender: Any?) {
        guard let tag = (sender as? PlatformView)?.tag else { return }
        guard actions.indices.contains(tag) else { return }
        actions[tag].handler(CodeBlock(language: language.isEmpty ? nil : language, content: content))
    }

    #if canImport(UIKit)
        private func setCopySymbol(_ name: String) {
            let image = UIImage(
                systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(scale: .small),
            )
            copyButton.setImage(image, for: .normal)
        }

        private func makeActionButton(for action: CodeBlockAction, tag: Int) -> UIButton {
            let button = UIButton()
            button.setImage(
                UIImage(
                    systemName: action.systemImage,
                    withConfiguration: UIImage.SymbolConfiguration(scale: .small),
                ),
                for: .normal,
            )
            button.tintColor = .label
            button.tag = tag
            button.accessibilityLabel = action.title
            button.addTarget(self, action: #selector(handleAction(_:)), for: .touchUpInside)
            return button
        }

    #elseif canImport(AppKit)
        private func setCopySymbol(_ name: String) {
            copyButton.image = Self.barSymbol(name, accessibilityDescription: nil)
        }

        private func makeActionButton(for action: CodeBlockAction, tag: Int) -> NSButton {
            let button = NSButton(title: "", target: self, action: #selector(handleAction(_:)))
            button.image = Self.barSymbol(action.systemImage, accessibilityDescription: action.title)
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = Self.barButtonTint
            button.toolTip = action.title
            button.tag = tag
            return button
        }
    #endif
}
