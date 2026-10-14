import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var isCreatingProject = false
    @State private var isViewingArchived = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            List {
                if !searchText.isEmpty {
                    searchResultsSection
                } else {
                    if appState.conversations.hasPinnedItems {
                        pinnedSection
                    }
                    ProjectSection(isCreatingProject: $isCreatingProject)
                    ConversationSection()
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("conversation.sidebar")

            Divider()

            bottomUtilityBar
        }
        .navigationTitle("Limare")
        .sheet(isPresented: $isCreatingProject) {
            CreateProjectSheet()
        }
        .sheet(isPresented: $isViewingArchived) {
            ArchivedConversationsSheet()
        }
    }

    private var bottomUtilityBar: some View {
        VStack(spacing: AppSpacing.xxxSmall) {
            SidebarRowContainer(
                isSelected: false,
                onSelect: {
                    isViewingArchived = true
                }
            ) {
                Image(systemName: "archivebox")
                    .font(AppTypography.interfaceSubheadline)
                    .foregroundStyle(Color.secondary)
                Text("Archived Conversations")
                    .font(AppTypography.interfaceSubheadline)
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.88))
                Spacer()
                if !appState.conversations.archivedConversations.isEmpty {
                    Text("\(appState.conversations.archivedConversations.count)")
                        .font(AppTypography.interfaceCaption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, AppSpacing.xSmall)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                }
            }

            SidebarRowContainer(
                isSelected: false,
                onSelect: {
                    Task { @MainActor in
                        appState.screen = .settingsGeneral
                    }
                }
            ) {
                Image(systemName: "gearshape")
                    .font(AppTypography.interfaceSubheadline)
                    .foregroundStyle(Color.secondary)
                Text("Settings")
                    .font(AppTypography.interfaceSubheadline)
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.88))
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sidebar.settings")
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    private var topBar: some View {
        VStack(spacing: AppSpacing.small) {
            Button {
                appState.conversations.newConversation()
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: "square.and.pencil")
                        .font(AppTypography.interfaceSubheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    Text("New Conversation")
                        .font(AppTypography.interfaceMedium)
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)
                .background(AppColors.surfaceInteractive)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.sidebar.newConversation")

            SidebarSearchField(text: $searchText)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        let results = appState.conversations.searchResults(query: searchText)
        if results.projects.isEmpty && results.conversations.isEmpty {
            Section {
                SidebarEmptyState(message: "No results for \"\(searchText)\"")
            }
        } else {
            if !results.projects.isEmpty {
                Section("Projects") {
                    ForEach(results.projects) { project in
                        ProjectRow(project: project)
                    }
                }
            }
            if !results.conversations.isEmpty {
                Section("Conversations") {
                    ForEach(results.conversations) { conv in
                        ConversationRow(conversation: conv)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        Section {
            ForEach(appState.conversations.pinnedProjects) { project in
                ProjectRow(project: project)
            }
            ForEach(appState.conversations.pinnedStandaloneConversations) { conv in
                ConversationRow(conversation: conv)
            }
        } header: {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: "pin.fill")
                    .font(AppTypography.interfaceCaption2)
                Text("Pinned")
                    .font(AppTypography.interfaceCaption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSidebarView: View {
    @Binding var selection: AppScreen

    var body: some View {
        List(selection: $selection) {
            Button {
                Task { @MainActor in
                    selection = .chat
                }
            } label: {
                Label("Back to Limare", systemImage: "arrow.left")
            }
            .buttonStyle(.plain)
            .tag(AppScreen.chat)

            Section {
                Label("General", systemImage: "gearshape")
                    .tag(AppScreen.settingsGeneral)
                Label("Personalization", systemImage: "person.text.rectangle")
                    .tag(AppScreen.settingsSoul)
                Label("Permissions", systemImage: "lock.shield")
                    .tag(AppScreen.settingsPermissions)
                Label("Remote Access", systemImage: "iphone.and.arrow.forward")
                    .tag(AppScreen.settingsRemoteAccess)
            }

            Section("Models") {
                Label("Providers", systemImage: "server.rack")
                    .tag(AppScreen.settingsProviders)
                Label("Model Groups", systemImage: "square.stack.3d.up")
                    .tag(AppScreen.settingsModelGroups)
            }

            Section("Extensions") {
                Label("Skills", systemImage: "wand.and.stars")
                    .tag(AppScreen.settingsSkills)
                Label("MCP", systemImage: "network")
                    .tag(AppScreen.settingsMCP)
                Label("Hooks", systemImage: "arrow.triangle.branch")
                    .tag(AppScreen.settingsHooks)
            }

            Section("Advanced") {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
                    .tag(AppScreen.settingsLogs)
            }
        }
        .font(AppTypography.interface)
        .labelStyle(SettingsSidebarLabelStyle())
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }
}

private struct SettingsSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AppSpacing.small) {
            configuration.icon
                .foregroundStyle(.secondary)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}
