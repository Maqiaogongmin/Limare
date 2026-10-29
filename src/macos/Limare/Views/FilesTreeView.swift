import SwiftUI

/// Tree view displaying the Workspace directory hierarchy and files. Every Files tab shows the
/// same workspace tree (`AppState.files`: its folders stay open across tabs); `files` is the
/// store of the tab it sits in, whose file it highlights. `AppState.openTreeFile` decides where
/// a chosen file opens.
public struct FilesTreeView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var filterQuery: String = ""

    let files: FilesSurfaceStore

    init(files: FilesSurfaceStore) { self.files = files }

    private var tree: FilesSurfaceStore { window.files }

    public var body: some View {
        VStack(spacing: 0) {
            // No rules: the header, the filter and the tree are set apart by space alone.
            headerView
            searchField

            if let error = tree.treeErrorMessage {
                unavailableView(error)
            } else if tree.isLoadingTree {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tree.treeNodes.isEmpty {
                emptyView
            } else if filteredNodes.isEmpty {
                noMatchView
            } else {
                treeList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textMuted)

            TextField("Filter files…", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))

            if !filterQuery.isEmpty {
                Button {
                    filterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        // A borderless field set into the panel.
        .padding(.horizontal, AppSpacing.small)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .padding(.horizontal, AppSpacing.medium)
        .padding(.bottom, AppSpacing.xSmall)
    }

    private var headerView: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(FileTreeStyle.folderIcon)

            Text(workspaceTitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .help("\(workspaceTitle)\n\(tree.rootURL?.path ?? "Workspace")")

            Spacer()

            Button {
                tree.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Refresh Files")
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(height: 36)
    }

    private var workspaceTitle: String {
        guard let rootURL = tree.rootURL else { return String(localized: "Workspace") }
        if let conversation = window.conversation, let worktree = conversation.worktree {
            let project = appState.conversations.project(for: conversation)?.name ?? URL(fileURLWithPath: worktree.repositoryRoot).lastPathComponent
            let branch: String
            if case .branch(let name)? = window.changes.snapshot?.branch { branch = name }
            else if case .detached(let sha)? = window.changes.snapshot?.branch { branch = "HEAD \(sha)" }
            else { branch = worktree.branch }
            return "\(project) / \(branch)"
        }
        if let conversation = window.conversation,
           let project = appState.conversations.project(for: conversation),
           project.workspace?.url.standardizedFileURL == rootURL.standardizedFileURL {
            return project.name
        }
        let name = rootURL.lastPathComponent
        if let conversation = window.conversation,
           name.caseInsensitiveCompare(conversation.id.uuidString) == .orderedSame {
            return conversation.displayTitle
        }
        return name
    }

    private var filteredNodes: [FileTreeNode] {
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return tree.treeNodes
        }
        let query = trimmed.lowercased()
        return filterTreeNodes(tree.treeNodes, matching: query)
    }

    private func filterTreeNodes(_ nodes: [FileTreeNode], matching query: String) -> [FileTreeNode] {
        var results: [FileTreeNode] = []
        for node in nodes {
            if node.name.lowercased().contains(query) {
                results.append(node)
            } else if let children = node.children, !children.isEmpty {
                let matchingChildren = filterTreeNodes(children, matching: query)
                if !matchingChildren.isEmpty {
                    var parent = node
                    parent.children = matchingChildren
                    results.append(parent)
                }
            }
        }
        return results
    }

    /// One row per visible node, in display order: an open folder's children follow it as rows of
    /// their own rather than nesting inside it, so the lazy stack builds and measures only the
    /// rows on screen. Nested, an open folder of hundreds of files was a single item, built,
    /// measured and torn down whole on every open, close and preview.
    private var visibleRows: [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func append(_ nodes: [FileTreeNode], depth: Int) {
            for node in nodes {
                let isExpanded = node.isDirectory && tree.expandedPaths.contains(node.id)
                rows.append(FileTreeRow(node: node, depth: depth, isExpanded: isExpanded))
                if isExpanded, let children = node.children {
                    append(children, depth: depth + 1)
                }
            }
        }
        append(filteredNodes, depth: 0)
        return rows
    }

    private var treeList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleRows) { row in
                    FileTreeNodeRow(files: files, row: row)
                }
            }
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xxSmall)
        }
    }

    private var noMatchView: some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.textMuted)
            Text("No matching files")
                .font(.subheadline)
                .foregroundStyle(AppColors.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.textMuted)
            Text("No files yet")
                .font(.subheadline)
                .foregroundStyle(AppColors.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(_ message: String) -> some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(AppColors.statusWarning)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The tree's single, quiet palette: folders a step darker than files, no accent colour.
private enum FileTreeStyle {
    static let folderIcon = Color.primary.opacity(0.68)
    static let fileIcon = Color.secondary.opacity(0.55)
    static let rowHeight: CGFloat = 26
    static let rowFill = Color.primary.opacity(0.05)
}

/// A node where the tree shows it: how deep, and whether its folder is open.
private struct FileTreeRow: Identifiable {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool

    var id: String { node.id }
}

private struct FileTreeNodeRow: View {
    @Environment(WindowSession.self) private var window
    let files: FilesSurfaceStore
    let row: FileTreeRow

    @State private var isHovering = false

    private var node: FileTreeNode { row.node }
    private var depth: Int { row.depth }
    private var isExpanded: Bool { row.isExpanded }

    private var isSelected: Bool {
        !node.isDirectory && files.selectedFileURL == node.url
    }

    var body: some View {
        Button {
            if node.isDirectory {
                window.files.toggleDirectory(url: node.url)
            } else {
                window.openTreeFile(node.url, in: files)
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppColors.textMuted)
                        .frame(width: 12)
                } else {
                    Spacer()
                        .frame(width: 12)
                }

                // An outlined folder: a filled one reads heavier than the names beside it.
                Image(systemName: node.isDirectory ? "folder" : node.sfSymbol)
                    .font(.system(size: 12))
                    .foregroundStyle(node.isDirectory ? FileTreeStyle.folderIcon : FileTreeStyle.fileIcon)
                    .frame(width: 18)

                Text(node.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth * 14) + AppSpacing.xSmall)
            .padding(.trailing, AppSpacing.xSmall)
            .frame(height: FileTreeStyle.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .fill(isSelected || isHovering ? FileTreeStyle.rowFill : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
    }
}
