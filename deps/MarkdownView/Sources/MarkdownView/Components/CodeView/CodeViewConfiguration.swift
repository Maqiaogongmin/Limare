//
//  Created by ktiays on 2025/1/22.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
enum CodeViewConfiguration {
    nonisolated static let barPadding: CGFloat = 8
    nonisolated static let codePadding: CGFloat = 8
    nonisolated static let codeLineSpacing: CGFloat = 4
    nonisolated static let lineNumberWidth: CGFloat = 40
    nonisolated static let lineNumberPadding: CGFloat = 8
    /// A `.rule` block: from the rule to the code, and above and below the code, so the
    /// block's edges sit on the body's lines.
    nonisolated static let ruleCodeInset: CGFloat = 14
    nonisolated static let ruleCodeVerticalPadding: CGFloat = 2
    /// A `.rule` block's hover controls: their height, their padding at either end, and
    /// their distance from the block's top.
    nonisolated static let hoverBarHeight: CGFloat = 24
    nonisolated static let hoverBarPadding: CGFloat = 8
    nonisolated static let hoverBarTop: CGFloat = 2

    /// Whether a block is drawn in the `.rule` style; UIKit draws every block as a card.
    static func drawsRule(_ theme: MarkdownTheme) -> Bool {
        #if canImport(UIKit)
            false
        #elseif canImport(AppKit)
            theme.codeBlockStyle == .rule
        #endif
    }

    /// Where a block's parts sit, for its style. Measurement and layout both read this, so
    /// the height reserved for a block is the height it lays out to.
    struct Insets {
        /// The bar above the code; a `.rule` block has none.
        var bar: CGFloat
        /// Before the line numbers: the rule's width.
        var gutterLeading: CGFloat
        var codeTop: CGFloat
        var codeBottom: CGFloat
        var codeLeading: CGFloat
        var codeTrailing: CGFloat
    }

    /// `barHeight` is the card's bar, which each caller measures as upstream did.
    static func insets(theme: MarkdownTheme, barHeight: @autoclosure () -> CGFloat) -> Insets {
        if drawsRule(theme) {
            return Insets(
                bar: 0,
                gutterLeading: theme.sizes.codeBlockRuleWidth,
                codeTop: ruleCodeVerticalPadding,
                codeBottom: ruleCodeVerticalPadding,
                codeLeading: ruleCodeInset,
                codeTrailing: 0,
            )
        }
        return Insets(
            bar: barHeight(),
            gutterLeading: 0,
            codeTop: codePadding,
            codeBottom: codePadding,
            codeLeading: codePadding,
            codeTrailing: codePadding,
        )
    }

    static func intrinsicHeight(
        for content: String,
        theme: MarkdownTheme = .default,
    ) -> CGFloat {
        let numberOfRows = content.components(separatedBy: .newlines).count
        return intrinsicHeight(lineCount: numberOfRows, theme: theme)
    }

    /// The font of the language name in the bar, which sets the bar's height.
    static func barFont(theme: MarkdownTheme) -> PlatformFont {
        theme.fonts.codeBlockLabel ?? theme.fonts.code
    }

    static func intrinsicHeight(
        lineCount: Int,
        theme: MarkdownTheme = .default,
    ) -> CGFloat {
        func height(of font: PlatformFont) -> CGFloat {
            #if canImport(UIKit)
                font.lineHeight
            #elseif canImport(AppKit)
                font.ascender + abs(font.descender) + font.leading
            #endif
        }
        let lineHeight = height(of: theme.fonts.code)
        let insets = insets(theme: theme, barHeight: height(of: barFont(theme: theme)) + barPadding * 2)
        let codeHeight = lineHeight * CGFloat(lineCount)
            + insets.codeTop + insets.codeBottom
            + codeLineSpacing * CGFloat(max(lineCount - 1, 0))
        return ceil(insets.bar + codeHeight)
    }
}

extension CodeView {
    func configureSubviews() {
        setupViewAppearance()
        setupBarView()
        setupButtons()
        setupScrollView()
        setupTextView()
        setupLineNumberView()
        setupRuleView()
        applyStyle()
        applyBackgroundColors()
    }

    private func setupButtons() {
        setupPreviewButton()
        setupCopyButton()
        setupBarButton(expandButton, symbol: CodeView.expandSymbol, title: TableTitleText.expand, action: #selector(handleExpand(_:)))
    }

    func performLayout() {
        let labelSize = languageLabel.intrinsicContentSize
        let insets = layoutInsets
        previewButton.isHidden = previewAction == nil

        if CodeViewConfiguration.drawsRule(theme) {
            layoutHoverBar(labelSize: labelSize)
            layoutButtons(height: CodeViewConfiguration.hoverBarHeight, trailingInset: CodeViewConfiguration.hoverBarPadding / 2)
        } else {
            layoutBarView(barHeight: insets.bar, labelSize: labelSize)
            layoutButtons(height: 44, trailingInset: 4)
        }
        layoutRuleView()
        layoutLineNumberView(insets: insets)
        layoutScrollViewAndTextView(insets: insets)
    }

    /// The block's insets, with the card's bar measured as upstream lays it out.
    var layoutInsets: CodeViewConfiguration.Insets {
        CodeViewConfiguration.insets(
            theme: theme,
            barHeight: max(languageLabel.lineHeight, languageLabel.intrinsicContentSize.height) + CodeViewConfiguration.barPadding * 2,
        )
    }

    /// The gutter's width: the line numbers', or none when the theme hides them.
    var lineNumberWidth: CGFloat {
        theme.showsCodeLineNumbers ? lineNumberView.intrinsicContentSize.width : 0
    }

    /// Lays the bar's buttons out from the trailing edge: Expand, Copy, then
    /// Preview when there is a handler, then the host's actions.
    private func layoutButtons(height: CGFloat, trailingInset: CGFloat) {
        let buttonSize = CGSize(width: TableTitleBar.buttonWidth, height: height)
        var trailing = barView.bounds.width - trailingInset
        for button in barButtons where !button.isHidden {
            trailing -= buttonSize.width
            button.applyFrame(CGRect(
                x: trailing,
                y: (barView.bounds.height - buttonSize.height) / 2,
                width: buttonSize.width,
                height: buttonSize.height,
            ))
        }
    }

    private func layoutBarView(barHeight: CGFloat, labelSize: CGSize) {
        barView.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width, height: barHeight))
        languageLabel.frame = CGRect(
            origin: CGPoint(x: CodeViewConfiguration.barPadding, y: CodeViewConfiguration.barPadding),
            size: labelSize,
        )
    }

    /// A `.rule` block's controls: the language, then the buttons, on a small panel at the
    /// block's top right.
    private func layoutHoverBar(labelSize: CGSize) {
        let padding = CodeViewConfiguration.hoverBarPadding
        let height = CodeViewConfiguration.hoverBarHeight
        let buttonCount = CGFloat(barButtons.filter { !$0.isHidden }.count)
        let labelWidth = languageLabel.isHidden ? 0 : labelSize.width + padding / 2
        let width = padding / 2 + labelWidth + buttonCount * TableTitleBar.buttonWidth + padding / 2
        barView.frame = CGRect(
            x: bounds.width - width,
            y: CodeViewConfiguration.hoverBarTop,
            width: width,
            height: height,
        )
        languageLabel.frame = CGRect(
            origin: CGPoint(x: padding, y: (height - labelSize.height) / 2),
            size: labelSize,
        )
        #if !canImport(UIKit)
            barMaterialView.frame = barView.bounds
        #endif
    }

    private func layoutRuleView() {
        ruleView.isHidden = !CodeViewConfiguration.drawsRule(theme)
        ruleView.frame = CGRect(x: 0, y: 0, width: theme.sizes.codeBlockRuleWidth, height: bounds.height)
    }

    private func layoutLineNumberView(insets: CodeViewConfiguration.Insets) {
        lineNumberView.isHidden = !theme.showsCodeLineNumbers
        lineNumberView.frame = CGRect(
            x: insets.gutterLeading,
            y: insets.bar,
            width: lineNumberWidth,
            height: bounds.height - insets.bar,
        )
    }

    private func layoutScrollViewAndTextView(insets: CodeViewConfiguration.Insets) {
        let textContentSize = textView.intrinsicContentSize
        let leading = insets.gutterLeading + lineNumberWidth

        scrollView.frame = CGRect(
            x: leading,
            y: insets.bar,
            width: bounds.width - leading,
            height: bounds.height - insets.bar,
        )

        #if canImport(UIKit)
            let textOrigin = CGPoint(x: insets.codeLeading, y: insets.codeTop)
        #elseif canImport(AppKit)
            // The scroll view's content insets hold the padding.
            let textOrigin = CGPoint.zero
            let contentInsets = NSEdgeInsets(
                top: insets.codeTop,
                left: insets.codeLeading,
                bottom: insets.codeBottom,
                right: insets.codeTrailing,
            )
            if !NSEdgeInsetsEqual(scrollView.contentInsets, contentInsets) {
                scrollView.contentInsets = contentInsets
            }
        #endif
        textView.frame = CGRect(
            x: textOrigin.x,
            y: textOrigin.y,
            width: max(scrollView.bounds.width - insets.codeLeading - insets.codeTrailing, textContentSize.width),
            height: textContentSize.height,
        )

        #if canImport(UIKit)
            scrollView.contentSize = CGSize(
                width: textView.frame.width + CodeViewConfiguration.codePadding * 2,
                height: 0,
            )
        #endif
    }
}

#if canImport(UIKit)
    private extension CodeView {
        func setupViewAppearance() {
            layer.cornerRadius = theme.sizes.codeBlockCornerRadius
            layer.cornerCurve = .continuous
            // Not clipped, so a selection's handles can reach past the code;
            // the bar rounds its own corners instead.
            clipsToBounds = false
        }

        func setupBarView() {
            barView.layer.cornerRadius = layer.cornerRadius
            barView.layer.cornerCurve = .continuous
            barView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            addSubview(barView)
            barView.addSubview(languageLabel)
        }

        func setupPreviewButton() {
            let previewImage = UIImage(
                systemName: "eye",
                withConfiguration: UIImage.SymbolConfiguration(scale: .small),
            )
            previewButton.setImage(previewImage, for: .normal)
            previewButton.tintColor = .label
            previewButton.addTarget(self, action: #selector(handlePreview(_:)), for: .touchUpInside)
            barView.addSubview(previewButton)
        }

        func setupCopyButton() {
            setupBarButton(copyButton, symbol: CodeView.copySymbol, title: TableTitleText.copy, action: #selector(handleCopy(_:)))
        }

        func setupBarButton(_ button: UIButton, symbol: String, title: String, action: Selector) {
            let image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(scale: .small),
            )
            button.setImage(image, for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = title
            button.addTarget(self, action: action, for: .touchUpInside)
            barView.addSubview(button)
        }

        func setupScrollView() {
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            scrollView.blankLeadingWidth = CodeViewConfiguration.codePadding
            scrollView.blankTrailingWidth = CodeViewConfiguration.codePadding
            addSubview(scrollView)
        }

        func setupTextView() {
            textView.backgroundColor = .clear
            textView.preferredMaxLayoutWidth = .greatestFiniteMagnitude
            textView.isSelectable = true
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            scrollView.addSubview(textView)
        }

        func setupLineNumberView() {
            lineNumberView.backgroundColor = .clear
            // Under the code, so a selection's handles draw over the gutter.
            insertSubview(lineNumberView, belowSubview: scrollView)
            updateLineNumberView()
        }

        /// Never shown: UIKit draws every block as a card.
        func setupRuleView() {
            ruleView.isHidden = true
            addSubview(ruleView)
        }
    }

#elseif canImport(AppKit)
    private extension CodeView {
        func setupViewAppearance() {
            wantsLayer = true
            layer?.cornerRadius = theme.sizes.codeBlockCornerRadius
            layer?.cornerCurve = .continuous
            // Clipped, so the bar's tint keeps to the rounded top corners.
            layer?.masksToBounds = true
        }

        func setupBarView() {
            barView.wantsLayer = true
            addSubview(barView)
            barMaterialView.material = .popover
            barMaterialView.blendingMode = .withinWindow
            barMaterialView.wantsLayer = true
            barMaterialView.layer?.cornerRadius = 6
            barMaterialView.layer?.masksToBounds = true
            barView.addSubview(barMaterialView)
            barView.addSubview(languageLabel)
        }

        func setupRuleView() {
            ruleView.wantsLayer = true
            addSubview(ruleView)
        }

        func setupPreviewButton() {
            previewButton.image = CodeView.barSymbol("eye", accessibilityDescription: nil)
            previewButton.target = self
            previewButton.action = #selector(handlePreview(_:))
            previewButton.bezelStyle = .inline
            previewButton.isBordered = false
            previewButton.contentTintColor = CodeView.barButtonTint
            barView.addSubview(previewButton)
        }

        func setupCopyButton() {
            setupBarButton(copyButton, symbol: CodeView.copySymbol, title: TableTitleText.copy, action: #selector(handleCopy(_:)))
        }

        func setupBarButton(_ button: NSButton, symbol: String, title: String, action: Selector) {
            button.image = CodeView.barSymbol(symbol, accessibilityDescription: title)
            button.target = self
            button.action = action
            button.bezelStyle = .inline
            button.isBordered = false
            button.contentTintColor = CodeView.barButtonTint
            button.toolTip = title
            barView.addSubview(button)
        }

        func setupScrollView() {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: CodeViewConfiguration.codePadding,
                left: CodeViewConfiguration.codePadding,
                bottom: CodeViewConfiguration.codePadding,
                right: CodeViewConfiguration.codePadding,
            )
            addSubview(scrollView)
        }

        func setupTextView() {
            textView.wantsLayer = true
            textView.layer?.backgroundColor = NSColor.clear.cgColor
            textView.preferredMaxLayoutWidth = .greatestFiniteMagnitude
            textView.isSelectable = true
            textView.selectionBackgroundColor = theme.colors.selectionBackground
            scrollView.documentView = textView
        }

        func setupLineNumberView() {
            lineNumberView.wantsLayer = true
            lineNumberView.layer?.backgroundColor = NSColor.clear.cgColor
            addSubview(lineNumberView)
            updateLineNumberView()
        }
    }
#endif

extension CodeView {
    /// Sets what differs between a card and a `.rule` block: the corners, the bar's panel,
    /// the language label, and whether the controls show only under the pointer.
    func applyStyle() {
        let drawsRule = CodeViewConfiguration.drawsRule(theme)
        #if canImport(UIKit)
            layer.cornerRadius = theme.sizes.codeBlockCornerRadius
            barView.layer.cornerRadius = layer.cornerRadius
        #elseif canImport(AppKit)
            // A rule block has no fill to round, and rounding would clip its rule's ends.
            layer?.cornerRadius = drawsRule ? 0 : theme.sizes.codeBlockCornerRadius
            barMaterialView.isHidden = !drawsRule
        #endif
        updateLanguageLabel()
        updateControlsVisibility(animated: false)
        markNeedsLayout()
    }

    /// The language in lower case. A card shows `</>` for a block without one; a `.rule`
    /// block shows nothing.
    func updateLanguageLabel() {
        if CodeViewConfiguration.drawsRule(theme) {
            languageLabel.text = language.lowercased()
            languageLabel.isHidden = language.isEmpty
        } else {
            languageLabel.text = language.isEmpty ? "</>" : language.lowercased()
            languageLabel.isHidden = false
        }
    }

    /// Paints the body, the bar and the edge in the theme's code block colours; a `.rule`
    /// block paints only its rule.
    func applyBackgroundColors() {
        let border = theme.colors.codeBlockBorder
        let rule = theme.colors.codeBlockRule ?? theme.colors.body.withAlphaComponent(0.12)
        #if canImport(UIKit)
            backgroundColor = theme.colors.codeBlockBackground
            barView.backgroundColor = theme.colors.codeBlockBarBackground
            layer.borderWidth = border == nil ? 0 : 1
            layer.borderColor = border?.cgColor
        #elseif canImport(AppKit)
            let drawsRule = CodeViewConfiguration.drawsRule(theme)
            // A layer takes a fixed colour, so resolve it for this appearance.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = drawsRule ? nil : theme.colors.codeBlockBackground.cgColor
                barView.layer?.backgroundColor = drawsRule ? nil : theme.colors.codeBlockBarBackground.cgColor
                layer?.borderWidth = drawsRule || border == nil ? 0 : 1
                layer?.borderColor = drawsRule ? nil : border?.cgColor
                ruleView.layer?.backgroundColor = rule.cgColor
            }
        #endif
    }
}
