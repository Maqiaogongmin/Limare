import SwiftUI
import AppKit
import WebKit
import PDFKit

// MARK: - Document Toolbar

public struct FilePreviewToolbar: View {
    @Environment(AppState.self) private var appState
    @AppStorage("limare.worksurface.files.treeWidth") private var storedTreeWidth: Double = Double(AppLayout.filesTreeIdealWidth)
    let metadata: FileMetadata
    let onBack: (() -> Void)?
    /// Reloads the store this preview belongs to (a file's own tab, or the Files navigator).
    let onRefresh: () -> Void
    /// Shows the file's source instead of its rendering; nil for files with only one view.
    let showsSource: Binding<Bool>?

    public init(
        metadata: FileMetadata,
        onBack: (() -> Void)? = nil,
        onRefresh: @escaping () -> Void,
        showsSource: Binding<Bool>? = nil
    ) {
        self.metadata = metadata
        self.onBack = onBack
        self.onRefresh = onRefresh
        self.showsSource = showsSource
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
                        .frame(width: 20, height: 20)
                        .foregroundStyle(showsSource.wrappedValue ? Color.accentColor : AppColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(showsSource.wrappedValue ? "Show Preview" : "Show Source")
                .accessibilityLabel(showsSource.wrappedValue ? "Show Preview" : "Show Source")
            }

            // Refresh
            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Refresh File")

            // Open in Default App
            Button {
                appState.files.openInDefaultApp(url: metadata.url)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Open in Default App")

            // Reveal in Finder
            Button {
                appState.files.revealInFinder(url: metadata.url)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Reveal in Finder")

            // Toggle File Tree
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if storedTreeWidth <= 20 {
                        storedTreeWidth = Double(AppLayout.filesTreeIdealWidth)
                    } else {
                        storedTreeWidth = 0.0
                    }
                }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(storedTreeWidth > 20 ? Color.accentColor : AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help(storedTreeWidth > 20 ? "Collapse File Tree" : "Show File Tree")
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.xSmall)
    }
}

// MARK: - Markdown Preview View (Preview + Source)

public struct MarkdownFilePreviewView: View {
    let source: String
    /// The source instead of the rendering; switched from the preview toolbar.
    let showsSource: Bool

    public init(source: String, showsSource: Bool = false) {
        self.source = source
        self.showsSource = showsSource
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsSource {
                CodeFilePreviewView(code: source, language: "Markdown")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AppSpacing.medium) {
                        LimareMarkdownView(source: source, profile: .document)
                    }
                    .padding(AppSpacing.standard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.surfacePrimary)
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
            .background(AppColors.surfacePrimary)
    }
}

public struct CodeFilePreviewView: View {
    let code: String
    let language: String

    public init(code: String, language: String) {
        self.code = code
        self.language = language
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

            ReadOnlyTextViewRepresentable(text: code, isMonospaced: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppColors.surfacePrimary)
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
        fitImageToViewport()
    }

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
            .background(AppColors.surfacePrimary)
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
        .background(AppColors.surfacePrimary)
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
                    appState.files.openInDefaultApp(url: metadata.url)
                }
                .buttonStyle(.borderedProminent)

                Button("Reveal in Finder") {
                    appState.files.revealInFinder(url: metadata.url)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, AppSpacing.small)

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.surfacePrimary)
    }
}

public struct TooLargeFilePreviewView: View {
    @Environment(AppState.self) private var appState
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
                    appState.files.openInDefaultApp(url: metadata.url)
                }
                .buttonStyle(.borderedProminent)

                Button("Reveal in Finder") {
                    appState.files.revealInFinder(url: metadata.url)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, AppSpacing.small)

            Spacer()
        }
        .padding(AppSpacing.standard)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.surfacePrimary)
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
        .background(AppColors.surfacePrimary)
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
        .background(AppColors.surfacePrimary)
    }
}
