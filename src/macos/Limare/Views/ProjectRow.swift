import SwiftUI

struct ProjectRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let project: ProjectRecord

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDeletion = false
    @State private var isShowingAllConversations = false

    private let maxInitialConversations = 5

    private var isExpanded: Bool {
        appState.conversations.expandedProjectIDs.contains(project.id)
    }

    private var projectConversations: [ConversationRecord] {
        appState.conversations.activeConversations(in: project)
    }

    private var visibleConversations: [ConversationRecord] {
        if isShowingAllConversations || projectConversations.count <= maxInitialConversations {
            return projectConversations
        }
        return Array(projectConversations.prefix(maxInitialConversations))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
            header

            if isExpanded {
                VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                    if projectConversations.isEmpty {
                        SidebarEmptyState(message: "No conversations", isIndented: true)
                    } else {
                        ForEach(visibleConversations) { conv in
                            ConversationRow(conversation: conv, isIndented: true)
                        }

                        if projectConversations.count > maxInitialConversations {
                            Button {
                                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                                    isShowingAllConversations.toggle()
                                }
                            } label: {
                                HStack(spacing: AppSpacing.xxSmall) {
                                    Image(systemName: isShowingAllConversations ? "chevron.up" : "chevron.down")
                                        .font(AppTypography.interfaceCaption2)
                                    Text(isShowingAllConversations ? "Show Less" : "Show More (\(projectConversations.count - maxInitialConversations))")
                                        .font(AppTypography.interfaceCaption)
                                }
                                .foregroundStyle(Color.secondary)
                                .padding(.leading, AppSpacing.medium + AppSpacing.small)
                                .padding(.vertical, AppSpacing.xxSmall)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }

        .sheet(isPresented: $isRenaming) {
            SidebarRenameSheet(
                title: "Rename Project",
                placeholder: "Project Name",
                text: $renameText,
                onSave: { newName in
                    appState.conversations.renameProject(id: project.id, name: newName)
                    isRenaming = false
                },
                onCancel: {
                    isRenaming = false
                }
            )
        }
        .confirmationDialog(
            "Delete \(project.name)?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Project Only", role: .destructive) {
                appState.conversations.deleteProject(id: project.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conversations in this project will be kept and converted to standalone conversations.")
        }
    }

    private var header: some View {
        SidebarRowContainer(
            isSelected: false
        ) {
            Button {
                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                    appState.conversations.toggleProjectExpanded(id: project.id)
                }
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(AppTypography.interfaceCaption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)

                    Image(systemName: project.isPinned ? "pin.fill" : "folder")
                        .font(AppTypography.interfaceSubheadline)
                        .foregroundStyle(project.isPinned ? Color.accentColor : Color.secondary)

                    Text(project.name)
                        .font(AppTypography.interfaceSubheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Color.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse project \(project.name)" : "Expand project \(project.name)")
        } actions: {
            SidebarHoverIconButton(
                systemImage: "plus",
                tooltip: "New Conversation in \(project.name)"
            ) {
                appState.showChat(in: window)
                appState.conversations.newConversation(projectID: project.id)
            }

            Menu {
                projectMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: AppControlHeight.small, height: AppControlHeight.small)
            .help("Project Actions")
            .accessibilityLabel("Project actions for \(project.name)")
        }
        .contextMenu {
            projectMenuItems
        }
    }

    @ViewBuilder
    private var projectMenuItems: some View {
        Button {
            appState.showChat(in: window)
            appState.conversations.newConversation(projectID: project.id)
        } label: {
            Label("New Conversation in Project", systemImage: "plus")
        }

        Button {
            renameText = project.name
            isRenaming = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            appState.conversations.toggleProjectPinned(id: project.id)
        } label: {
            Label(
                project.isPinned ? "Unpin Project" : "Pin Project",
                systemImage: project.isPinned ? "pin.slash" : "pin"
            )
        }



        Divider()

        Button {
            chooseWorkspaceForProject()
        } label: {
            Label(project.workspace == nil ? "Choose Project Folder…" : "Change Project Folder…", systemImage: "folder.badge.gearshape")
        }

        if let ws = project.workspace {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ws.path)
            } label: {
                Label("Reveal Project Folder in Finder", systemImage: "arrow.up.forward.app")
            }

            Button {
                appState.conversations.setProjectWorkspace(id: project.id, workspace: nil)
            } label: {
                Label("Remove Project Folder", systemImage: "xmark.circle")
            }
        }

        Divider()

        Button {
            appState.conversations.archiveProjectConversations(id: project.id)
        } label: {
            Label("Archive All Conversations", systemImage: "archivebox")
        }

        Divider()

        Button(role: .destructive) {
            isConfirmingDeletion = true
        } label: {
            Label("Delete Project…", systemImage: "trash")
        }
    }

    private func chooseWorkspaceForProject() {
        let picker = WorkspacePicker()
        guard let url = picker.chooseWorkspace() else { return }
        let config = WorkspaceConfiguration.from(url: url)
        appState.conversations.setProjectWorkspace(id: project.id, workspace: config)
    }
}
