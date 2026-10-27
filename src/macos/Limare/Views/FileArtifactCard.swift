import SwiftUI

/// Reusable first-class document card for presenting file artifacts and chat attachments.
/// Provides consistent visual grammar, hover state, file metadata, and one-click preview.
public struct FileArtifactCard: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var isHovered: Bool = false

    private let filename: String
    private let subtitle: String
    private let iconSystemName: String
    private let target: Target

    /// What the card previews when clicked.
    private enum Target {
        case workspaceFile(URL)
        case attachment(ChatAttachment, AttachmentStore)
        case artifact(id: UUID, conversationID: UUID, store: ArtifactStore)
    }

    /// Initializes a FileArtifactCard for a local workspace file.
    public init(fileURL: URL, displayName: String? = nil) {
        let name = displayName ?? fileURL.lastPathComponent
        let sizeBytes: Int64? = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
            return (attrs[.size] as? Int64) ?? (attrs[.size] as? NSNumber)?.int64Value
        }()
        self.init(filename: name, byteCount: sizeBytes, target: .workspaceFile(fileURL))
    }

    /// Initializes a FileArtifactCard for a ChatAttachment.
    public init(attachment: ChatAttachment, attachmentStore: AttachmentStore) {
        self.init(
            filename: attachment.filename,
            byteCount: Int64(attachment.byteCount),
            target: .attachment(attachment, attachmentStore)
        )
    }

    /// Initializes a FileArtifactCard for a file a tool registered or produced in a conversation.
    public init(artifact descriptor: ArtifactDescriptor, artifactStore: ArtifactStore) {
        self.init(
            filename: descriptor.filename,
            byteCount: descriptor.byteCount,
            target: .artifact(id: descriptor.artifactID, conversationID: descriptor.conversationID, store: artifactStore)
        )
    }

    private init(filename: String, byteCount: Int64?, target: Target) {
        self.filename = filename
        self.target = target
        let ext = (filename as NSString).pathExtension.lowercased()
        let kind = FilePreviewClassifier.classify(url: URL(fileURLWithPath: filename))

        let typeName: String
        switch kind {
        case .markdown:
            typeName = "Markdown"
        case .code(let lang):
            typeName = lang.isEmpty ? String(localized: "Code") : lang.capitalized
        case .text:
            typeName = ext.isEmpty ? String(localized: "Plain Text") : ext.uppercased()
        case .html:
            typeName = "HTML"
        case .image:
            typeName = ext == "svg" ? "SVG" : (ext.isEmpty ? "Image" : "\(ext.uppercased()) Image")
        case .pdf:
            typeName = "PDF"
        case .unsupported:
            typeName = ext.isEmpty ? String(localized: "File") : String(localized: "\(ext.uppercased()) File")
        }

        if let size = byteCount, size > 0 {
            let formattedSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            self.subtitle = "\(typeName) · \(formattedSize)"
        } else if byteCount == 0 {
            self.subtitle = "\(typeName) · 0 KB"
        } else {
            self.subtitle = typeName
        }

        switch kind {
        case .markdown:
            self.iconSystemName = "doc.text"
        case .code:
            self.iconSystemName = "chevron.left.forwardslash.chevron.right"
        case .text:
            self.iconSystemName = "doc.text"
        case .html:
            self.iconSystemName = "globe"
        case .image:
            self.iconSystemName = "photo"
        case .pdf:
            self.iconSystemName = "doc.richtext"
        case .unsupported:
            self.iconSystemName = "doc"
        }
    }

    public var body: some View {
        Button {
            // Previewed in Files when Limare can, otherwise the default app (see FileOpening).
            switch target {
            case .workspaceFile(let url):
                FileOpening.open(url) { window.previewWorkspaceFile(url) }
            case .attachment(let attachment, let store):
                guard let url = try? store.fileURL(for: attachment) else { return }
                FileOpening.open(url) { window.previewAttachment(attachment) }
            case .artifact(let id, let conversationID, let store):
                if let source = window.workspaceSource(ofArtifact: id, conversationID: conversationID) {
                    FileOpening.open(source) { window.previewWorkspaceFile(source) }
                    return
                }
                guard let url = try? store.resolveFileURL(artifactID: id, conversationID: conversationID) else { return }
                FileOpening.open(url) { window.previewArtifact(id: id, conversationID: conversationID) }
            }
        } label: {
            let shape = RoundedRectangle(cornerRadius: AppRadius.fileCard, style: .continuous)
            HStack(spacing: AppSpacing.small + 2) {
                Image(systemName: iconSystemName)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.70))
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.fileIconTile, style: .continuous)
                            .fill(Color.primary.opacity(0.045))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(filename)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: AppSpacing.small)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textMuted.opacity(0.6))
            }
            .padding(.leading, AppSpacing.small)
            .padding(.trailing, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            // Compact wherever it sits: a file is a card, not a row across the column.
            .frame(minWidth: AppLayout.fileCardMinimumWidth, maxWidth: AppLayout.fileCardMaximumWidth, alignment: .leading)
            .background(shape.fill(AppColors.fileCard))
            .overlay(shape.fill(isHovered ? AppColors.pillHover : .clear))
            .overlay(shape.stroke(AppColors.cardStroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppMotion.resolved(AppMotion.quick)) {
                isHovered = hovering
            }
        }
    }
}
