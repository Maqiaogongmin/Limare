import SwiftUI

struct CreateProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var projectName = ""
    @State private var selectedWorkspace: WorkspaceConfiguration?
    @State private var isHoveringCard = false

    private var canCreate: Bool {
        selectedWorkspace != nil
    }


    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            header
            nameSection
            folderSection
            footer
        }
        .padding(AppSpacing.large)
        .frame(width: 440)
    }

    private var header: some View {
        HStack {
            Text("创建项目")
                .font(.title3.weight(.bold))

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(AppColors.surfaceInteractive)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private var nameSection: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundStyle(AppColors.textSecondary)

            TextField("项目名称", text: $projectName)
                .textFieldStyle(.plain)
                .font(.body)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card)
                .stroke(AppColors.borderMuted, lineWidth: 1)
                .background(AppColors.surfaceElevated.clipShape(RoundedRectangle(cornerRadius: AppRadius.card)))
        )
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("项目文件夹")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            if let ws = selectedWorkspace {
                selectedFolderCard(ws)
            } else {
                emptyFolderCard
            }
        }
    }

    private var emptyFolderCard: some View {
        Button {
            chooseFolder()
        } label: {
            VStack(spacing: AppSpacing.small) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(AppColors.textSecondary)

                Text("选择作为项目默认工作目录的文件夹")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 100)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.modal)
                    .stroke(
                        isHoveringCard ? Color.accentColor.opacity(0.8) : AppColors.borderMuted,
                        lineWidth: 1
                    )
                    .background(
                        (isHoveringCard ? AppColors.surfaceInteractive : AppColors.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.modal))
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.modal))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringCard = $0 }
    }

    private func selectedFolderCard(_ ws: WorkspaceConfiguration) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: "folder.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(ws.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(ws.path)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("更换") {
                chooseFolder()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(Color.accentColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))

            Button {
                selectedWorkspace = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("移除文件夹")
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.modal)
                .stroke(AppColors.borderMuted, lineWidth: 1)
                .background(AppColors.surfaceElevated.clipShape(RoundedRectangle(cornerRadius: AppRadius.modal)))
        )
    }

    private var footer: some View {
        HStack(spacing: AppSpacing.medium) {
            Spacer()

            Button("取消") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.small)
            .contentShape(Rectangle())

            Button {
                createProject()
            } label: {
                Text("创建项目")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canCreate ? Color(nsColor: .windowBackgroundColor) : AppColors.textSecondary)
                    .padding(.horizontal, AppSpacing.standard)
                    .padding(.vertical, AppSpacing.small)
                    .background(canCreate ? Color.primary : AppColors.surfaceInteractive)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.top, AppSpacing.xxSmall)
    }

    private func chooseFolder() {
        let picker = WorkspacePicker()
        guard let url = picker.chooseWorkspace() else { return }
        let config = WorkspaceConfiguration.from(url: url)
        selectedWorkspace = config
        if projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectName = config.name
        }
    }

    private func createProject() {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? (selectedWorkspace?.name ?? "New Project") : trimmed
        let project = appState.conversations.newProject(name: finalName, workspace: selectedWorkspace)
        appState.focus(window)
        appState.conversations.newConversation(projectID: project.id)
        dismiss()
    }
}
