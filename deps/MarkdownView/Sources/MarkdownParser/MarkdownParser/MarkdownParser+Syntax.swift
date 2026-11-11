import cmark_gfm
import Foundation

public extension MarkdownParser {
    struct SyntaxSpan: Sendable {
        public enum Kind: Sendable { case heading, emphasis, strong, code, link, quote, marker }
        public let range: NSRange
        public let kind: Kind
    }

    /// Source ranges from the same CommonMark parser used to render documents. Later spans
    /// are more specific than earlier ones. Offsets are UTF-16 for attributed text.
    func syntaxSpans(_ source: String) -> [SyntaxSpan] {
        let root = withParser { parser in
            source.withCString { bytes in
                cmark_parser_feed(parser, bytes, source.utf8.count)
                return cmark_parser_finish(parser)
            }
        }
        guard let root else { return [] }
        defer { cmark_node_free(root) }

        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (i, byte) in bytes.enumerated() where byte == 10 { lineStarts.append(i + 1) }
        // Map each byte boundary to its UTF-16 offset once, including CJK and emoji.
        var utf16Offsets = [Int](repeating: 0, count: bytes.count + 1)
        var byteOffset = 0
        var utf16Offset = 0
        for scalar in source.unicodeScalars {
            let length = scalar.utf8.count
            for i in 0..<length { utf16Offsets[byteOffset + i] = utf16Offset }
            byteOffset += length
            utf16Offset += scalar.value > 0xFFFF ? 2 : 1
            utf16Offsets[byteOffset] = utf16Offset
        }

        func bytePosition(line: Int, column: Int, end: Bool = false) -> Int? {
            guard line > 0, line <= lineStarts.count, column > 0 else { return nil }
            let start = lineStarts[line - 1]
            let lineEnd = line < lineStarts.count ? lineStarts[line] - 1 : bytes.count
            return min(lineEnd, start + column - (end ? 0 : 1))
        }
        var spans: [SyntaxSpan] = []
        func append(_ start: Int, _ end: Int, _ kind: SyntaxSpan.Kind) {
            guard start >= 0, end > start, end <= bytes.count else { return }
            let location = utf16Offsets[start]
            let length = utf16Offsets[end] - location
            if length > 0 { spans.append(.init(range: NSRange(location: location, length: length), kind: kind)) }
        }
        func visit(_ node: UnsafeNode) {
            let info = node.pointee
            guard let start = bytePosition(line: Int(info.start_line), column: Int(info.start_column)),
                  let end = bytePosition(line: Int(info.end_line), column: Int(info.end_column), end: true) else {
                for child in node.children { visit(child) }
                return
            }
            switch node.nodeType {
            case .heading: append(start, end, .heading)
            case .emphasis: append(start, end, .emphasis)
            case .strong: append(start, end, .strong)
            case .code:
                // cmark's inline-code coordinates exclude the backtick delimiters.
                var lower = start
                var upper = end
                while lower > 0 && bytes[lower - 1] == 96 { lower -= 1 }
                while upper < bytes.count && bytes[upper] == 96 { upper += 1 }
                append(lower, upper, .code)
            case .codeBlock: append(start, end, .code)
            case .link, .image: append(start, end, .link)
            case .blockquote:
                for line in Int(info.start_line)...Int(info.end_line) where line > 0 && line <= lineStarts.count {
                    var position = lineStarts[line - 1]
                    while position < bytes.count && (bytes[position] == 32 || bytes[position] == 9) { position += 1 }
                    if position < bytes.count && bytes[position] == 62 { append(position, position + 1, .quote) }
                }
            case .item, .taskListItem:
                var position = start
                while position < end && bytes[position] >= 48 && bytes[position] <= 57 { position += 1 }
                if position < end && [UInt8(45), 43, 42, 46, 41].contains(bytes[position]) {
                    append(start, position + 1, .marker)
                }
            case .thematicBreak: append(start, end, .marker)
            default: break
            }
            for child in node.children { visit(child) }
        }
        for node in root.children { visit(node) }
        return spans
    }
}
