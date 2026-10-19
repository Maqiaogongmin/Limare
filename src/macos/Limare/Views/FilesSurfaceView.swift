import SwiftUI

/// Main Files Work Surface view combining Workspace File Tree and P0 File Preview.
/// Supports adaptive layout across the 320pt to 700pt width spectrum with user-adjustable split.
public struct FilesSurfaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.worksurface.files.treeWidth") private var storedTreeWidth: Double = Double(AppLayout.filesTreeIdealWidth)

    let previewStore: FilesSurfaceStore?
    /// Markdown and HTML show their source instead of the rendering; set from the preview toolbar.
    @State private var showsSource = false
    /// The user has read, once, what opening an HTML file in the browser allows.
    @AppStorage("limare.files.htmlBrowserConsent") private var htmlBrowserConsent = false
    @State private var pendingBrowserExit: URL?

    init(previewStore: FilesSurfaceStore? = nil) { self.previewStore = previewStore }

    private var files: FilesSurfaceStore { previewStore ?? window.files }

    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let isNarrow = totalWidth < 420

            if !files.hasActivePreview {
                // Nothing chosen yet: the tree is the content.
                FilesTreeView(files: files)
            } else if isNarrow {
                // Narrow width: the preview fills the tab; Back goes to the tree in a Files tab
                // and leaves this file open in its own.
                previewContentView(onBack: {
                    window.addSurface(.files)
                })
            } else {
                // Wide width (>= 420pt): Adjustable Split View [ Preview (Col 3) | Draggable Divider | Tree (Col 4) ]
                let minTree: Double = 0.0
                let minPreview = Double(AppLayout.filesPreviewMinimumWidth)
                let maxTree = max(minTree, Double(totalWidth) - minPreview)
                let treeWidth = Self.treeWidth(stored: storedTreeWidth, maxWidth: maxTree)

                HStack(spacing: 0) {
                    // Column 3: Document Preview (Can expand to 100% when File Tree is pushed away)
                    previewContentView(onBack: nil)

                    // The divider stays when the tree is collapsed, so it can be dragged back out.
                    DraggableSplitDivider(
                        splitWidth: $storedTreeWidth,
                        minWidth: minTree,
                        maxWidth: maxTree,
                        invertDrag: true,
                        snapToZeroThreshold: 60.0
                    )

                    // Column 4: Workspace File Tree (Right Side)
                    if treeWidth > 0 {
                        FilesTreeView(files: files)
                            .frame(width: CGFloat(treeWidth))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "在浏览器中打开？",
            isPresented: Binding(get: { pendingBrowserExit != nil },
                                 set: { if !$0 { pendingBrowserExit = nil } }),
            titleVisibility: .visible
        ) {
            Button("继续") {
                if let url = pendingBrowserExit { appState.openLocalFileInBrowserTab(url) }
                pendingBrowserExit = nil
                htmlBrowserConsent = true
            }
            Button("取消", role: .cancel) { pendingBrowserExit = nil }
        } message: {
            Text("这会在 Limare 的浏览器里加载该文件：页面脚本会运行，并可读取该文件所在的文件夹。被动预览不会这样做。")
        }
    }

    /// The width the file tree gets beside a preview; a collapsed tree gives its room to it.
    static func treeWidth(stored: Double, maxWidth: Double) -> Double {
        stored <= 20.0 ? 0.0 : min(maxWidth, max(120.0, stored))
    }

    /// The one rule in the preview's head: a hairline under its toolbar.
    private var previewToolbarRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    @ViewBuilder
    private func previewContentView(onBack: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            switch files.previewState {
            case .idle:
                noFileSelectedView

            case .loading(let url):
                ProgressView("Loading \(url.lastPathComponent)…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let previewData):
                let htmlURL: URL? = {
                    if case .html(_, let url) = previewData.content { return url } else { return nil }
                }()
                FilePreviewToolbar(
                    metadata: previewData.metadata,
                    onBack: onBack,
                    onRefresh: files.refresh,
                    showsSource: previewData.content.hasSource ? $showsSource : nil,
                    onOpenInBrowser: htmlURL.map { url in { openInBrowser(url) } }
                )
                previewToolbarRule

                switch previewData.content {
                case .markdown(let src):
                    MarkdownFilePreviewView(source: src, showsSource: showsSource)
                case .text(let txt):
                    TextFilePreviewView(text: txt)
                case .code(let code, let lang):
                    CodeFilePreviewView(code: code, language: lang)
                case .image(let data, let isSVG):
                    ImageFilePreviewView(data: data, isSVG: isSVG, fileURL: previewData.metadata.url)
                case .pdf(let url):
                    PDFFilePreviewView(url: url)
                case .html(let src, let url):
                    HTMLFilePreviewView(source: src, fileURL: url, showsSource: showsSource)
                }

            case .emptyFile(let metadata):
                FilePreviewToolbar(metadata: metadata, onBack: onBack, onRefresh: files.refresh)
                previewToolbarRule
                EmptyFilePreviewView(metadata: metadata)

            case .tooLarge(let metadata):
                FilePreviewToolbar(metadata: metadata, onBack: onBack, onRefresh: files.refresh)
                previewToolbarRule
                TooLargeFilePreviewView(metadata: metadata)

            case .unsupported(let metadata):
                FilePreviewToolbar(metadata: metadata, onBack: onBack, onRefresh: files.refresh)
                previewToolbarRule
                UnsupportedFilePreviewView(metadata: metadata)

            case .error(let message):
                ErrorFilePreviewView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openInBrowser(_ url: URL) {
        if htmlBrowserConsent {
            appState.openLocalFileInBrowserTab(url)
        } else {
            pendingBrowserExit = url
        }
    }

    private var noFileSelectedView: some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(AppColors.textMuted)
            Text("Select a file to preview")
                .font(.subheadline)
                .foregroundStyle(AppColors.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Interactive vertical divider with macOS horizontal resize cursor and drag gesture support.
/// The line lights up while the pointer is on it, so the edge shows it can be dragged.
public struct DraggableSplitDivider: View {
    @Binding var splitWidth: Double
    let minWidth: Double
    let maxWidth: Double
    var invertDrag: Bool = false
    var snapToZeroThreshold: Double = 0.0

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragStartWidth: Double = 0

    public init(
        splitWidth: Binding<Double>,
        minWidth: Double,
        maxWidth: Double,
        invertDrag: Bool = false,
        snapToZeroThreshold: Double = 0.0
    ) {
        self._splitWidth = splitWidth
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.invertDrag = invertDrag
        self.snapToZeroThreshold = snapToZeroThreshold
    }

    public var body: some View {
        let isActive = isHovering || isDragging
        ZStack {
            Rectangle()
                .fill(isActive ? Color.accentColor.opacity(0.7) : AppColors.separator)
                .frame(width: isActive ? 2 : 1)
                .animation(AppMotion.resolved(AppMotion.quickOut), value: isActive)

            // Transparent hit target for easy grabbing (8px)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
        }
        .frame(width: 8)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else if !isDragging {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = splitWidth
                    }
                    let delta = Double(value.translation.width) * (invertDrag ? -1.0 : 1.0)
                    var newWidth = dragStartWidth + delta
                    if snapToZeroThreshold > 0 && newWidth < snapToZeroThreshold {
                        newWidth = 0.0
                    }
                    splitWidth = min(maxWidth, max(minWidth, newWidth))
                }
                .onEnded { _ in
                    isDragging = false
                    if !isHovering {
                        NSCursor.pop()
                    }
                }
        )
        .onDisappear {
            if isHovering || isDragging {
                NSCursor.pop()
            }
        }
    }
}
