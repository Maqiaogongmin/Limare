import XCTest
import AppKit
import SwiftUI
@testable import Limare
@testable import MarkdownView
import MarkdownParser
import Litext

@MainActor
final class MarkdownViewIntegrationTests: XCTestCase {

    // MARK: - 1. Theme & Typography Alignment & Code Size Contract

    func testThemeAlignmentAndCodeSizePreferenceContract() {
        let origConv = TypographyPreferences.shared.conversationSize
        let origCode = TypographyPreferences.shared.codeSize
        defer {
            TypographyPreferences.shared.conversationSize = origConv
            TypographyPreferences.shared.codeSize = origCode
        }

        // Test configuration A
        TypographyPreferences.shared.conversationSize = 16.0
        TypographyPreferences.shared.codeSize = 12.0

        let themeA = LimareMarkdownRepresentable.makeThemeFromPreferences()
        XCTAssertEqual(themeA.fonts.body.pointSize, 16.0, "Body font size must match conversationPointSize")
        XCTAssertEqual(themeA.fonts.code.pointSize, 12.0, "Fenced code font size must match codePointSize")
        XCTAssertNotNil(themeA.colors.selectionBackground)

        // Mutate codeSize to configuration B
        TypographyPreferences.shared.codeSize = 15.0

        let themeB = LimareMarkdownRepresentable.makeThemeFromPreferences()
        XCTAssertEqual(themeB.fonts.body.pointSize, 16.0, "Body font size remains matched to conversationPointSize")
        XCTAssertEqual(themeB.fonts.code.pointSize, 15.0, "Fenced code font size must reflect updated codePointSize")
    }

    // MARK: - 2. Profiles Configuration

    func testTwoProfilesConfiguration() {
        let chatProfile = LimareMarkdownView.Profile.chat(isStreaming: true, messageId: "turn-123")
        let docProfile = LimareMarkdownView.Profile.document

        XCTAssertNotEqual(chatProfile, docProfile)

        if case let .chat(isStreaming, id) = chatProfile {
            XCTAssertTrue(isStreaming)
            XCTAssertEqual(id, "turn-123")
        } else {
            XCTFail("Expected chat profile")
        }

        if case .document = docProfile {
            // Success
        } else {
            XCTFail("Expected document profile")
        }
    }

    // MARK: - 3. Streaming Tail Repair & Incomplete Syntax

    func testStreamingTailRepair() {
        let incompleteBold = "**Unclosed bold text"
        let repairedBold = MarkdownParser.StreamingTail(closing: incompleteBold).applied(to: incompleteBold)
        XCTAssertTrue(repairedBold.hasSuffix("**"), "Repaired prose should close unclosed bold markers")

        let incompleteFence = "```swift\nlet answer = 42"
        let repairedFence = MarkdownParser.StreamingTail(closing: incompleteFence).applied(to: incompleteFence)
        XCTAssertTrue(repairedFence.contains("```"), "Repaired code should close unclosed fence markers")

        let incompleteTable = "| Header 1 | Header 2 |\n| :--- | :--- |\n| Data 1 |"
        let repairedTable = MarkdownParser.StreamingTail(closing: incompleteTable).applied(to: incompleteTable)
        XCTAssertFalse(repairedTable.isEmpty)

        let parser = MarkdownParser()
        let result = parser.parse(repairedBold)
        XCTAssertFalse(result.document.isEmpty)
    }

    // MARK: - 4. Lists Contract (Nested, Ordered, Unordered, Tabs)

    func testListsContract() {
        let listMarkdown = """
        - Unordered Item 1
          - Nested Child 1.1 (2-space)
            - Nested Grandchild 1.1.1 (4-space)
        - Unordered Item 2
        \t- Tab-indented Child 2.1

        1. Ordered First
        2. Ordered Second
           1. Nested Ordered Sub-1
           2. Nested Ordered Sub-2
        3. Mixed Nesting:
           - Bullet under ordered
           - Another bullet
             1. Ordered under bullet
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(listMarkdown)

        // Semantic Contract Assertions:
        // 1. Unordered bullet list at root
        guard case let .bulletedList(_, bulletItems) = parseResult.document[0] else {
            XCTFail("First block must be parsed as a bulletedList")
            return
        }
        XCTAssertEqual(bulletItems.count, 2, "Root bulleted list should have 2 items")
        // Nested bullet list inside item 1
        let nestedBulletLists = bulletItems[0].children.compactMap { block -> [RawListItem]? in
            if case let .bulletedList(_, subItems) = block { return subItems }
            return nil
        }
        XCTAssertFalse(nestedBulletLists.isEmpty, "Item 1 must contain nested bullet list in its children")
        XCTAssertEqual(nestedBulletLists.first?.count, 1, "Child 1.1 list item count")

        // 2. Ordered numbered list at root
        guard case let .numberedList(_, start, orderedItems) = parseResult.document[1] else {
            XCTFail("Second block must be parsed as a numberedList")
            return
        }
        XCTAssertEqual(start, 1, "Ordered list must start at index 1")
        XCTAssertEqual(orderedItems.count, 3, "Ordered list should have 3 items")

        // Nested ordered list inside Item 2
        let nestedOrderedLists = orderedItems[1].children.compactMap { block -> [RawListItem]? in
            if case let .numberedList(_, _, subItems) = block { return subItems }
            return nil
        }
        XCTAssertFalse(nestedOrderedLists.isEmpty, "Item 2 must contain nested numbered list in its children")

        // Rendering integration: verify layout
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 500)
        XCTAssertGreaterThan(size.height, 0, "Nested lists should produce positive layout height")
    }

    // MARK: - 5. Fenced Code Contract (Tildes, Fences, Unknown Languages, Fidelity)

    func testFencedCodeContract() {
        let codeMarkdown = """
        ```swift
        func execute() -> Int {
            return 42
        }
        ```

        ~~~python
        def compute():
            return "tilde fence"
        ~~~

        ````text
        Inside four-backtick fence:
        ```swift
        nested backticks
        ```
        ````

        ```unknown-syntax-xyz-123
        custom_directive @run {
            target: "safe_fallback"
        }
        ```
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(codeMarkdown)

        // Semantic Contract Assertions:
        XCTAssertEqual(parseResult.document.count, 4, "Must parse exactly 4 code fence blocks")

        // 1. Backtick Swift block
        guard case let .codeBlock(swiftFence, swiftCode) = parseResult.document[0] else {
            XCTFail("Block 0 must be .codeBlock")
            return
        }
        XCTAssertEqual(swiftFence, "swift")
        XCTAssertTrue(swiftCode.contains("func execute() -> Int"))

        // 2. Tilde Python block
        guard case let .codeBlock(pythonFence, pythonCode) = parseResult.document[1] else {
            XCTFail("Block 1 must be .codeBlock")
            return
        }
        XCTAssertEqual(pythonFence, "python")
        XCTAssertTrue(pythonCode.contains("return \"tilde fence\""))

        // 3. Quad backtick text block with nested backticks
        guard case let .codeBlock(textFence, textCode) = parseResult.document[2] else {
            XCTFail("Block 2 must be .codeBlock")
            return
        }
        XCTAssertEqual(textFence, "text")
        XCTAssertTrue(textCode.contains("```swift\nnested backticks\n```"))

        // 4. Unknown syntax language identifier fallback
        guard case let .codeBlock(unknownFence, unknownCode) = parseResult.document[3] else {
            XCTFail("Block 3 must be .codeBlock")
            return
        }
        XCTAssertEqual(unknownFence, "unknown-syntax-xyz-123")
        XCTAssertTrue(unknownCode.contains("custom_directive @run"))

        // Rendering integration: verify layout
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 600)
        XCTAssertGreaterThan(size.height, 0, "Code blocks must lay out successfully without crashing")
    }

    // MARK: - 6. Rich Formatting Contract (Strikethrough, Tasks, Quotes)

    func testRichFormattingContract() {
        let richMarkdown = """
        > Level 1 Blockquote
        >
        > > Level 2 Nested Blockquote

        - [x] Completed task item
        - [ ] Pending task item with **bold** label

        Text formatting:
        This is ~~strikethrough~~ and *italic* and `inline code`.
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(richMarkdown)
        // Semantic Contract Assertions:
        // 1. Blockquote: recognized, with the text of both levels. MarkdownView 4.8.2 flattens
        //    a nested quote into paragraphs of the outer one (`flattenBlockquoteChildren`), so the
        //    nesting itself is not represented; this pins that upstream behavior.
        func paragraphText(_ block: MarkdownBlockNode) -> String? {
            guard case let .paragraph(inlines) = block else { return nil }
            return inlines.compactMap { inline -> String? in
                if case let .text(t) = inline { return t }
                return nil
            }.joined()
        }
        guard case let .blockquote(quoteChildren) = parseResult.document[0] else {
            XCTFail("Block 0 must be .blockquote")
            return
        }
        let quoteTexts = quoteChildren.compactMap(paragraphText)
        XCTAssertTrue(quoteTexts.contains { $0.contains("Level 1 Blockquote") }, "Blockquote must keep the Level 1 text")
        XCTAssertTrue(quoteTexts.contains { $0.contains("Level 2 Nested Blockquote") }, "Blockquote must keep the nested quote's text")
        XCTAssertFalse(quoteChildren.contains { if case .blockquote = $0 { return true } else { return false } },
                       "MarkdownView 4.8.2 flattens nested quotes; if this changes, revisit the blockquote contract")

        // 2. Task list semantics:
        guard case let .taskList(_, taskItems) = parseResult.document[1] else {
            XCTFail("Block 1 must be .taskList")
            return
        }
        XCTAssertEqual(taskItems.count, 2, "Task list should have 2 items")
        XCTAssertTrue(taskItems[0].isCompleted, "- [x] must be recognized with isCompleted == true")
        XCTAssertFalse(taskItems[1].isCompleted, "- [ ] must be recognized with isCompleted == false")

        // 3. Strikethrough semantic inline node:
        let lastBlock = parseResult.document.last
        var foundStrikethrough = false
        if case let .paragraph(inlines) = lastBlock {
            for inline in inlines {
                if case let .strikethrough(strikeChildren) = inline {
                    foundStrikethrough = true
                    if case let .text(t) = strikeChildren.first {
                        XCTAssertEqual(t, "strikethrough")
                    }
                }
            }
        }
        XCTAssertTrue(foundStrikethrough, "~~strikethrough~~ must be parsed as .strikethrough inline node")

        // Rendering integration: verify layout
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 550)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - 7. Tables Contract (GFM, Escaped Pipes, Alignment)

    func testTablesContract() {
        let tableMarkdown = """
        | Left Align | Center Align | Right Align | Escaped Pipe |
        | :--- | :---: | ---: | :--- |
        | Alpha | Beta | 1,000 | A \\| B |
        | Gamma | Delta | 2,500 | Simple |
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(tableMarkdown)

        // Semantic Contract Assertions:
        guard case let .table(alignments, rows) = parseResult.document[0] else {
            XCTFail("Parsed block must be .table")
            return
        }

        // Column count & alignments
        XCTAssertEqual(alignments.count, 4, "Table must have 4 columns")
        XCTAssertEqual(alignments[0], .left, "Column 0 alignment :--- should be .left")
        XCTAssertEqual(alignments[1], .center, "Column 1 alignment :---: should be .center")
        XCTAssertEqual(alignments[2], .right, "Column 2 alignment ---: should be .right")
        XCTAssertEqual(alignments[3], .left, "Column 3 alignment :--- should be .left")

        // Rows count: header + 2 data rows = 3 rows
        XCTAssertEqual(rows.count, 3, "Table should have 3 rows (1 header + 2 data)")

        // Escaped pipe verification in Row 1 Cell 3
        let row1Cell3 = rows[1].cells[3]
        let cellText = row1Cell3.content.compactMap { inline -> String? in
            if case let .text(t) = inline { return t }
            return nil
        }.joined()
        XCTAssertEqual(cellText, "A | B", "Escaped pipe `\\|` must be unescaped into cell text and preserve 4 columns")

        // Rendering integration: verify layout
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 650)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - 8. Math Contract (Inline and Display)

    func testMathContract() {
        let mathMarkdown = """
        Inline formula: $E = mc^2$ and $\\lambda_{max} = \\frac{b}{T}$.

        Display formula block:
        $$
        \\int_{-\\infty}^{\\infty} e^{-x^2} dx = \\sqrt{\\pi}
        $$
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(mathMarkdown)

        // Semantic Contract Assertions:
        // MathContext maps indices to parsed LaTeX formulas
        XCTAssertFalse(parseResult.mathContext.isEmpty, "MathContext must contain extracted LaTeX formulas")
        let allFormulas = parseResult.mathContext.values.joined(separator: " ")
        XCTAssertTrue(allFormulas.contains("E = mc^2"), "MathContext must preserve inline formula `E = mc^2`")
        XCTAssertTrue(allFormulas.contains("\\int_{-\\infty}^{\\infty}"), "MathContext must preserve display formula LaTeX")

        // Inline node verification
        var foundMathNodes = 0
        for block in parseResult.document {
            if case let .paragraph(inlines) = block {
                for inline in inlines {
                    if case let .math(content, _) = inline {
                        foundMathNodes += 1
                        XCTAssertFalse(content.isEmpty)
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(foundMathNodes, 2, "Document must contain at least 2 .math inline nodes")

        // Rendering integration: verify layout
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 600)
        XCTAssertGreaterThan(size.height, 0, "Math rendering must produce valid layout height")
    }

    // MARK: - 9. CJK & Latin Fidelity

    func testCJKAndLatinFidelity() {
        let cjkMarkdown = """
        # 中文标题：系统状态与观测
        这是包含 **粗体中文** 和 *斜体文本* 的段落。
        同时包含日本語：こんにちは世界、および 한국어: 안녕하세요。

        - 列表项一：架构边界与权威
        - 列表项二：CJK 原文无破坏性预处理
        - List Item 3: Mixed English with 中文 mixed `codeToken()`

        ```rust
        fn main() {
            println!("你好，世界！");
        }
        ```
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(cjkMarkdown)
        XCTAssertGreaterThan(parseResult.document.count, 0)

        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let size = streamView.boundingSize(for: 600)
        XCTAssertGreaterThan(size.height, 0)
    }

    // A single newline the user typed stays a line break; in a document it is a space.
    func testTypedProfileKeepsSingleNewlines() {
        let source = "第一行\n第二行"
        func height(_ profile: LimareMarkdownView.Profile) -> CGFloat {
            let theme = LimareMarkdownRepresentable.makeTheme(
                conversationPointSize: 15,
                codePointSize: 13,
                profile: profile
            )
            let view = LimareStreamView()
            view.setContentImmediately(
                MarkdownContent(parserResult: MarkdownParser().parse(source), theme: theme),
                theme: theme
            )
            return view.boundingSize(for: 600).height
        }

        let oneLine = height(.document)
        let typed = height(.typed)
        XCTAssertGreaterThan(typed, oneLine + 10, "The typed newline must start a second line")
        XCTAssertLessThan(typed, oneLine * 2 + 10, "The second line must not get paragraph spacing")
    }

    // MARK: - 10. Streaming Convergence Equivalence

    func testStreamingConvergenceEquivalence() {
        let messageId = "stream-conv-\(UUID().uuidString)"
        let step1 = "### Architectural Convergence\nStreaming"
        let step2 = "### Architectural Convergence\nStreaming responses converge monotonically.\n\n"
        let step3 = "### Architectural Convergence\nStreaming responses converge monotonically.\n\n```swift\nlet status = \"converged\"\n```"
        let finalMarkdown = step3

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let coordinator = LimareMarkdownRepresentable.Coordinator()
        let streamedView = LimareStreamView()

        // 1. Multi-step real streaming traversal
        // Step 1: Initial token arrives with isStreaming = true
        coordinator.apply(
            source: step1,
            profile: .chat(isStreaming: true, messageId: messageId),
            theme: theme,
            to: streamedView,
            isInitial: true
        )
        XCTAssertTrue(streamedView.isStreaming, "View must be in streaming mode during generation")
        XCTAssertEqual(streamedView.streamIdentity, messageId, "Stream identity must be tracked")

        // Step 2: Intermediate stream chunk arrives in flight
        coordinator.apply(
            source: step2,
            profile: .chat(isStreaming: true, messageId: messageId),
            theme: theme,
            to: streamedView,
            isInitial: false
        )
        XCTAssertTrue(streamedView.isStreaming)

        // Step 3: Stream completes, isStreaming transitions to false
        coordinator.apply(
            source: finalMarkdown,
            profile: .chat(isStreaming: false, messageId: messageId),
            theme: theme,
            to: streamedView,
            isInitial: false
        )
        XCTAssertFalse(streamedView.isStreaming, "View must exit streaming mode on completion")

        // 2. Direct static reference
        let staticResult = MarkdownParser().parse(finalMarkdown)
        let staticContent = MarkdownContent(parserResult: staticResult, theme: theme)
        let staticView = LimareStreamView()
        staticView.setContentImmediately(staticContent, theme: theme)

        // 3. Compare AST semantic convergence
        XCTAssertEqual(
            coordinator.lastParseResult?.document,
            staticResult.document,
            "Streamed final AST must converge to static parse AST"
        )

        // 4. Compare layout bounding size convergence
        let streamedSize = coordinator.sizeThatFits(ProposedViewSize(width: 600, height: nil), for: streamedView, hugsText: false)
        let staticSize = coordinator.sizeThatFits(ProposedViewSize(width: 600, height: nil), for: staticView, hugsText: false)

        XCTAssertNotNil(streamedSize)
        XCTAssertNotNil(staticSize)
        XCTAssertEqual(
            streamedSize?.height ?? 0,
            staticSize?.height ?? 1,
            accuracy: 1.0,
            "Streamed final layout height must converge to static layout height"
        )
    }

    // MARK: - 11. Reflow & Multi-Width Bounding Calculation

    func testActualBoundingSizeAndReflow() {
        let sample = """
        Limare isolates transcript rendering by separating presentation authority from rendering backend.
        When container widths resize, text reflows smoothly without re-parsing AST structures.
        This paragraph is long enough to span multiple lines across narrow container widths.
        """

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let parseResult = parser.parse(sample)
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)

        let widths: [CGFloat] = [240, 360, 500, 750, 1100]
        var heights: [CGFloat] = []
        for w in widths {
            let size = streamView.boundingSize(for: w)
            XCTAssertGreaterThan(size.height, 0, "Height for width \(w) must be positive")
            heights.append(size.height)
        }

        // Monotonic non-increasing: narrow height >= wide height
        XCTAssertGreaterThanOrEqual(heights[0], heights[1])
        XCTAssertGreaterThanOrEqual(heights[1], heights[2])
        XCTAssertGreaterThanOrEqual(heights[2], heights[4])
    }

    // MARK: - 12. Large Document Layout

    func testLargeDocumentLayout() {
        var massive = "# Large Markdown Document Layout Test\n\n"
        for i in 1...15 {
            massive += "## Section \(i): System Observation\n"
            massive += "Paragraph describing architectural isolation boundaries for block \(i). This paragraph contains substantial prose to test word-wrapping, multi-line reflow, CoreText typographic run layout, and height calculation.\n\n"
            massive += "- Item A in block \(i) with additional descriptive details\n"
            massive += "- Item B with `token_\(i)` and extra bullet tokens\n\n"
            massive += "```swift\nlet value_\(i) = \(i * 10)\n```\n\n"
        }
        XCTAssertGreaterThan(massive.count, 5000, "Fixture should exceed substantial character threshold")

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()

        let start = DispatchTime.now()
        let parseResult = parser.parse(massive)
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)
        let size = streamView.boundingSize(for: 600)
        let end = DispatchTime.now()

        let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        XCTAssertGreaterThan(size.height, 300, "Large document must produce substantial layout height")
        XCTAssertLessThan(elapsedMs, 2500.0, "Large document layout should finish within 2500ms budget")
    }

    // MARK: - 13. Selection Callbacks

    func testSelectionBecameActiveCallback() {
        let streamView = LimareStreamView()
        var callbackFired = false
        streamView.onSelectionBecameActive = {
            callbackFired = true
        }

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()
        let result = parser.parse("Hello, selectable world!")
        let content = MarkdownContent(parserResult: result, theme: theme)
        streamView.setContentImmediately(content, theme: theme)

        // Non-empty selection triggers callback
        streamView.textLabelView(streamView.textLabelView, didChangeSelection: NSRange(location: 0, length: 5))
        XCTAssertTrue(callbackFired, "onSelectionBecameActive should be invoked when selection is non-empty")

        // Zero-length selection does not trigger callback
        callbackFired = false
        streamView.textLabelView(streamView.textLabelView, didChangeSelection: NSRange(location: 0, length: 0))
        XCTAssertFalse(callbackFired, "onSelectionBecameActive should not be invoked when selection length is 0")
    }

    // MARK: - 14. Real Adapter Hosting Integration (NSHostingView)

    func testAdapterHostingIntegration() {
        let markdown = """
        # Adapter Hosted View
        Testing integration through `NSHostingView` to verify AppKit representable bridge.
        """

        let chatView = LimareMarkdownView(
            source: markdown,
            profile: .chat(isStreaming: false, messageId: "host_test_msg")
        )

        let hostingView = NSHostingView(rootView: chatView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertNotNil(hostingView)
        XCTAssertEqual(hostingView.frame.width, 400)

        // Width change reflow
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.frame.width, 600)

        // Transition to document profile
        let docView = LimareMarkdownView(
            source: markdown,
            profile: .document
        )
        let docHostingView = NSHostingView(rootView: docView)
        docHostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        docHostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(docHostingView.frame.width, 500)
    }

    // MARK: - 15. Streaming Lifecycle Transition

    func testStreamingLifecycleTransition() {
        let streamView = LimareStreamView()
        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let messageId = "msg-\(UUID().uuidString)"

        streamView.streamIdentity = messageId
        streamView.isStreaming = true

        let token1 = "Thinking through "
        let parse1 = MarkdownParser().parse(token1)
        let content1 = MarkdownContent(parserResult: parse1, theme: theme)
        streamView.setContent(content1)
        XCTAssertTrue(streamView.isStreaming)

        let token2 = "Thinking through the plan..."
        let parse2 = MarkdownParser().parse(token2)
        let content2 = MarkdownContent(parserResult: parse2, theme: theme)
        streamView.setContent(content2)

        // Finalize streaming
        streamView.isStreaming = false
        streamView.setContentImmediately(content2, theme: theme)
        XCTAssertFalse(streamView.isStreaming)
    }

    // MARK: - 16. Performance Benchmark (XCTest Measured)

    func testPerformanceBenchmarkThroughput() {
        var testDocument = "# Benchmark Document\n\n"
        for i in 1...15 {
            testDocument += "## Section \(i)\nThis is a standard text section with **emphasis** and `code`.\n\n"
            testDocument += "| A | B |\n| --- | --- |\n| \(i) | Data |\n\n"
            testDocument += "```swift\nfunc test\(i)() { return }\n```\n\n"
        }

        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let parser = MarkdownParser()

        let start = DispatchTime.now()
        let parseResult = parser.parse(testDocument)
        let content = MarkdownContent(parserResult: parseResult, theme: theme)
        let streamView = LimareStreamView()
        streamView.setContentImmediately(content, theme: theme)
        let size = streamView.boundingSize(for: 600)
        let end = DispatchTime.now()

        let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        print("  📊 Benchmark: 15-section mixed Markdown parsed & laid out in: \(String(format: "%.2f", elapsedMs)) ms (Height: \(size.height))")
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(elapsedMs, 1000.0, "Benchmark run should complete under 1000ms")
    }

    // MARK: - 17. Dynamic Typography Observation Hosting Contract

    func testLiveTypographyObservationHostingContract() {
        let origConv = TypographyPreferences.shared.conversationSize
        let origCode = TypographyPreferences.shared.codeSize

        TypographyPreferences.shared.conversationSize = 14.0
        TypographyPreferences.shared.codeSize = 12.0

        let markdownSource = """
        Regular prose text.

        ```swift
        let sample = "code"
        ```
        """

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: LimareMarkdownView(source: markdownSource, profile: .chat(isStreaming: false, messageId: "type-test")))
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)

        // Teardown order: take the hosted SwiftUI hierarchy down first, then restore the
        // preferences, so no restore lands on a live hosted view.
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
            TypographyPreferences.shared.conversationSize = origConv
            TypographyPreferences.shared.codeSize = origCode
        }

        func findStreamView(in view: NSView) -> LimareStreamView? {
            if let stream = view as? LimareStreamView { return stream }
            for subview in view.subviews {
                if let found = findStreamView(in: subview) { return found }
            }
            return nil
        }

        /// Runs the main run loop (SwiftUI's own update cycle) until `condition` holds. Layout
        /// is never forced from the test: updates arrive as they do in the app.
        func runUpdates(until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }

        window.contentView = hostingView
        runUpdates { findStreamView(in: hostingView).map { $0.theme.fonts.body.pointSize == 14.0 } ?? false }
        guard let streamView = findStreamView(in: hostingView) else {
            XCTFail("LimareStreamView must exist in NSHostingView hierarchy")
            return
        }
        XCTAssertEqual(streamView.theme.fonts.body.pointSize, 14.0, accuracy: 0.01)
        XCTAssertEqual(streamView.theme.fonts.code.pointSize, 12.0, accuracy: 0.01)

        // Conversation size alone: body follows, fenced code does not.
        TypographyPreferences.shared.conversationSize = 17.0
        runUpdates { streamView.theme.fonts.body.pointSize == 17.0 }
        XCTAssertEqual(streamView.theme.fonts.body.pointSize, 17.0, accuracy: 0.01, "Conversation size mutation must drive the hosted view's body font")
        XCTAssertEqual(streamView.theme.fonts.code.pointSize, 12.0, accuracy: 0.01, "Conversation size must not change the fenced-code font")

        // Code size alone: fenced code follows, body does not.
        TypographyPreferences.shared.codeSize = 15.0
        runUpdates { streamView.theme.fonts.code.pointSize == 15.0 }
        XCTAssertEqual(streamView.theme.fonts.code.pointSize, 15.0, accuracy: 0.01, "Code size mutation must drive the hosted view's code font")
        XCTAssertEqual(streamView.theme.fonts.body.pointSize, 17.0, accuracy: 0.01, "Code size must not change the body font")

        // The view on screen was updated in place, not replaced.
        XCTAssertTrue(findStreamView(in: hostingView) === streamView, "The existing hosted Markdown view must be the one updated")
    }

    // MARK: - 17b. Reading Typography

    func testReadingProfilesUseTheSerifAndTypedStaysSystem() {
        let chat = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 14, codePointSize: 12, profile: .chat(isStreaming: false, messageId: "a"))
        let document = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 14, codePointSize: 12, profile: .document)
        let typed = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 14, codePointSize: 12, profile: .typed)

        for theme in [chat, document] {
            XCTAssertEqual(theme.fonts.body.familyName, "Noto Serif SC")
            XCTAssertTrue(theme.fonts.bold === ReadingFont.semibold(size: 14), "Bold is the 600 instance, not a derived trait")
            XCTAssertTrue(theme.fonts.italic === ReadingFont.regular(size: 14), "Italic is set upright")
            for heading in theme.headings {
                XCTAssertEqual(heading.font.familyName, "Noto Serif SC")
                XCTAssertEqual(heading.kern, 0)
            }
        }
        XCTAssertNotEqual(typed.fonts.body.familyName, "Noto Serif SC")
        XCTAssertTrue(typed.headings.allSatisfy { $0.font.familyName != "Noto Serif SC" && $0.kern == 0 })
        for theme in [chat, document, typed] {
            XCTAssertTrue(theme.fonts.code.isFixedPitch)
            XCTAssertTrue(theme.fonts.codeInline.isFixedPitch)
        }
    }

    func testLeadingFollowsTheFontAndSize() {
        for size in [14.0, 16.0, 18.0] as [CGFloat] {
            for (profile, multiple) in [(LimareMarkdownView.Profile.chat(isStreaming: false, messageId: "a"), 1.70),
                                        (.document, 1.70), (.typed, 1.50)] as [(LimareMarkdownView.Profile, CGFloat)] {
                let theme = LimareMarkdownRepresentable.makeTheme(conversationPointSize: size, codePointSize: 12, profile: profile)
                let natural = LimareMarkdownRepresentable.Rhythm.naturalLineHeight(of: theme.fonts.body)
                XCTAssertEqual((natural + theme.spacings.line).rounded(), (size * multiple).rounded(), accuracy: 1,
                               "\(profile) at \(size) pt")
            }
        }
        let chat = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 14, codePointSize: 12, profile: .chat(isStreaming: false, messageId: "a"))
        let document = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 14, codePointSize: 12, profile: .document)
        XCTAssertEqual([chat.spacings.paragraph, chat.spacings.list, chat.spacings.headingBefore], [13, 6, 18])
        XCTAssertEqual([document.spacings.paragraph, document.spacings.list, document.spacings.headingBefore], [14, 6, 22])
        print("[reading-typography] 14 pt natural \(LimareMarkdownRepresentable.Rhythm.naturalLineHeight(of: chat.fonts.body)) line \(chat.spacings.line)")
    }

    func testSameInputsMakeEqualThemes() {
        for profile in [LimareMarkdownView.Profile.chat(isStreaming: true, messageId: "a"), .document, .typed] {
            let first = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 15, codePointSize: 12, profile: profile)
            let second = LimareMarkdownRepresentable.makeTheme(conversationPointSize: 15, codePointSize: 12, profile: profile)
            XCTAssertEqual(first, second, "\(profile): an update with the same sizes must not rebuild the text")
        }
    }

    // MARK: - 18. Fences Without a Language

    func testFencesWithoutALanguageAreLeftUncoloured() {
        XCTAssertNil(SyntaxLanguage.named(nil))
        XCTAssertNil(SyntaxLanguage.named(""))
        XCTAssertNil(SyntaxLanguage.named("   "))
        XCTAssertEqual(SyntaxLanguage.named("unknown-syntax-xyz-123")?.keywords, SyntaxLanguage.generic.keywords,
                       "A language the catalog does not know still gets the shared rules")
        XCTAssertNotNil(SyntaxLanguage.named("swift"))
        XCTAssertNotEqual(SyntaxLanguage.named("swift")?.keywords, SyntaxLanguage.generic.keywords)

        let map = CodeHighlighter.current.highlight(key: nil, content: "The app and from", language: "")
        XCTAssertTrue(map.isEmpty, "An unlabelled fence must not be coloured")
    }

    // MARK: - 19. Rule-Style Code Blocks

    private func makeCodeView(lines: Int, theme: MarkdownTheme, language: String = "swift") -> CodeView {
        let content = (1 ... lines).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let view = CodeView(frame: .zero)
        view.theme = theme
        view.language = language
        view.setContent(content, highlightMap: nil)
        // Sized as the text view sizes it: to its intrinsic height, at the column's width.
        view.frame = CGRect(x: 0, y: 0, width: 500, height: view.intrinsicContentSize.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The text reserves `intrinsicContentSize`, whose floor is `intrinsicHeight` from the font's
    /// metrics. The text engine's lines run a little taller than those metrics (about 0.5 pt a
    /// line, in either style), so the two agree for a few lines and the floor is under it after.
    private func assertReservedHeightIsLaidOut(_ view: CodeView, lines: Int, theme: MarkdownTheme,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let reserved = ContextViewAttachment.Appearance.of(view).size.height
        XCTAssertEqual(reserved, view.bounds.height, "\(lines) lines", file: file, line: line)
        let floor = CodeViewConfiguration.intrinsicHeight(lineCount: lines, theme: theme)
        XCTAssertLessThanOrEqual(floor, reserved + 0.5, "\(lines) lines", file: file, line: line)
        if lines <= 3 {
            XCTAssertEqual(floor, reserved, accuracy: 1, "\(lines) lines", file: file, line: line)
        }
    }

    func testRuleCodeBlockMeasuresAsItLaysOut() {
        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        XCTAssertEqual(theme.codeBlockStyle, .rule)
        XCTAssertFalse(theme.showsCodeLineNumbers)
        for lines in [1, 3, 20] {
            let view = makeCodeView(lines: lines, theme: theme)
            assertReservedHeightIsLaidOut(view, lines: lines, theme: theme)
            let text = view.convert(view.textView.bounds, from: view.textView)
            XCTAssertEqual(text.minX, theme.sizes.codeBlockRuleWidth + 14, accuracy: 0.5)
            XCTAssertEqual(text.minY, 2, accuracy: 0.5)
            XCTAssertEqual(view.bounds.height - text.maxY, 2, accuracy: 1, "\(lines) lines: no clipping and no blank below the code")
            XCTAssertTrue(view.lineNumberView.isHidden)
            XCTAssertFalse(view.ruleView.isHidden)
            XCTAssertEqual(view.ruleView.frame.width, theme.sizes.codeBlockRuleWidth)
        }
    }

    func testCardCodeBlockLayoutIsUnchanged() {
        var theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        theme.codeBlockStyle = .card
        theme.showsCodeLineNumbers = true
        for lines in [1, 3, 20] {
            let view = makeCodeView(lines: lines, theme: theme)
            assertReservedHeightIsLaidOut(view, lines: lines, theme: theme)
            XCTAssertEqual(view.bounds.height - view.convert(view.textView.bounds, from: view.textView).maxY,
                           CodeViewConfiguration.codePadding, accuracy: 1)
            let text = view.convert(view.textView.bounds, from: view.textView)
            XCTAssertEqual(text.minX, view.lineNumberView.intrinsicContentSize.width + CodeViewConfiguration.codePadding, accuracy: 0.5)
            XCTAssertGreaterThan(view.barView.frame.height, 0)
            XCTAssertFalse(view.barView.isHidden)
            XCTAssertFalse(view.lineNumberView.isHidden)
            XCTAssertTrue(view.ruleView.isHidden)
            XCTAssertEqual(view.languageLabel.text, "swift")
        }
        XCTAssertEqual(makeCodeView(lines: 1, theme: theme, language: "").languageLabel.text, "</>")
        XCTAssertEqual(MarkdownTheme().codeBlockStyle, .card, "The package default stays upstream's card")
        XCTAssertTrue(MarkdownTheme().showsCodeLineNumbers)
    }

    func testRuleCodeBlockControlsFollowThePointer() {
        let theme = LimareMarkdownRepresentable.makeThemeFromPreferences()
        let view = makeCodeView(lines: 3, theme: theme, language: "")
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3)) }

        XCTAssertTrue(view.languageLabel.isHidden, "No language: no label, and no </>")
        XCTAssertTrue(view.barView.isHidden)
        XCTAssertEqual(view.barView.alphaValue, 0, accuracy: 0.01)
        let copyPoint = view.convert(CGPoint(x: view.copyButton.bounds.midX, y: view.copyButton.bounds.midY), from: view.copyButton)
        XCTAssertFalse(view.interactionTarget(at: copyPoint) === view.copyButton, "Hidden controls take no clicks")

        view.mouseEntered(with: event)
        settle()
        XCTAssertFalse(view.barView.isHidden)
        XCTAssertEqual(view.barView.alphaValue, 1, accuracy: 0.01)
        XCTAssertTrue(view.interactionTarget(at: copyPoint) === view.copyButton)
        XCTAssertEqual(view.barView.frame.maxX, view.bounds.width, accuracy: 0.5, "The controls sit at the top right")

        view.mouseExited(with: event)
        settle()
        XCTAssertTrue(view.barView.isHidden)
        XCTAssertEqual(view.barView.alphaValue, 0, accuracy: 0.01)

        // Copied: the checkmark keeps the controls up after the pointer leaves.
        view.mouseEntered(with: event)
        view.showCopyFeedback()
        view.mouseExited(with: event)
        settle()
        XCTAssertFalse(view.barView.isHidden)
        XCTAssertEqual(view.barView.alphaValue, 1, accuracy: 0.01)
        view.resetCopyFeedback()
        settle()
        XCTAssertTrue(view.barView.isHidden)

        view.language = "swift"
        XCTAssertFalse(view.languageLabel.isHidden)
        XCTAssertEqual(view.languageLabel.text, "swift")
    }
}

extension LimareMarkdownRepresentable {
    /// The theme for the current preferences, as the observing body passes them in production.
    static func makeThemeFromPreferences() -> MarkdownTheme {
        makeTheme(conversationPointSize: AppTypography.conversationPointSize, codePointSize: AppTypography.codePointSize)
    }
}
