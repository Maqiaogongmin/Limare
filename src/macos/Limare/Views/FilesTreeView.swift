import SwiftUI

/// Tree view displaying the Workspace directory hierarchy and files. Every Files tab shows the
/// same workspace tree (`AppState.files`: its folders stay open across tabs); `files` is the
/// store of the tab it sits in, whose file it highlights. `AppState.openTreeFile` decides where
/// a chosen file opens.
public struct FilesTreeView: View {
    @Environment(AppState.self) private var appState
    @State private var filterQuery: String = ""

    let files: FilesSurfaceStore

    init(files: FilesSurfaceStore) { self.files = files }

    private var tree: FilesSurfaceStore { appState.files }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            searchField
            Divider()

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
        HStack(spacing: AppSpacing.xxSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(AppColors.textMuted)

            TextField("Filter files…", text: $filterQuery)
                .textFieldStyle(.plain)
                .font(.caption)

            if !filterQuery.isEmpty {
                Button {
                    filterQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 4)
        .background(AppColors.surfaceSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xxSmall)
    }

    private var headerView: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(workspaceTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(1)
                .help("\(workspaceTitle)\n\(tree.rootURL?.path ?? "Workspace")")

            Spacer()

            Button {
                tree.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .help("Refresh Files")
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(height: 36)
        .background(AppColors.surfaceSecondary.opacity(0.4))
    }

    private var workspaceTitle: String {
        guard let rootURL = tree.rootURL else { return "Workspace" }
        if let conversation = appState.conversations.activeConversation,
           let project = appState.conversations.project(for: conversation),
           project.workspace?.url.standardizedFileURL == rootURL.standardizedFileURL {
            return project.name
        }
        let name = rootURL.lastPathComponent
        if let conversation = appState.conversations.activeConversation,
           name.caseInsensitiveCompare(conversation.id.uuidString) == .orderedSame {
            return conversation.title
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

    private var treeList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filteredNodes) { node in
                    FileTreeNodeRow(files: files, node: node, depth: 0)
                }
            }
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

private struct FileTreeNodeRow: View {
    @Environment(AppState.self) private var appState
    let files: FilesSurfaceStore
    let node: FileTreeNode
    let depth: Int

    private var isSelected: Bool {
        !node.isDirectory && files.selectedFileURL == node.url
    }

    private var isExpanded: Bool {
        node.isDirectory && appState.files.expandedPaths.contains(node.url.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if node.isDirectory {
                    appState.files.toggleDirectory(url: node.url)
                } else {
                    appState.openTreeFile(node.url, in: files)
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

                    Image(systemName: node.sfSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : AppColors.textSecondary)
                        .frame(width: 16)

                    Text(node.name)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : AppColors.textPrimary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.leading, CGFloat(depth * 14) + AppSpacing.small)
                .padding(.trailing, AppSpacing.small)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AppColors.selection : (node.isDirectory ? Color.clear : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let children = node.children {
                ForEach(children) { child in
                    FileTreeNodeRow(files: files, node: child, depth: depth + 1)
                }
            }
        }
    }
}
