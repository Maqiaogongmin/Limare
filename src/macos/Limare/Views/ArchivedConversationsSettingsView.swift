import SwiftUI

/// Settings › Archived: every archived conversation, searchable, filtered by project and
/// grouped by it on white cards, standalone conversations last.
struct ArchivedConversationsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var searchText = ""
    @State private var projectFilter: ProjectFilter = .all
    @State private var conversationToDelete: ConversationRecord?
    @State private var isConfirmingDeleteAll = false

    enum ProjectFilter: Hashable {
        case all
        case standalone
        case project(UUID)
    }

    /// One project's archived conversations; `project` is nil for the standalone group.
    struct ArchiveGroup: Identifiable {
        let project: ProjectRecord?
        let conversations: [ConversationRecord]
        var id: String { project?.id.uuidString ?? "standalone" }
    }

    private var archivedList: [ConversationRecord] {
        appState.conversations.archivedConversations
    }

    /// Every group with archived conversations, before search and filter: in the sidebar's
    /// project order, standalone last. A conversation whose project is gone counts as standalone.
    private var allGroups: [ArchiveGroup] {
        let store = appState.conversations
        let byProject = Dictionary(grouping: archivedList) { conv in
            conv.projectID.flatMap { id in store.projects.contains { $0.id == id } ? id : nil }
        }
        var groups = (store.pinnedProjects + store.unpinnedProjects).compactMap { project in
            byProject[project.id].map { ArchiveGroup(project: project, conversations: $0) }
        }
        if let standalone = byProject[nil] {
            groups.append(ArchiveGroup(project: nil, conversations: standalone))
        }
        return groups
    }

    /// The chosen filter while its group still holds something; All Projects once it is emptied.
    private var effectiveFilter: ProjectFilter {
        switch projectFilter {
        case .all:
            return .all
        case .standalone:
            return allGroups.contains { $0.project == nil } ? .standalone : .all
        case .project(let id):
            return allGroups.contains { $0.project?.id == id } ? projectFilter : .all
        }
    }

    private var visibleGroups: [ArchiveGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = effectiveFilter
        return allGroups.compactMap { group in
            switch filter {
            case .all: break
            case .standalone: guard group.project == nil else { return nil }
            case .project(let id): guard group.project?.id == id else { return nil }
            }
            let rows = query.isEmpty ? group.conversations : group.conversations.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
            return rows.isEmpty ? nil : ArchiveGroup(project: group.project, conversations: rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsColumn {
                VStack(alignment: .leading, spacing: AppSpacing.standard) {
                    headerRow
                    if !archivedList.isEmpty {
                        filterBar
                    }
                }
            }
            .padding(.top, AppSemanticLayout.settingsPageTop)
            .padding(.bottom, AppSpacing.standard)

            if archivedList.isEmpty {
                emptyState
            } else {
                let groups = visibleGroups
                if groups.isEmpty {
                    Text("No results for \"\(searchText)\"")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        SettingsColumn {
                            LazyVStack(alignment: .leading, spacing: AppSpacing.large) {
                                ForEach(groups) { group in
                                    groupSection(group)
                                }
                            }
                        }
                        .padding(.bottom, AppSemanticLayout.settingsPageTop)
                    }
                    .settingsScrollEdgeFade()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Delete Conversation permanently?",
            isPresented: Binding(get: { conversationToDelete != nil }, set: { if !$0 { conversationToDelete = nil } }),
            titleVisibility: .visible,
            presenting: conversationToDelete
        ) { conv in
            Button("Delete Permanently", role: .destructive) {
                appState.requestDeleteConversations([conv.id], in: window)
            }
            Button("Cancel", role: .cancel) {}
        } message: { conv in
            Text("This action cannot be undone. All messages in '\(conv.displayTitle)' will be permanently deleted.")
        }
        .confirmationDialog(
            "Delete all archived conversations?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All Permanently", role: .destructive) {
                appState.requestDeleteConversations(archivedList.map(\.id), in: window)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone. All \(archivedList.count) archived conversations and their messages will be permanently deleted.")
        }
    }

    private var headerRow: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Archived Conversations")
                .font(.system(size: 20, weight: .semibold))
            Spacer(minLength: AppSpacing.small)
            if !archivedList.isEmpty {
                Button {
                    isConfirmingDeleteAll = true
                } label: {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5))
                        Text("Delete All")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(AppColors.dangerText)
                    .padding(.horizontal, AppSpacing.small + 2)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Delete every archived conversation permanently")
                .accessibilityIdentifier("archived.deleteAll")
            }
        }
        .frame(minHeight: 28)
    }

    private var filterBar: some View {
        HStack(spacing: AppSpacing.small) {
            searchField
            projectMenu
        }
    }

    private var searchField: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search archived conversations...", text: $searchText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, AppSpacing.small + 2)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .fieldChrome()
        .accessibilityIdentifier("archived.search")
    }

    private var projectMenu: some View {
        let groups = allGroups
        let filter = effectiveFilter
        let label: String = switch filter {
        case .all: String(localized: "All Projects")
        case .standalone: String(localized: "Standalone")
        case .project(let id): groups.first { $0.project?.id == id }?.project?.name ?? String(localized: "All Projects")
        }
        return Menu {
            filterButton("All Projects", value: .all, current: filter)
            Divider()
            ForEach(groups) { group in
                if let project = group.project {
                    filterButton("\(project.name)", value: .project(project.id), current: filter)
                } else {
                    filterButton("Standalone", value: .standalone, current: filter)
                }
            }
        } label: {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.small + 2)
            .frame(height: 32)
            .fieldChrome()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: 220, alignment: .trailing)
        .accessibilityLabel("Project filter")
        .accessibilityIdentifier("archived.projectFilter")
    }

    private func filterButton(_ title: LocalizedStringKey, value: ProjectFilter, current: ProjectFilter) -> some View {
        Button {
            projectFilter = value
        } label: {
            if value == current {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func groupSection(_ group: ArchiveGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.xSmall) {
                Image(systemName: group.project == nil ? "bubble.left.and.bubble.right" : "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(group.project?.name ?? String(localized: "Standalone"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: AppSpacing.small)
                Text("\(group.conversations.count) conversations")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xxSmall)

            VStack(spacing: 0) {
                ForEach(Array(group.conversations.enumerated()), id: \.element.id) { index, conv in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                            .padding(.leading, AppSpacing.standard)
                    }
                    ArchivedConversationRow(
                        conversation: conv,
                        notice: appState.worktrees.notices[conv.id],
                        onOpen: {
                            appState.focus(window)
                            appState.conversations.restoreConversation(id: conv.id)
                            window.screen = .chat
                        },
                        onRestore: {
                            appState.focus(window)
                            appState.conversations.restoreConversation(id: conv.id)
                        },
                        onDelete: {
                            conversationToDelete = conv
                        },
                        onWorktree: conv.worktree == nil ? nil : {
                            window.worktreeDetails = conv.id
                        }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                    .fill(AppColors.raisedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                    .strokeBorder(AppColors.hairline, lineWidth: 1)
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.medium) {
            Image(systemName: "archivebox")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Archived Conversations")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Conversations archived from the sidebar will appear here.\nYou can restore them to the sidebar at any time.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppSpacing.xLarge)
    }
}

private extension View {
    /// The filter bar's white field: search and the project menu.
    func fieldChrome() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.raisedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppColors.cardStroke, lineWidth: 1)
        )
    }
}

/// Title over the archive time; clicking the title restores the conversation and opens it.
private struct ArchivedConversationRow: View {
    let conversation: ConversationRecord
    let notice: String?
    let onOpen: () -> Void
    let onRestore: () -> Void
    let onDelete: () -> Void
    let onWorktree: (() -> Void)?

    @State private var isHoveringTitle = false
    @State private var isHoveringTrash = false
    @State private var isHoveringRestore = false

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.displayTitle)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .underline(isHoveringTitle, color: Color.primary.opacity(0.3))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let date = conversation.archivedAt {
                        Text("Archived \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                    if let notice {
                        Text(notice).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTitle = $0 }
            .help("Restore and open")

            if let onWorktree {
                Button("Worktree…", action: onWorktree).controlSize(.small)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(isHoveringTrash ? AppColors.dangerHover : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringTrash = $0 }
            .help("Delete permanently")

            Button(action: onRestore) {
                Text("Restore")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, AppSpacing.small + 2)
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isHoveringRestore ? 0.09 : 0.06))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHoveringRestore = $0 }
            .help("Restore to Sidebar")
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.small + 2)
        .animation(AppMotion.resolved(AppMotion.quick), value: isHoveringTrash)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Restore and open", action: onOpen)
            Button("Restore to Sidebar", action: onRestore)
            Button("Delete permanently", action: onDelete)
            if let onWorktree { Button("Worktree…", action: onWorktree) }
        }
    }
}
