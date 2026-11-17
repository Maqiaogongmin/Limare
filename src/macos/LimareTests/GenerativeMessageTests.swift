import XCTest
@testable import Limare

@MainActor
final class GenerativeMessageTests: XCTestCase {
    private let root = #"{"op":"add","path":"/root","value":"card"}"#
    private let element = #"{"op":"add","path":"/elements/card","value":{"type":"Card","props":{"title":"测试"},"children":[]}}"#

    func testStreamingBlockKeepsTrailingNewlineAndFinalizes() throws {
        let source = "Before\n\n```spec\n\(root)\n\(element)\n"
        let parts = try XCTUnwrap(GenerativeMessageSegments.split(source))
        guard case .block(let block) = parts.last else { return XCTFail("missing block") }
        XCTAssertFalse(block.closed)
        XCTAssertTrue(block.input.hasSuffix("\n"))
        let model = GenerativeBlockModel()
        model.update(input: block.input, closed: false, streaming: true)
        XCTAssertEqual(model.spec.root, "card")
        XCTAssertNotNil(model.spec.elements["card"])
        XCTAssertFalse(model.isFinalized)
        model.update(input: block.input + "```", closed: true, streaming: true)
        XCTAssertTrue(model.isFinalized)
        XCTAssertNotNil(model.spec.elements["card"])
    }

    func testHistoricalAndInterruptedFinalLineWithoutNewline() {
        let model = GenerativeBlockModel()
        model.update(input: root + "\n" + element, closed: false, streaming: false)
        XCTAssertTrue(model.isFinalized)
        XCTAssertNotNil(model.spec.elements["card"])
        model.update(input: root + "\n" + element, closed: false, streaming: false)
        XCTAssertNotNil(model.spec.elements["card"])
    }

    func testReplacedInputRebuildsCompiler() {
        let model = GenerativeBlockModel()
        model.update(input: root + "\n" + element + "\n", closed: false, streaming: true)
        model.update(input: #"{"op":"add","path":"/root","value":"other"}"# + "\n", closed: false, streaming: true)
        XCTAssertEqual(model.spec.root, "other")
        XCTAssertNil(model.spec.elements["card"])
    }

    func testRegistryUsesUpstreamComponentsWithoutImage() {
        let keys = Set(GenerativeRegistries.animated.components.keys)
        XCTAssertFalse(keys.contains("Image"))
        XCTAssertTrue(["Card", "BarChart", "LineChart", "Row", "Column", "Toggle", "Divider"].allSatisfy(keys.contains))
        XCTAssertTrue(GenerativeRegistries.animated.actions.isEmpty)
    }

    func testTopLevelFencesAndOrdinaryMarkdown() throws {
        XCTAssertNil(GenerativeMessageSegments.split("ordinary spec text"))
        XCTAssertNil(GenerativeMessageSegments.split("> ```spec\n> \(root)\n> ```"))
        XCTAssertNil(GenerativeMessageSegments.split("````text\n```spec\n\(root)\n```\n````"))
        let source = "before\r\n\r\n~~~spec\r\n\(root)\r\n~~~\r\n\r\n```spec\n\(root)\n```\n\nafter"
        let parts = try XCTUnwrap(GenerativeMessageSegments.split(source))
        let blocks = parts.compactMap { part -> GenerativeMessageSegments.Block? in
            if case .block(let block) = part { return block }
            return nil
        }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy(\.closed))
        let reconstructed = parts.map { part in
            switch part { case .markdown(let text): text; case .block(let block): block.original }
        }.joined()
        XCTAssertEqual(reconstructed, source)
    }

    func testFenceIndentationAndSourcePreservation() throws {
        for count in 0...3 {
            let spaces = String(repeating: " ", count: count)
            let source = "before\n\n\(spaces)```spec\n\(root)\n\(spaces)```\n\nafter"
            let parts = try XCTUnwrap(GenerativeMessageSegments.split(source), "indent \(count)")
            let blocks = parts.compactMap { part -> GenerativeMessageSegments.Block? in
                if case .block(let block) = part { return block }
                return nil
            }
            XCTAssertEqual(blocks.count, 1)
            XCTAssertTrue(try XCTUnwrap(blocks.first).closed)
            XCTAssertTrue(try XCTUnwrap(blocks.first).original.hasPrefix(spaces + "```spec"))
            XCTAssertEqual(parts.map { part in
                switch part { case .markdown(let text): text; case .block(let block): block.original }
            }.joined(), source)
        }
        XCTAssertNil(GenerativeMessageSegments.split("    ```spec\n    \(root)\n    ```"))
        XCTAssertNil(GenerativeMessageSegments.split("\t```spec\n\t\(root)\n\t```"))
    }

    func testIndentedFenceDoesNotCloseStreamingBlock() throws {
        for indentation in ["    ", "\t", "  \t"] {
            let source = "```spec\n\(root)\n\(indentation)```\n"
            let parts = try XCTUnwrap(GenerativeMessageSegments.split(source))
            guard case .block(let block) = parts.first else { return XCTFail("missing block") }
            XCTAssertFalse(block.closed)
            XCTAssertEqual(block.input, root + "\n\(indentation)```\n")
        }
    }

    func testAdjacentBlocksPreserveWhitespaceInSource() throws {
        let first = "```spec\n\(root)\n```"
        let second = "~~~spec\n\(root)\n~~~"
        for gap in ["\n", "\n\n", "\n\n\n\n"] {
            let source = first + gap + second + "\n"
            let parts = try XCTUnwrap(GenerativeMessageSegments.split(source))
            XCTAssertEqual(parts.count, 4)
            guard case .markdown(let middle) = parts[1], case .markdown(let end) = parts[3] else {
                return XCTFail("missing whitespace segments")
            }
            XCTAssertEqual(middle, gap)
            XCTAssertEqual(end, "\n")
            XCTAssertEqual(parts.map { part in
                switch part { case .markdown(let text): text; case .block(let block): block.original }
            }.joined(), source)
        }
    }
}
