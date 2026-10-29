import SwiftUI

/// One file's unified diff with old and new line numbers. A line number opens a comment on that
/// line; saved comments sit under their lines.
struct GitDiffView: View {
    let store: GitReviewStore
    let file: GitChangedFile
    let onBack: (() -> Void)?
    let onOpenInFiles: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var patch: GitReviewStore.PatchState? {
        store.patch?.path == file.path ? store.patch : nil
    }

    private var header: some View {
        HStack(spacing: AppSpacing.xSmall) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(GhostIconButtonStyle(size: 22, iconSize: 11))
                .accessibilityLabel("Back to the file list")
                .help("Back to the file list")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path)
                    .font(AppTypography.interfaceMedium)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.path)
                if let readAt = patch?.readAt {
                    Text("Read at \(readAt.formatted(date: .omitted, time: .standard))")
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.textMuted)
                }
            }
            Spacer(minLength: 0)
            if patch?.isLoading == true {
                ProgressView().controlSize(.mini)
            }
            if let additions = file.additions, let deletions = file.deletions {
                HStack(spacing: 3) {
                    Text(verbatim: "+\(additions)").foregroundStyle(AppColors.positiveText)
                    Text(verbatim: "−\(deletions)").foregroundStyle(AppColors.dangerText)
                }
                .font(AppTypography.interfaceCaption.monospacedDigit())
            }
            if let onOpenInFiles {
                Button(action: onOpenInFiles) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(GhostIconButtonStyle(size: 22, iconSize: 11))
                .accessibilityLabel("Open in Files")
                .help("Open the file in Files")
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    @ViewBuilder
    private var content: some View {
        switch patch?.result {
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .document(let document):
            GitDiffLinesView(store: store, file: file, document: document)
        case .tooLarge(let lineCount):
            ChangesNotice(systemImage: "doc.plaintext", title: "Too large to show here",
                          detail: lineCount.map { String(localized: "\($0) lines changed. Open the file in Files to read it.") }
                              ?? String(localized: "The diff is over 2 MB. Open the file in Files to read it."),
                          actionTitle: onOpenInFiles == nil ? nil : "Open in Files", action: onOpenInFiles)
        case .binary(let byteCount):
            ChangesNotice(systemImage: "doc.zipper", title: "Binary file",
                          detail: byteCount.map { String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)) · Git shows no lines for it.") }
                              ?? String(localized: "Git shows no lines for it."))
        case .conflicted:
            ChangesNotice(systemImage: "exclamationmark.triangle", title: "Merge conflict",
                          message: "Resolve this file's conflicts in a terminal; Changes doesn't show combined diffs.")
        case .noNetChange:
            ChangesNotice(systemImage: "equal.circle", title: "No net change",
                          message: "HEAD and the working tree hold the same content: what is staged was undone in the working tree. See Staged or Unstaged.")
        case .untrackedNote(let note):
            untrackedNotice(note)
        case .pathUnreadable:
            ChangesNotice(systemImage: "questionmark.folder", title: "Path can't be read",
                          message: "This path isn't valid UTF-8, so Limare can't ask Git about it. Look at it in a terminal.")
        case .failed(let message):
            ChangesNotice(systemImage: "exclamationmark.triangle", title: "Git couldn't show this file",
                          detail: message, actionTitle: "Try Again", action: { store.refresh(.manual) })
        }
    }

    @ViewBuilder
    private func untrackedNotice(_ note: GitReviewService.UntrackedNote) -> some View {
        switch note {
        case .symbolicLink(let destination):
            ChangesNotice(systemImage: "arrow.up.right.square", title: "Symbolic link",
                          detail: String(localized: "Points to \(destination). Links aren't followed."))
        case .directory:
            ChangesNotice(systemImage: "folder", title: "Folder",
                          message: "An untracked folder Git lists as a whole, often a repository of its own.")
        case .tooLarge(let byteCount):
            ChangesNotice(systemImage: "doc.plaintext", title: "Too large to show here",
                          detail: String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)). Open the file in Files to read it."),
                          actionTitle: onOpenInFiles == nil ? nil : "Open in Files", action: onOpenInFiles)
        case .binary(let byteCount):
            ChangesNotice(systemImage: "doc.zipper", title: "Binary file",
                          detail: String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)) · new, untracked."))
        case .unreadable(let detail):
            ChangesNotice(systemImage: "exclamationmark.triangle", title: "Couldn't read the file", detail: detail)
        }
    }
}

/// The hunks, line by line. Lazy, so a file near the 5,000-line limit stays responsive.
private struct GitDiffLinesView: View {
    let store: GitReviewStore
    let file: GitChangedFile
    let document: GitDiffDocument

    private var gutterWidth: CGFloat {
        let largest = document.lines.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        return CGFloat(String(largest).count) * 7.5 + 14
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(document.sections) { section in
                            GitDiffSectionNotes(section: section, file: file)
                            ForEach(section.hunks) { hunk in
                                Text(hunk.header)
                                    .font(AppTypography.codeMeta)
                                    .foregroundStyle(AppColors.textMuted)
                                    .lineLimit(1)
                                    .padding(.leading, gutterWidth * 2 + 4)
                                    .padding(.vertical, 3)
                                    .frame(minWidth: geometry.size.width, alignment: .leading)
                                    .background(AppColors.statusInfo.opacity(0.05))
                                ForEach(hunk.lines) { line in
                                    lineRows(line, commentable: !section.isSubmodule, width: geometry.size.width)
                                }
                            }
                        }
                    }
                    .padding(.bottom, AppSpacing.small)
                }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target, target.path == file.path else { return }
                    withAnimation(AppMotion.resolved(AppMotion.standard)) {
                        proxy.scrollTo(Self.rowID(side: target.side, line: target.line), anchor: .center)
                    }
                    store.scrollTarget = nil
                }
                .onAppear {
                    guard let target = store.scrollTarget, target.path == file.path else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.rowID(side: target.side, line: target.line), anchor: .center)
                        store.scrollTarget = nil
                    }
                }
            }
        }
    }

    static func rowID(side: GitDiffSide, line: Int) -> String { "\(side.rawValue)-\(line)" }

    @ViewBuilder
    private func lineRows(_ line: GitDiffLine, commentable: Bool, width: CGFloat) -> some View {
        let key = line.anchorLine.map { GitLineAnchor.Key(scope: store.scope, path: file.path, side: line.anchorSide, line: $0) }
        let comment = key.flatMap { store.comment(at: $0) }
        let isEditing = key != nil && store.editor?.anchor.key == key
        GitDiffLineRow(
            line: line,
            gutterWidth: gutterWidth,
            minWidth: width,
            hasComment: comment != nil,
            commentable: commentable,
            onComment: { store.beginComment(on: line, path: file.path) }
        )
        .id(Self.rowID(side: line.anchorSide, line: line.anchorLine ?? 0))
        if isEditing {
            GitCommentEditorCard(store: store)
                .frame(width: max(240, min(width, 640) - gutterWidth * 2 - 24))
                .padding(.leading, gutterWidth * 2 + 8)
                .padding(.vertical, AppSpacing.xxSmall)
        } else if let comment {
            GitCommentCard(comment: comment,
                           onEdit: { store.beginComment(on: line, path: file.path) },
                           onDelete: { store.deleteComment(id: comment.id) })
                .frame(width: max(240, min(width, 640) - gutterWidth * 2 - 24))
                .padding(.leading, gutterWidth * 2 + 8)
                .padding(.vertical, AppSpacing.xxSmall)
        }
    }
}

/// What a section's header says beyond its lines: renames, modes, new or deleted files, submodules.
private struct GitDiffSectionNotes: View {
    let section: GitDiffSection
    let file: GitChangedFile

    private var notes: [String] {
        var notes: [String] = []
        if let from = section.renameFrom {
            notes.append(section.similarity.map { String(localized: "Renamed from \(from) (\($0)% similar)") }
                         ?? String(localized: "Renamed from \(from)"))
        }
        if let from = section.copyFrom {
            notes.append(section.similarity.map { String(localized: "Copied from \(from) (\($0)% similar)") }
                         ?? String(localized: "Copied from \(from)"))
        }
        if section.hasModeChange, let old = section.oldMode, let new = section.newMode {
            notes.append(String(localized: "Mode changed: \(old) → \(new)"))
        }
        if section.isSubmodule {
            notes.append(file.submoduleDirtyOnly ? String(localized: "Submodule with uncommitted changes inside it")
                                                 : String(localized: "Submodule: the commit it points at"))
        }
        if section.hunks.isEmpty {
            if section.isNewFile { notes.append(String(localized: "New empty file")) }
            else if section.isDeletedFile { notes.append(String(localized: "Deleted empty file")) }
            else if !section.hasModeChange && section.renameFrom == nil && section.copyFrom == nil {
                notes.append(String(localized: "No content changes"))
            }
        }
        return notes
    }

    var body: some View {
        ForEach(notes, id: \.self) { note in
            Text(note)
                .font(AppTypography.interfaceCaption)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.xxSmall)
        }
    }
}

private struct GitDiffLineRow: View {
    let line: GitDiffLine
    let gutterWidth: CGFloat
    let minWidth: CGFloat
    let hasComment: Bool
    let commentable: Bool
    let onComment: () -> Void

    @State private var isHovered = false

    private var tint: Color? {
        switch line.kind {
        case .added: AppColors.statusSuccess
        case .removed: AppColors.statusError
        case .context: nil
        }
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var displayText: String {
        line.text.hasSuffix("\r") ? String(line.text.dropLast()) : line.text
    }

    var body: some View {
        HStack(spacing: 0) {
            gutter
            Text(marker)
                .foregroundStyle(tint ?? AppColors.textMuted)
                .frame(width: 14)
            Text(displayText.isEmpty ? " " : displayText)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize()
            if line.noNewlineAtEnd {
                Text("No newline at end of file")
                    .font(AppTypography.interfaceCaption2)
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.leading, AppSpacing.small)
                    .fixedSize()
            }
        }
        .font(AppTypography.codeMeta)
        .padding(.trailing, AppSpacing.medium)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(tint?.opacity(0.09) ?? .clear)
        .onHover { isHovered = $0 }
    }

    private var gutter: some View {
        Button(action: onComment) {
            HStack(spacing: 0) {
                number(line.oldLine)
                number(line.newLine)
            }
            .overlay(alignment: .leading) {
                if hasComment {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 2)
                } else if isHovered && commentable {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 9))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!commentable)
        .background(isHovered && commentable ? AppColors.surfaceInteractive : Color.primary.opacity(0.025))
        .accessibilityLabel(accessibilityLabel)
        .help(commentable ? String(localized: "Comment on this line") : String(localized: "Submodule lines can't be commented on"))
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(AppColors.textMuted)
            .monospacedDigit()
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.vertical, 1)
    }

    private var accessibilityLabel: String {
        let number = line.anchorLine ?? 0
        switch line.kind {
        case .added: return String(localized: "Added line \(number), comment")
        case .removed: return String(localized: "Removed line \(number), comment")
        case .context: return String(localized: "Line \(number), comment")
        }
    }
}

/// A saved comment under its line.
private struct GitCommentCard: View {
    let comment: GitReviewComment
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: "text.bubble")
                    .foregroundStyle(AppColors.textMuted)
                if comment.isOutdated {
                    Text("Outdated")
                        .foregroundStyle(AppColors.cautionIcon)
                        .help("The line no longer holds the text this comment was written on")
                }
                Spacer(minLength: 0)
                Button("Edit", action: onEdit)
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textSecondary)
                Button("Delete", action: onDelete)
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .font(AppTypography.interfaceCaption)
            Text(comment.body)
                .font(AppTypography.interface)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppSpacing.small)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).fill(AppColors.editorWell))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).strokeBorder(AppColors.hairline, lineWidth: 1))
    }
}

/// The comment being written. ⌘Return saves, Esc cancels.
private struct GitCommentEditorCard: View {
    @Bindable var store: GitReviewStore
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            TextEditor(text: $store.editorText)
                .font(AppTypography.interface)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 56, maxHeight: 140)
                .focused($focused)
                .accessibilityLabel("Comment")
            HStack(spacing: AppSpacing.small) {
                Spacer(minLength: 0)
                Button("Cancel") { store.cancelEditor() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { store.saveEditor() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(AppSpacing.small)
        .background(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).fill(AppColors.editorWell))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous).strokeBorder(AppColors.composerStroke, lineWidth: 1))
        .onAppear { focused = true }
    }
}
