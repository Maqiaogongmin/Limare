import SwiftUI
import AppKit
import WebKit
import PDFKit

// MARK: - Document Toolbar

public struct FilePreviewToolbar: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.worksurface.files.treeWidth") private var storedTreeWidth: Double = Double(AppLayout.filesTreeIdealWidth)
    let metadata: FileMetadata
    let onBack: (() -> Void)?
    /// Reloads the store this preview belongs to (a file's own tab, or the Files navigator).
    let onRefresh: () -> Void
    /// Shows the file's source instead of its rendering; nil for files with only one view.
    let showsSource: Binding<Bool>?
    /// Opens the file in the Work Surface browser, where its scripts run; HTML only.
    let onOpenInBrowser: (() -> Void)?

    public init(
        metadata: FileMetadata,
        onBack: (() -> Void)? = nil,
        onRefresh: @escaping () -> Void,
        showsSource: Binding<Bool>? = nil,
        onOpenInBrowser: (() -> Void)? = nil
    ) {
        self.metadata = metadata
        self.onBack = onBack
        self.onRefresh = onRefresh
        self.showsSource = showsSource
        self.onOpenInBrowser = onOpenInBrowser
    }

    public var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Files")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
                .help("Back to File Tree")

                Divider()
                    .frame(height: 14)
            }

            // The tab in the title row names the file; this row says what it is and acts on it.
            Text(metadata.formattedSubtitle)
                .font(.caption)
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(1)
                .help(metadata.filename)

            Spacer(minLength: AppSpacing.small)

            if let showsSource {
                Button {
                    showsSource.wrappedValue.toggle()
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                        .foregroundStyle(showsSource.wrappedValue ? Color.accentColor : AppColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(showsSource.wrappedValue ? "Show Preview" : "Show Source")
                .accessibilityLabel(showsSource.wrappedValue ? "Show Preview" : "Show Source")
            }

            if let onOpenInBrowser {
                Button {
                    onOpenInBrowser()
                } label: {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
                .help("Open in Browser (runs scripts and can read the file's folder)")
                .accessibilityLabel("Open in Browser")
                .accessibilityIdentifier("files.preview.openInBrowser")
            }

            // Refresh
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Refresh File")
            .accessibilityLabel("Refresh File")

            // Open in Default App
            Button {
                window.files.openInDefaultApp(url: metadata.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Open in Default App")
            .accessibilityLabel("Open in Default App")

            // Reveal in Finder
            Button {
                window.files.revealInFinder(url: metadata.url)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")

            // Toggle File Tree
            Button {
                withAnimation(AppMotion.resolved(AppMotion.layout)) {
                    if storedTreeWidth <= 20 {
                        storedTreeWidth = Double(AppLayout.filesTreeIdealWidth)
                    } else {
                        storedTreeWidth = 0.0
                    }
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                    .foregroundStyle(storedTreeWidth > 20 ? Color.accentColor : AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(storedTreeWidth > 20 ? "Collapse File Tree" : "Show File Tree")
            .accessibilityLabel(storedTreeWidth > 20 ? "Collapse File Tree" : "Show File Tree")
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.xSmall)
    }
}

// MARK: - Markdown Preview View (Preview + Source)

public enum MarkdownPreviewSegment: Equatable, Sendable {
    case markdown(String)
    case image(alt: String, source: String)
}

public enum MarkdownPreviewSegmentSplitter {
    /// Splits Markdown into prose segments and standalone image lines (`![alt](url)` or `<img ...>`)
    /// while leaving fenced code blocks untouched.
    public static func split(_ source: String) -> [MarkdownPreviewSegment] {
        let lines = source.components(separatedBy: .newlines)
        var segments: [MarkdownPreviewSegment] = []
        var markdownBuffer: [String] = []
        var activeFenceChar: Character?
        var activeFenceLength = 0

        func flushMarkdown() {
            guard !markdownBuffer.isEmpty else { return }
            let joined = markdownBuffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(joined))
            }
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = parseFence(trimmed) {
                if let current = activeFenceChar {
                    if fence.char == current && fence.length >= activeFenceLength && fence.infoIsEmpty {
                        activeFenceChar = nil
                        activeFenceLength = 0
                    }
                } else {
                    activeFenceChar = fence.char
                    activeFenceLength = fence.length
                }
                markdownBuffer.append(line)
                continue
            }

            if activeFenceChar == nil, let image = parseStandaloneImageLine(trimmed) {
                flushMarkdown()
                segments.append(.image(alt: image.alt, source: image.source))
                continue
            }

            markdownBuffer.append(line)
        }

        flushMarkdown()
        return segments
    }

    /// Resolves a Markdown image source to an existing local file URL relative to `documentURL`.
    /// Returns `nil` for remote HTTP(S) URLs (passive preview never fetches network assets) or missing files.
    public static func resolveLocalImageURL(source: String, documentURL: URL?) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") {
            return nil
        }

        let fm = FileManager.default
        if lower.hasPrefix("file://"), let parsed = URL(string: trimmed), parsed.isFileURL {
            if fm.fileExists(atPath: parsed.path) { return parsed }
            return nil
        }

        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        let candidatesRaw = unescaped == trimmed ? [trimmed] : [trimmed, unescaped]
        let baseDir = documentURL?.deletingLastPathComponent()

        for candidate in candidatesRaw {
            if candidate.hasPrefix("~/") {
                let expanded = (candidate as NSString).expandingTildeInPath
                if fm.fileExists(atPath: expanded) {
                    return URL(fileURLWithPath: expanded)
                }
            } else if candidate.hasPrefix("/") {
                if fm.fileExists(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            } else if let baseDir {
                let resolved = baseDir.appendingPathComponent(candidate).standardizedFileURL
                if fm.fileExists(atPath: resolved.path) {
                    return resolved
                }
            }
        }
        return nil
    }

    private static func parseFence(_ trimmedLine: String) -> (char: Character, length: Int, infoIsEmpty: Bool)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        var count = 0
        for ch in trimmedLine {
            if ch == first { count += 1 } else { break }
        }
        guard count >= 3 else { return nil }
        let rest = trimmedLine.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return (first, count, rest.isEmpty)
    }

    private static func parseStandaloneImageLine(_ trimmed: String) -> (alt: String, source: String)? {
        if trimmed.hasPrefix("![") {
            return parseMarkdownImage(trimmed)
        }
        if trimmed.lowercased().hasPrefix("<img") {
            return parseHTMLImage(trimmed)
        }
        return nil
    }

    private static func parseMarkdownImage(_ trimmed: String) -> (alt: String, source: String)? {
        // Scan `![alt](destination "title")` allowing balanced brackets in alt and parentheses in path.
        var idx = trimmed.index(trimmed.startIndex, offsetBy: 2)
        var bracketDepth = 1
        var altEnd: String.Index?
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if ch == "\\", trimmed.index(after: idx) < trimmed.endIndex {
                idx = trimmed.index(idx, offsetBy: 2)
                continue
            }
            if ch == "[" {
                bracketDepth += 1
            } else if ch == "]" {
                bracketDepth -= 1
                if bracketDepth == 0 {
                    altEnd = idx
                    break
                }
            }
            idx = trimmed.index(after: idx)
        }
        guard let altEnd else { return nil }
        let afterBracket = trimmed.index(after: altEnd)
        guard afterBracket < trimmed.endIndex, trimmed[afterBracket] == "(" else { return nil }

        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
        var destIdx = trimmed.index(after: afterBracket)
        var parenDepth = 1
        var destEnd: String.Index?
        while destIdx < trimmed.endIndex {
            let ch = trimmed[destIdx]
            if ch == "\\", trimmed.index(after: destIdx) < trimmed.endIndex {
                destIdx = trimmed.index(destIdx, offsetBy: 2)
                continue
            }
            if ch == "(" {
                parenDepth += 1
            } else if ch == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    destEnd = destIdx
                    break
                }
            }
            destIdx = trimmed.index(after: destIdx)
        }
        guard let destEnd else { return nil }
        let trailing = trimmed[trimmed.index(after: destEnd)...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty else { return nil }

        var inside = trimmed[trimmed.index(after: afterBracket)..<destEnd].trimmingCharacters(in: .whitespaces)
        if inside.hasPrefix("<"), let close = inside.firstIndex(of: ">") {
            let path = String(inside[inside.index(after: inside.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : (alt, path)
        }

        // Strip optional trailing title `"..."` or `'...'`
        if let quoteRange = inside.range(of: #"\s+(?:"[^"]*"|'[^']*')\s*$"#, options: .regularExpression) {
            inside = String(inside[..<quoteRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return inside.isEmpty ? nil : (alt, String(inside))
    }

    private static func parseHTMLImage(_ trimmed: String) -> (alt: String, source: String)? {
        guard trimmed.hasSuffix(">") else { return nil }
        let srcPattern = #"(?i)\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#
        guard let srcRegex = try? NSRegularExpression(pattern: srcPattern),
              let match = srcRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return nil
        }
        var src: String?
        for group in 1...3 {
            let r = match.range(at: group)
            if r.location != NSNotFound, let range = Range(r, in: trimmed) {
                src = String(trimmed[range])
                break
            }
        }
        guard let src, !src.isEmpty else { return nil }

        var alt = ""
        let altPattern = #"(?i)\balt\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        if let altRegex = try? NSRegularExpression(pattern: altPattern),
           let altMatch = altRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            for group in 1...2 {
                let r = altMatch.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: trimmed) {
                    alt = String(trimmed[range])
                    break
                }
            }
        }
        return (alt, src)
    }
}

public struct MarkdownFilePreviewView: View {
    let source: String
    let fileURL: URL?
    /// The source instead of the rendering; switched from the preview toolbar.
    let showsSource: Bool

    public init(source: String, fileURL: URL? = nil, showsSource: Bool = false) {
        self.source = source
        self.fileURL = fileURL
        self.showsSource = showsSource
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsSource {
                CodeFilePreviewView(code: source, language: "Markdown", wrapsLines: true)
            } else {
                // A document's margins, and a fade where lines leave the bottom of the sheet
                // rather than a cut across them; the bottom margin lets the last line rest clear.
                let segments = MarkdownPreviewSegmentSplitter.split(source)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AppSpacing.medium) {
                        if segments.isEmpty {
                            LimareMarkdownView(source: source, profile: .document)
                        } else {
                            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                switch segment {
                                case .markdown(let text):
                                    LimareMarkdownView(source: text, profile: .document)
                                case .image(let alt, let imageSource):
                                    MarkdownEmbeddedImageView(
                                        alt: alt,
                                        source: imageSource,
                                        documentURL: fileURL
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, AppSpacing.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .mask(
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: AppSpacing.standard)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}

private struct MarkdownEmbeddedImageView: View {
    @Environment(WindowSession.self) private var window
    @Environment(\.openURL) private var openURL
    let alt: String
    let source: String
    let documentURL: URL?

    var body: some View {
        if let resolvedURL = MarkdownPreviewSegmentSplitter.resolveLocalImageURL(source: source, documentURL: documentURL),
           let data = try? Data(contentsOf: resolvedURL) {
            let isSVG = resolvedURL.pathExtension.lowercased() == "svg"
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                if isSVG {
                    IsolatedSVGWebView(svgData: data, fileURL: resolvedURL)
                        .frame(maxWidth: .infinity)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                .strokeBorder(AppColors.hairline, lineWidth: 1)
                        )
                } else if let nsImage = NSImage(data: data),
                          let ratio = Self.aspectRatio(for: nsImage) {
                    AnimatedImageRepresentable(fileURL: resolvedURL, data: data, image: nsImage)
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 560, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                .strokeBorder(AppColors.hairline, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            window.previewExternalFile(resolvedURL)
                        }
                        .help("Open \(resolvedURL.lastPathComponent)")
                } else {
                    fallbackBadge(label: alt.isEmpty ? resolvedURL.lastPathComponent : alt, remoteURL: nil)
                }

                if !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(alt)
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.vertical, AppSpacing.xxSmall)
        } else {
            let remoteURL: URL? = {
                guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { return nil }
                return url
            }()
            let label = alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (URL(string: source)?.lastPathComponent.nilIfEmpty ?? source)
                : alt
            fallbackBadge(label: label, remoteURL: remoteURL)
        }
    }

    @ViewBuilder
    private func fallbackBadge(label: String, remoteURL: URL?) -> some View {
        let pill = HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "photo")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.textSecondary)
            Text(label)
                .font(AppTypography.interfaceCaption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .fill(AppColors.surfaceSecondary.opacity(0.6))
        )

        if let remoteURL {
            Button { openURL(remoteURL) } label: { pill }
                .buttonStyle(.plain)
        } else {
            pill
        }
    }

    private static func aspectRatio(for image: NSImage) -> CGFloat? {
        for rep in image.representations {
            if rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                return CGFloat(rep.pixelsWide) / CGFloat(rep.pixelsHigh)
            }
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image.size.width / image.size.height
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct AnimatedImageRepresentable: NSViewRepresentable {
    let fileURL: URL
    let data: Data
    let image: NSImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.canDrawSubviewsIntoLayer = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        apply(to: imageView, coordinator: context.coordinator)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    private func apply(to imageView: NSImageView, coordinator: Coordinator) {
        // Avoid re-setting image on unchanged SwiftUI updates so animated GIF playback does not reset to frame 0.
        if coordinator.lastURL == fileURL && coordinator.lastDataCount == data.count {
            return
        }
        coordinator.lastURL = fileURL
        coordinator.lastDataCount = data.count
        imageView.animates = true
        imageView.image = image
    }

    final class Coordinator {
        var lastURL: URL?
        var lastDataCount: Int = 0
    }
}

// MARK: - Read-Only NSTextView Wrapper for Code and Plain Text

public struct ReadOnlyTextViewRepresentable: NSViewRepresentable {
    let text: String
    let isMonospaced: Bool

    public init(text: String, isMonospaced: Bool = true) {
        self.text = text
        self.isMonospaced = isMonospaced
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.textContainer?.widthTracksTextView = !isMonospaced
        textView.textContainer?.containerSize = isMonospaced ? NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) : NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = isMonospaced
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]

        if isMonospaced {
            textView.font = AppTypography.codeNSFont
        } else {
            textView.font = AppTypography.interfaceNSFont
        }
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let textView = scrollView.documentView as? NSTextView {
            let expectedFont = isMonospaced ? AppTypography.codeNSFont : AppTypography.interfaceNSFont
            if textView.font != expectedFont {
                textView.font = expectedFont
            }
            if textView.string != text {
                textView.string = text
            }
        }
    }
}

// MARK: - Plain Text & Code Preview Views

public struct TextFilePreviewView: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        ReadOnlyTextViewRepresentable(text: text, isMonospaced: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.workSurface)
    }
}

public struct CodeFilePreviewView: View {
    let code: String
    let language: String
    /// Prose sources (Markdown) wrap; code keeps its lines and scrolls sideways.
    let wrapsLines: Bool

    public init(code: String, language: String, wrapsLines: Bool = false) {
        self.code = code
        self.language = language
        self.wrapsLines = wrapsLines
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AppColors.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))

                Spacer()
            }
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.xSmall)
            .background(AppColors.surfaceSecondary.opacity(0.3))

            Divider()

            CodePreviewTextView(code: code, language: language, wrapsLines: wrapsLines)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.workSurface)
    }
}

// MARK: - Image Preview View (Raster + SVG)

public struct ImageFilePreviewView: View {
    let data: Data
    let isSVG: Bool
    let fileURL: URL

    public init(data: Data, isSVG: Bool, fileURL: URL) {
        self.data = data
        self.isSVG = isSVG
        self.fileURL = fileURL
    }

    public var body: some View {
        Group {
            if isSVG {
                IsolatedSVGWebView(svgData: data, fileURL: fileURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let nsImage = NSImage(data: data) {
                NativeZoomableImageView(image: nsImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: AppSpacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(AppColors.statusError)
                    Text("Unable to display image")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.surfaceSecondary.opacity(0.3))
    }
}

// MARK: - Native Zoomable Image Preview (AppKit NSScrollView with Hardware Pinch & Pan)

public struct NativeZoomableImageView: NSViewRepresentable {
    let image: NSImage

    public init(image: NSImage) {
        self.image = image
    }

    public func makeNSView(context: Context) -> ImageZoomScrollView {
        let scrollView = ImageZoomScrollView()
        scrollView.setImage(image)
        return scrollView
    }

    public func updateNSView(_ scrollView: ImageZoomScrollView, context: Context) {
        scrollView.setImage(image)
    }
}

public final class ImageZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var currentImage: NSImage?
    private var lastBoundsSize: NSSize = .zero

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        self.wantsLayer = true
        let centeringClip = CenteringClipView()
        self.contentView = centeringClip

        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = AppRadius.card
        imageView.layer?.masksToBounds = true
        self.documentView = imageView

        self.allowsMagnification = true
        self.minMagnification = 1.0
        self.maxMagnification = 10.0
        self.hasHorizontalScroller = false
        self.hasVerticalScroller = false
        self.autohidesScrollers = true
        self.drawsBackground = false
        self.backgroundColor = .clear

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        self.addGestureRecognizer(doubleClick)
    }

    public func setImage(_ image: NSImage) {
        guard currentImage !== image else { return }
        currentImage = image
        imageView.image = image
        // Transparent areas sit on a checkerboard, the usual sign for "nothing here", so dark
        // artwork stays visible on the dark panel and light artwork on the light one. An opaque
        // image covers it entirely.
        let hasAlpha = image.representations.contains { $0.hasAlpha }
        imageView.layer?.backgroundColor = hasAlpha ? Self.checkerboard.cgColor : NSColor.clear.cgColor
        fitImageToViewport()
    }

    private static let checkerboard: NSColor = {
        let cell: CGFloat = 8
        let tile = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell, height: cell).fill()
            NSRect(x: cell, y: cell, width: cell, height: cell).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    public override func layout() {
        super.layout()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            if magnification <= 1.02 {
                fitImageToViewport()
            }
        }
    }

    private func fitImageToViewport() {
        guard let img = currentImage else { return }
        let container = bounds.size
        guard container.width > 30, container.height > 30 else { return }

        let padding: CGFloat = 24.0
        let availW = max(container.width - padding, 20)
        let availH = max(container.height - padding, 20)

        let imgW = max(img.size.width, 1)
        let imgH = max(img.size.height, 1)
        let ratio = min(availW / imgW, availH / imgH)

        let fittedW = imgW * ratio
        let fittedH = imgH * ratio

        imageView.frame = NSRect(x: 0, y: 0, width: fittedW, height: fittedH)
        setMagnification(1.0, centeredAt: NSPoint(x: fittedW / 2, y: fittedH / 2))
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let location = gesture.location(in: contentView)
        if magnification > 1.05 {
            animator().setMagnification(1.0, centeredAt: location)
        } else {
            animator().setMagnification(2.5, centeredAt: location)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = (event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 5) * 0.02
            let newMag = min(max(magnification + delta, minMagnification), maxMagnification)
            let mouseLoc = contentView.convert(event.locationInWindow, from: nil)
            setMagnification(newMag, centeredAt: mouseLoc)
            return
        }
        super.scrollWheel(with: event)
    }
}

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }

        if proposedBounds.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - proposedBounds.width) / 2
        }
        if proposedBounds.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - proposedBounds.height) / 2
        }
        return rect
    }
}

private struct IsolatedSVGWebView: View {
    let svgData: Data
    let fileURL: URL
    @State private var sandbox = PassivePreviewSandbox.shared

    var body: some View {
        if let config = sandbox.makeConfiguration() {
            RepresentableIsolatedSVGWebView(svgData: svgData, fileURL: fileURL, configuration: config)
        } else if sandbox.compilationFailed {
            VStack(spacing: AppSpacing.small) {
                Image(systemName: "exclamationmark.shield")
                    .font(.title2)
                    .foregroundStyle(AppColors.statusError)
                Text("Security rule compilation failed.")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: AppSpacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing secure preview...")
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                await sandbox.ensureCompiled()
            }
        }
    }
}

private struct RepresentableIsolatedSVGWebView: NSViewRepresentable {
    let svgData: Data
    let fileURL: URL
    let configuration: WKWebViewConfiguration

    func makeCoordinator() -> PassiveNavigationDelegate {
        PassiveNavigationDelegate()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(svgData, mimeType: "image/svg+xml", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}

// MARK: - PDF Preview View

public struct PDFFilePreviewView: View {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var body: some View {
        PDFKitViewRepresentable(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.workSurface)
    }
}

private struct PDFKitViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
        }
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            pdfView.document = PDFDocument(url: url)
        }
    }
}

// MARK: - HTML Preview View (Preview + Source)

public struct HTMLFilePreviewView: View {
    let source: String
    let fileURL: URL
    /// The source instead of the rendered page; switched from the preview toolbar.
    let showsSource: Bool

    public init(source: String, fileURL: URL, showsSource: Bool = false) {
        self.source = source
        self.fileURL = fileURL
        self.showsSource = showsSource
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsSource {
                CodeFilePreviewView(code: source, language: "HTML")
            } else {
                IsolatedHTMLWebView(fileURL: fileURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}

private struct IsolatedHTMLWebView: View {
    let fileURL: URL
    @State private var sandbox = PassivePreviewSandbox.shared

    var body: some View {
        if let config = sandbox.makeConfiguration() {
            RepresentableIsolatedHTMLWebView(fileURL: fileURL, configuration: config)
        } else if sandbox.compilationFailed {
            VStack(spacing: AppSpacing.small) {
                Image(systemName: "exclamationmark.shield")
                    .font(.title2)
                    .foregroundStyle(AppColors.statusError)
                Text("Security rule compilation failed.")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: AppSpacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing secure preview...")
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                await sandbox.ensureCompiled()
            }
        }
    }
}

private struct RepresentableIsolatedHTMLWebView: NSViewRepresentable {
    let fileURL: URL
    let configuration: WKWebViewConfiguration

    func makeCoordinator() -> PassiveNavigationDelegate {
        PassiveNavigationDelegate()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        let accessDir = fileURL.deletingLastPathComponent()
        webView.loadFileURL(fileURL, allowingReadAccessTo: accessDir)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != fileURL {
            let accessDir = fileURL.deletingLastPathComponent()
            webView.loadFileURL(fileURL, allowingReadAccessTo: accessDir)
        }
    }
}

// MARK: - Fallback, Size & Error Views

public struct UnsupportedFilePreviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let metadata: FileMetadata

    public init(metadata: FileMetadata) {
        self.metadata = metadata
    }

    public var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Spacer()

            Image(systemName: "doc")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textMuted)

            VStack(spacing: AppSpacing.xxSmall) {
                Text(metadata.filename)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)

                Text(metadata.formattedSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)

                Text("Preview isn’t available for this file type.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, AppSpacing.xSmall)
            }

            HStack(spacing: AppSpacing.small) {
                Button("Open in Default App") {
                    window.files.openInDefaultApp(url: metadata.url)
                }
                .buttonStyle(.borderedProminent)

                Button("Reveal in Finder") {
                    window.files.revealInFinder(url: metadata.url)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, AppSpacing.small)

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}

public struct TooLargeFilePreviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let metadata: FileMetadata

    public init(metadata: FileMetadata) {
        self.metadata = metadata
    }

    public var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Spacer()

            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textMuted)

            VStack(spacing: AppSpacing.xxSmall) {
                Text(metadata.filename)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)

                Text(metadata.formattedSubtitle)
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)

                Text("File is too large to preview.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, AppSpacing.xSmall)
            }

            HStack(spacing: AppSpacing.small) {
                Button("Open in Default App") {
                    window.files.openInDefaultApp(url: metadata.url)
                }
                .buttonStyle(.borderedProminent)

                Button("Reveal in Finder") {
                    window.files.revealInFinder(url: metadata.url)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, AppSpacing.small)

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}

public struct EmptyFilePreviewView: View {
    let metadata: FileMetadata

    public init(metadata: FileMetadata) {
        self.metadata = metadata
    }

    public var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Spacer()

            Image(systemName: "doc")
                .font(.system(size: 40))
                .foregroundStyle(AppColors.textMuted)

            VStack(spacing: AppSpacing.xxSmall) {
                Text(metadata.filename)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)

                Text("0 bytes • Empty file")
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}

public struct ErrorFilePreviewView: View {
    let message: String

    public init(message: String) {
        self.message = message
    }

    public var body: some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()

            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.statusError)

            Text("Preview Unavailable")
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.workSurface)
    }
}
