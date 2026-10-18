import SwiftUI

struct ProjectSection: View {
    @Environment(AppState.self) private var appState
    @Binding var isCreatingProject: Bool
    @AppStorage("limare.sidebar.projects.expanded") private var isExpanded: Bool = true
    @State private var isShowingAllProjects: Bool = false
    @State private var isAddHovered = false
    @FocusState private var isAddFocused: Bool

    private let maxInitialProjects = 6

    private var unpinnedProjects: [ProjectRecord] {
        appState.conversations.unpinnedProjects
    }

    private var visibleProjects: [ProjectRecord] {
        if isShowingAllProjects || unpinnedProjects.count <= maxInitialProjects {
            return unpinnedProjects
        }
        return Array(unpinnedProjects.prefix(maxInitialProjects))
    }

    var body: some View {
        Section {
            if isExpanded {
                if unpinnedProjects.isEmpty {
                    if appState.conversations.pinnedProjects.isEmpty {
                        Button {
                            isCreatingProject = true
                        } label: {
                            Label("Create Project…", systemImage: "plus.circle")
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, AppSpacing.xxSmall)
                    }
                } else {
                    ForEach(visibleProjects) { project in
                        ProjectRow(project: project)
                    }

                    if unpinnedProjects.count > maxInitialProjects {
                        Button {
                            withAnimation(AppMotion.resolved(AppMotion.standard)) {
                                isShowingAllProjects.toggle()
                            }
                        } label: {
                            HStack(spacing: AppSpacing.xxSmall) {
                                Image(systemName: isShowingAllProjects ? "chevron.up" : "chevron.down")
                                    .font(AppTypography.interfaceCaption2)
                                Text(isShowingAllProjects ? "Show Less" : "Show More (\(unpinnedProjects.count - maxInitialProjects))")
                                    .font(AppTypography.interfaceCaption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.secondary)
                            .padding(.vertical, AppSpacing.xxSmall)
                            .padding(.horizontal, AppSpacing.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            HStack(spacing: AppSpacing.xxSmall) {
                Button {
                    withAnimation(AppMotion.resolved(AppMotion.standard)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppTypography.interfaceCaption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 10)

                        Text("Projects")
                            .font(AppTypography.interfaceCaption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    isCreatingProject = true
                } label: {
                    Image(systemName: "plus")
                        .font(AppTypography.interfaceCaption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.small)
                                .fill((isAddHovered || isAddFocused) ? Color.secondary.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isAddFocused)
                .onHover { isAddHovered = $0 }
                .help("New Project")
                .accessibilityLabel("New Project")
            }
        }
    }
}
