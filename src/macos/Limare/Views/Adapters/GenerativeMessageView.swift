import SwiftUI

#if canImport(MarkdownParser) && canImport(JSONRenderCore) && canImport(JSONRenderSwiftUI) && canImport(JSONRenderCatalog)
import MarkdownParser
import JSONRenderCore
import JSONRenderSwiftUI
import JSONRenderCatalog

/// Splits only top-level spec fences; all other text remains ordinary Markdown.
enum GenerativeMessageSegments {
    struct Block: Equatable {
        let input: String
        let original: String
        let closed: Bool
    }
    enum Content: Equatable {
        case markdown(String)
        case block(Block)
    }

    static func split(_ source: String) -> [Content]? {
        guard source.contains("spec") else { return nil }
        let ranges = MarkdownParser().parseBlockRange(source)
        var parts: [Content] = []
        var cursor = source.startIndex
        var found = false
        for range in ranges where range.type == .codeBlock {
            let bytes = source.utf8
            guard let newline = bytes[range.startIndex...].firstIndex(of: 10) else { continue }
            let lineStart = bytes[..<range.startIndex].lastIndex(of: 10)
                .map { bytes.index(after: $0) } ?? source.startIndex
            let openingBytes = bytes[lineStart..<newline]
            let indentation = openingBytes.prefix { $0 == 32 }.count
            guard indentation <= 3,
                  let firstFenceByte = openingBytes.dropFirst(indentation).first,
                  firstFenceByte == 96 || firstFenceByte == 126 else { continue }
            let opening = String(decoding: openingBytes.dropFirst(indentation), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = opening.prefix { $0 == "`" || $0 == "~" }
            guard marker.count >= 3, Set(marker).count == 1,
                  opening.dropFirst(marker.count).trimmingCharacters(in: .whitespaces) == "spec" else { continue }
            let bodyStart = bytes.index(after: newline)
            let rangeHasBody = bodyStart <= range.endIndex
            let lastNewline = rangeHasBody ? bytes[bodyStart..<range.endIndex].lastIndex(of: 10) : nil
            let lastStart = lastNewline.map { bytes.index(after: $0) } ?? bodyStart
            let closingBytes = rangeHasBody ? bytes[lastStart..<range.endIndex] : bytes[bodyStart..<bodyStart]
            let closingIndentation = closingBytes.prefix { $0 == 32 }.count
            let lastLine = String(decoding: closingBytes.dropFirst(closingIndentation), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let closingMarker = lastLine.prefix { $0 == marker.first }
            let closed = closingIndentation <= 3 && closingBytes.dropFirst(closingIndentation).first == firstFenceByte &&
                closingMarker.count >= marker.count && lastLine.dropFirst(closingMarker.count).isEmpty
            let end = closed ? range.endIndex : source.endIndex
            guard cursor <= lineStart, bodyStart <= end else { continue }
            if cursor < lineStart {
                parts.append(.markdown(String(source[cursor..<lineStart])))
            }
            parts.append(.block(Block(
                input: String(decoding: bytes[bodyStart..<end], as: UTF8.self),
                original: String(decoding: bytes[lineStart..<end], as: UTF8.self),
                closed: closed
            )))
            found = true
            cursor = end
            if !closed { break }
        }
        guard found else { return nil }
        if cursor < source.endIndex { parts.append(.markdown(String(source[cursor...]))) }
        return parts
    }
}

@MainActor
final class GenerativeBlockModel: ObservableObject {
    @Published private(set) var spec = Spec(root: "", elements: [:])
    @Published private(set) var isFinalized = false
    private var compiler = SpecStreamCompiler()
    private var consumed = ""

    func update(input: String, closed: Bool, streaming: Bool) {
        if !input.hasPrefix(consumed) || (isFinalized && input != consumed) {
            compiler = SpecStreamCompiler()
            consumed = ""
            isFinalized = false
            spec = Spec(root: "", elements: [:])
        }
        if input != consumed {
            // Drop by UTF-8 bytes: chunks may end between Unicode characters as the
            // surrounding message is refreshed, but the saved prefix is complete.
            let suffix = String(decoding: input.utf8.dropFirst(consumed.utf8.count), as: UTF8.self)
            spec = Spec.decodePartial(compiler.push(suffix).result)
            consumed = input
        }
        if (closed || !streaming) && !isFinalized {
            spec = Spec.decodePartial(compiler.getResult())
            isFinalized = true
        }
    }
}

@MainActor
enum GenerativeRegistries {
    static let animated = make(animated: true)
    static let reduced = make(animated: false)
    private static func make(animated: Bool) -> RendererRegistry<AnyView> {
        var registry = NativeCatalog.registry(actions: [:], animatesAppearance: animated)
        registry.components.removeValue(forKey: "Image")
        return registry
    }
}

private struct GenerativeBlockView: View {
    let block: GenerativeMessageSegments.Block
    let streaming: Bool
    let onSelectionBecameActive: (@MainActor () -> Void)?
    let onQuote: (@MainActor (String) -> Void)?
    let messageId: String
    @StateObject private var model = GenerativeBlockModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Input: Equatable {
        let text: String
        let closed: Bool
        let streaming: Bool
    }
    private var input: Input { Input(text: block.input, closed: block.closed, streaming: streaming) }
    private var registry: RendererRegistry<AnyView> { reduceMotion ? GenerativeRegistries.reduced : GenerativeRegistries.animated }
    private var hasRoot: Bool {
        !model.spec.root.isEmpty && model.spec.elements[model.spec.root].map { registry.components[$0.type] != nil } == true
    }
    private func sync() { model.update(input: input.text, closed: input.closed, streaming: input.streaming) }

    var body: some View {
        Group {
            if hasRoot {
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    JSONRenderView(spec: model.spec, registry: registry, navigate: nil, confirm: nil,
                                   loading: streaming && !model.isFinalized,
                                   animation: AppMotion.resolved(AppMotion.standard))
                        .jsonRenderTextScale(CGFloat(TypographyPreferences.shared.conversationSize) / 13.0)
                    if !streaming && !block.closed {
                        Text(String(localized: "Output incomplete"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if (streaming && !block.closed) || !model.isFinalized {
                ProgressView().controlSize(.small).padding(.vertical, AppSpacing.xxSmall)
            } else {
                LimareMarkdownView(source: block.original, profile: .chat(isStreaming: false, messageId: messageId),
                                   onSelectionBecameActive: onSelectionBecameActive, onQuote: onQuote)
            }
        }
        .onAppear { sync() }
        .onChange(of: input) { _, _ in sync() }
    }
}
#endif

struct GenerativeMessageView: View {
    let source: String
    let messageId: String
    let streaming: Bool
    let onSelectionBecameActive: (@MainActor () -> Void)?
    let onQuote: (@MainActor (String) -> Void)?

    var body: some View {
        #if canImport(MarkdownParser) && canImport(JSONRenderCore) && canImport(JSONRenderSwiftUI) && canImport(JSONRenderCatalog)
        if let parts = GenerativeMessageSegments.split(source) {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    switch part {
                    case .markdown(let text):
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            LimareMarkdownView(source: text,
                                profile: .chat(isStreaming: streaming && index == parts.count - 1, messageId: "\(messageId)#\(index)"),
                                onSelectionBecameActive: onSelectionBecameActive, onQuote: onQuote)
                        }
                    case .block(let block):
                        GenerativeBlockView(block: block, streaming: streaming,
                            onSelectionBecameActive: onSelectionBecameActive, onQuote: onQuote,
                            messageId: "\(messageId)#\(index)")
                    }
                }
            }
        } else {
            markdown
        }
        #else
        markdown
        #endif
    }

    private var markdown: some View {
        LimareMarkdownView(source: source, profile: .chat(isStreaming: streaming, messageId: messageId),
                           onSelectionBecameActive: onSelectionBecameActive, onQuote: onQuote)
    }
}
