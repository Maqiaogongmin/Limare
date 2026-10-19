import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var isCreatingProject = false
    @State private var isViewingArchived = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar

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
            // No rules above or below the list: rows cut off at either end fade out instead.
            // The last row scrolls clear of the bottom fade.
            .contentMargins(.bottom, AppSpacing.xLarge, for: .scrollContent)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: AppSpacing.small)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: AppSpacing.xLarge)
                }
            )
            .accessibilityIdentifier("conversation.sidebar")

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
                // Takes the row ahead of the container's own trailing spacer, so the count sits
                // at the right edge.
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: "archivebox")
                        .font(AppTypography.interfaceSubheadline)
                        .foregroundStyle(Color.secondary)
                    Text("Archived")
                        .font(AppTypography.interfaceSubheadline)
                        .lineLimit(1)
                        .foregroundStyle(Color.primary.opacity(0.88))
                    Spacer(minLength: AppSpacing.small)
                    if !appState.conversations.archivedConversations.isEmpty {
                        Text("\(appState.conversations.archivedConversations.count)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, AppSpacing.xSmall)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
            }

            SidebarRowContainer(
                isSelected: false,
                onSelect: {
                    Task { @MainActor in
                        window.screen = .settingsGeneral
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
                appState.focus(window)
                appState.newConversation(in: window)
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
                // A raised card, a step above the search field under it.
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .fill(AppColors.raisedSurface)
                        .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                        .strokeBorder(AppColors.raisedStroke, lineWidth: 1)
                )
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
        List {
            // A white capsule with a hairline edge, apart from the pages below it.
            Button {
                Task { @MainActor in
                    selection = .chat
                }
            } label: {
                // The icon set apart from the Label: a list tints a row's label icon blue.
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: "arrow.left")
                    Text("Back to Limare")
                }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, AppSpacing.medium)
                    .frame(height: 28)
                    .background(Capsule().fill(AppColors.raisedSurface))
                    .overlay(Capsule().strokeBorder(AppColors.raisedStroke, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, AppSpacing.small)

            Section {
                row("General", systemImage: "gearshape", screen: .settingsGeneral)
                row("Personalization", systemImage: "person.text.rectangle", screen: .settingsSoul)
                row("Permissions", systemImage: "lock.shield", screen: .settingsPermissions)
                row("Remote Access", systemImage: "iphone.and.arrow.forward", screen: .settingsRemoteAccess)
            }

            Section("Models") {
                row("Providers", systemImage: "server.rack", screen: .settingsProviders)
                row("Model Groups", systemImage: "square.stack.3d.up", screen: .settingsModelGroups)
            }

            Section("Extensions") {
                row("Skills", systemImage: "wand.and.stars", screen: .settingsSkills)
                row("MCP", systemImage: "network", screen: .settingsMCP)
                row("Hooks", systemImage: "arrow.triangle.branch", screen: .settingsHooks)
            }

            Section("Advanced") {
                row("Logs", systemImage: "doc.text.magnifyingglass", screen: .settingsLogs)
            }
        }
        .font(AppTypography.interface)
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }

    /// A page, drawn as the chat sidebar draws its rows: the selected one on a warm tint in
    /// full-strength semibold text, the others quieter; no system selection blue.
    private func row(_ title: String, systemImage: String, screen: AppScreen) -> some View {
        SettingsSidebarRow(title: title, systemImage: systemImage, isSelected: selection == screen) {
            selection = screen
        }
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
                .fontWeight(isSelected ? .semibold : .regular)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.68))
        .padding(.horizontal, AppSpacing.small)
        .frame(height: AppControlHeight.row)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.07) : (isHovering ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }
}
