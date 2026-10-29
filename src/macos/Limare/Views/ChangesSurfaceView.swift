import SwiftUI

/// The Changes surface: the project's Git changes in one scope, a file's diff, and the line
/// comments the user adds to the message. Read-only; it follows the window's conversation.
struct ChangesSurfaceView: View {
    @Environment(WindowSession.self) private var window
    /// In the narrow layout the list and the diff take turns; this says the diff's turn.
    @State private var showsDiffWhenNarrow = false
    @State private var showsComments = false
    @State private var confirmsOutdated = false

    private var store: GitReviewStore { window.changes }
    static let narrowWidth: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            let isNarrow = geometry.size.width < Self.narrowWidth
            VStack(spacing: 0) {
                switch store.availability {
                case .idle:
                    loading
                case .unavailable(let why):
                    ChangesUnavailableView(reason: why, onRetry: { store.refresh(.manual) })
                case .repository(let root):
                    if let snapshot = store.snapshot {
                        if window.conversation?.worktree != nil {
                            Label("Worktree", systemImage: "arrow.triangle.branch")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, AppSpacing.medium)
                        }
                        ChangesHeader(store: store, root: root, snapshot: snapshot)
                        rule
                        content(snapshot, root: root, isNarrow: isNarrow)
                        rule
                        bottomBar
                    } else if let error = store.refreshError {
                        ChangesNotice(systemImage: "exclamationmark.triangle", title: "Git couldn't read the changes",
                                      detail: error, actionTitle: "Try Again", action: { store.refresh(.manual) })
                    } else {
                        loading
                    }
                }
            }
        }
        .onAppear {
            window.syncChanges()
            store.refresh(.opened)
        }
        .onDisappear { store.saveEditor() }
        .confirmationDialog("Some comments are outdated", isPresented: $confirmsOutdated, titleVisibility: .visible) {
            Button("Add to Message") { window.addReviewToMessage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(store.comments.filter(\.isOutdated).count) comments point at lines that have changed since. They are added with the text and line numbers they had.")
        }
    }

    private var loading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
    }

    @ViewBuilder
    private func content(_ snapshot: GitReviewSnapshot, root: URL, isNarrow: Bool) -> some View {
        if snapshot.files.isEmpty {
            ChangesNotice(systemImage: "checkmark.circle", title: emptyTitle(snapshot), message: emptyMessage(snapshot))
        } else if isNarrow {
            if showsDiffWhenNarrow, let file = store.selectedFile {
                diff(file, root: root, onBack: { showsDiffWhenNarrow = false })
            } else {
                fileList(snapshot)
            }
        } else {
            HStack(spacing: 0) {
                fileList(snapshot)
                    .frame(width: 200)
                Rectangle().fill(AppColors.separator).frame(width: 1)
                if let file = store.selectedFile {
                    diff(file, root: root, onBack: nil)
                } else {
                    ChangesNotice(systemImage: "doc.text.magnifyingglass", title: "Select a file", message: nil)
                }
            }
        }
    }

    private func fileList(_ snapshot: GitReviewSnapshot) -> some View {
        ChangesFileList(store: store, files: snapshot.files) { path in
            store.select(path: path)
            showsDiffWhenNarrow = true
        }
    }

    private func diff(_ file: GitChangedFile, root: URL, onBack: (() -> Void)?) -> some View {
        GitDiffView(
            store: store,
            file: file,
            onBack: onBack,
            onOpenInFiles: file.status == .deleted || file.pathIsLossy ? nil : {
                window.previewWorkspaceFile(root.appendingPathComponent(file.path))
            }
        )
        .id(file.path)
    }

    private var bottomBar: some View {
        let count = store.comments.count
        return HStack(spacing: AppSpacing.small) {
            Button {
                showsComments.toggle()
            } label: {
                Label("\(count) comments", systemImage: "text.bubble")
                    .font(AppTypography.interfaceCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(count == 0 ? AppColors.textMuted : AppColors.textSecondary)
            .disabled(count == 0)
            .accessibilityLabel("Review comments")
            .help("Show the review comments")
            .popover(isPresented: $showsComments, arrowEdge: .top) {
                GitReviewCommentsView(store: store, onClose: { showsComments = false })
            }

            Spacer(minLength: 0)

            Button("Add to Message") {
                store.saveEditor()
                if store.comments.contains(where: \.isOutdated) {
                    confirmsOutdated = true
                } else {
                    window.addReviewToMessage()
                }
            }
            .controlSize(.small)
            .disabled(count == 0 || !window.canAddReviewToMessage)
            .help(window.canAddReviewToMessage
                  ? String(localized: "Add the comments to the message you're writing; nothing is sent until you send it")
                  : String(localized: "This is a subtask's conversation; review in its parent conversation"))
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.xSmall)
    }

    private func emptyTitle(_ snapshot: GitReviewSnapshot) -> LocalizedStringKey {
        switch snapshot.scope {
        case .branch: "No commits to compare"
        case .task: "No changes since the task started"
        default: "No changes"
        }
    }

    private func emptyMessage(_ snapshot: GitReviewSnapshot) -> LocalizedStringKey {
        switch snapshot.scope {
        case .all: "Everything is committed."
        case .unstaged: "Nothing in the working tree differs from the index."
        case .staged: "Nothing is staged."
        case .branch: "This branch has no commits that \(snapshot.base ?? "") doesn't have."
        case .task: "The worktree matches the commit it started from."
        }
    }
}

// MARK: - Header

/// Repository, branch and refresh; then the scope, the base and the totals.
private struct ChangesHeader: View {
    let store: GitReviewStore
    let root: URL
    let snapshot: GitReviewSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textMuted)
                Text(root.lastPathComponent)
                    .font(AppTypography.interfaceMedium)
                    .lineLimit(1)
                Text(branchLabel)
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if store.isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Button {
                    store.refresh(.manual)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GhostIconButtonStyle(size: 22, iconSize: 11))
                .accessibilityLabel("Refresh")
                .help("Read the changes again")
            }

            HStack(spacing: AppSpacing.small) {
                scopeMenu
                if store.scope == .branch { baseMenu }
                Spacer(minLength: 0)
                totals
            }

            if let error = store.refreshError {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xxSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.cautionIcon)
                    Text("Couldn't refresh: \(error) Showing what was read at \(snapshot.readAt.formatted(date: .omitted, time: .standard)).")
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(AppTypography.interfaceCaption)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var branchLabel: String {
        switch snapshot.branch {
        case .branch(let name): name
        case .detached(let sha): String(localized: "Detached at \(sha)")
        case .unborn(let name): name.isEmpty ? String(localized: "No commits yet") : String(localized: "\(name) · no commits yet")
        }
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(GitReviewScope.allCases.filter { $0 != .task || store.taskBase != nil }) { scope in
                let reason = store.unavailability(of: scope)
                Button {
                    store.setScope(scope)
                } label: {
                    if let reason {
                        Text(verbatim: "\(ChangesScopeLabel.title(scope, base: store.base, taskBase: store.taskBaseName)) — \(reason)")
                    } else if scope == store.scope {
                        Label(ChangesScopeLabel.title(scope, base: store.base, taskBase: store.taskBaseName), systemImage: "checkmark")
                    } else {
                        Text(ChangesScopeLabel.title(scope, base: store.base, taskBase: store.taskBaseName))
                    }
                }
                .disabled(reason != nil)
            }
        } label: {
            Text(ChangesScopeLabel.title(store.scope, base: store.base, taskBase: store.taskBaseName))
                .font(AppTypography.interfaceCaption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Compare")
        .help("Which changes to show")
    }

    private var baseMenu: some View {
        Menu {
            ForEach(store.baseChoices?.candidates ?? [], id: \.self) { candidate in
                Button {
                    store.setBase(candidate)
                } label: {
                    if candidate == store.base {
                        Label(candidate, systemImage: "checkmark")
                    } else {
                        Text(candidate)
                    }
                }
            }
        } label: {
            Text(store.base ?? String(localized: "Choose a base"))
                .font(AppTypography.interfaceCaption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.baseChoices?.candidates.isEmpty ?? true)
        .accessibilityLabel("Base branch")
        .help("The branch to compare the commits against")
    }

    private var totals: some View {
        HStack(spacing: AppSpacing.xxSmall) {
            Text("\(snapshot.files.count) files")
                .foregroundStyle(AppColors.textSecondary)
            Text(verbatim: "+\(snapshot.totalAdditions)")
                .foregroundStyle(AppColors.positiveText)
            Text(verbatim: "−\(snapshot.totalDeletions)")
                .foregroundStyle(AppColors.dangerText)
        }
        .font(AppTypography.interfaceCaption.monospacedDigit())
        .lineLimit(1)
    }
}

/// How a scope is named in the Changes surface.
enum ChangesScopeLabel {
    static func title(_ scope: GitReviewScope, base: String?, taskBase: String? = nil) -> String {
        switch scope {
        case .all: String(localized: "All changes (uncommitted)")
        case .unstaged: String(localized: "Unstaged")
        case .staged: String(localized: "Staged")
        case .branch: base.map { String(localized: "Committed vs \($0)") } ?? String(localized: "Committed vs base")
        case .task: taskBase.map { String(localized: "Since the task started from \($0)") } ?? String(localized: "Since the task started")
        }
    }
}

// MARK: - File list

private struct ChangesFileList: View {
    let store: GitReviewStore
    let files: [GitChangedFile]
    let onSelect: (String) -> Void

    private struct Group: Identifiable {
        let id: Int
        let title: LocalizedStringKey
        let files: [GitChangedFile]
    }

    private var groups: [Group] {
        Dictionary(grouping: files, by: \.status.groupOrder)
            .sorted { $0.key < $1.key }
            .map { order, files in Group(id: order, title: Self.title(order), files: files) }
    }

    private static func title(_ order: Int) -> LocalizedStringKey {
        switch order {
        case 0: "Conflicts"
        case 1: "Modified"
        case 2: "Added"
        case 3: "Deleted"
        case 4: "Renamed"
        default: "Untracked"
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    Text(group.title)
                        .font(AppTypography.interfaceCaption2.weight(.semibold))
                        .foregroundStyle(AppColors.textMuted)
                        .padding(.horizontal, AppSpacing.medium)
                        .padding(.top, AppSpacing.small)
                        .padding(.bottom, AppSpacing.xxSmall)
                    ForEach(group.files) { file in
                        ChangesFileRow(file: file, isSelected: file.path == store.selectedPath,
                                       commentCount: store.comments.filter { $0.anchor.path == file.path }.count,
                                       onSelect: { onSelect(file.path) })
                    }
                }
            }
            .padding(.bottom, AppSpacing.small)
        }
    }
}

private struct ChangesFileRow: View {
    let file: GitChangedFile
    let isSelected: Bool
    let commentCount: Int
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
            Text(file.status.letter)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(ChangesStatusColor.color(file.status))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text((file.path as NSString).lastPathComponent)
                    .font(AppTypography.interface)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if !tags.isEmpty {
                    Text(tags.joined(separator: " · "))
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if commentCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble.fill")
                    Text(verbatim: "\(commentCount)")
                }
                .font(AppTypography.interfaceCaption2)
                .foregroundStyle(AppColors.textSecondary)
            }
            counts
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall + 1)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .fill(isSelected ? AppColors.selection : (isHovered ? AppColors.surfaceInteractive : .clear))
        )
        .padding(.horizontal, AppSpacing.xSmall)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
    }

    /// The folder, or where a renamed file came from.
    private var detail: String? {
        if let oldPath = file.oldPath { return "\(oldPath) →" }
        let folder = (file.path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }

    private var tags: [String] {
        var tags: [String] = []
        switch file.stageMark {
        case .staged: tags.append(String(localized: "Staged"))
        case .unstaged: tags.append(String(localized: "Unstaged"))
        case .both: tags.append(String(localized: "Staged + unstaged"))
        case .untracked, nil: break
        }
        if file.hasNoNetChange { tags.append(String(localized: "No net change")) }
        if file.isSubmodule { tags.append(String(localized: "Submodule")) }
        if file.pathIsLossy { tags.append(String(localized: "Path not UTF-8")) }
        return tags
    }

    @ViewBuilder
    private var counts: some View {
        if file.isBinary {
            Text("binary")
                .font(AppTypography.interfaceCaption2)
                .foregroundStyle(AppColors.textMuted)
        } else if let additions = file.additions, let deletions = file.deletions {
            HStack(spacing: 3) {
                Text(verbatim: "+\(additions)").foregroundStyle(AppColors.positiveText)
                Text(verbatim: "−\(deletions)").foregroundStyle(AppColors.dangerText)
            }
            .font(AppTypography.interfaceCaption2.monospacedDigit())
        }
    }
}

enum ChangesStatusColor {
    static func color(_ status: GitFileStatus) -> Color {
        switch status {
        case .added, .untracked: AppColors.positiveText
        case .deleted, .conflicted: AppColors.dangerText
        case .renamed, .copied: AppColors.statusInfo
        case .modified, .typeChanged: AppColors.cautionIcon
        }
    }
}

// MARK: - States

/// An icon, a title, a line of explanation and maybe one action, centred.
struct ChangesNotice: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: Text?
    var actionTitle: LocalizedStringKey?
    var action: (() -> Void)?

    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey?,
         actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message.map { Text($0) }
        self.actionTitle = actionTitle
        self.action = action
    }

    /// For text that is already localized or comes from Git.
    init(systemImage: String, title: LocalizedStringKey, detail: String,
         actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = Text(verbatim: detail)
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(AppColors.textMuted)
            Text(title)
                .font(AppTypography.interfaceMedium)
                .foregroundStyle(AppColors.textPrimary)
            if let message {
                message
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, AppSpacing.xxSmall)
            }
        }
        .padding(AppSpacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangesUnavailableView: View {
    let reason: GitRepositoryUnavailable
    let onRetry: () -> Void

    var body: some View {
        switch reason {
        case .gitNotInstalled:
            ChangesNotice(systemImage: "wrench.and.screwdriver", title: "Git isn't available",
                          message: "Changes needs the Command Line Tools. Install them by running xcode-select --install in Terminal, then try again.",
                          actionTitle: "Try Again", action: onRetry)
        case .notRepository(let nested?):
            ChangesNotice(systemImage: "folder.badge.questionmark", title: "Not a Git repository",
                          message: "The folder “\(nested)” inside this project is one. To review its changes, open it as the project.",
                          actionTitle: "Check Again", action: onRetry)
        case .notRepository(nil):
            ChangesNotice(systemImage: "folder.badge.questionmark", title: "Not a Git repository",
                          message: "This conversation's working folder isn't under Git, so there are no changes to review.",
                          actionTitle: "Check Again", action: onRetry)
        case .notRepositoryRoot(let root):
            ChangesNotice(systemImage: "folder.badge.questionmark", title: "Open the repository's root",
                          message: "This folder is inside the Git repository at \(root). Open that folder as the project to review its changes.",
                          actionTitle: "Check Again", action: onRetry)
        case .gitFailed(let detail):
            ChangesNotice(systemImage: "exclamationmark.triangle", title: "Git couldn't read this folder",
                          detail: detail, actionTitle: "Try Again", action: onRetry)
        }
    }
}
