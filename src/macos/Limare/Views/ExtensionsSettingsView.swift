import SwiftUI
import AppKit

struct ExtensionsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var searchText = ""
    @AppStorage("extensions.cardSortOrder") private var sortOrder: ExtensionCardSortOrder = .name
    @State private var selectedCardID: String?
    @State private var selectedCardIDs: Set<String> = []
    @State private var selectingCards = false
    @State private var cardFrames: [String: CGRect] = [:]
    @State private var selectionOrigin: CGPoint?
    @State private var selectionRect: CGRect?
    @State private var bulkMessage: String?
    @State private var showAddMCPSheet = false
    @State private var reviewHookSource: HookSource?
    @State private var hookImportErrorMessage: String?
    @State private var hookImportErrorDetails: String?
    @State private var migrationError: String?
    @State private var migrationInProgress = false
    @State private var groupStore = ExtensionGroupStore()
    @State private var isUngroupedCollapsed = false
    @State private var showGroupEditorSheet = false
    @State private var editingGroupID: UUID?
    @State private var groupEditorNameDraft = ""
    @State private var groupEditorInitialCardIDs: [String] = []
    @State private var targetedDropSectionID: String?

    private var activeEffectiveWorkspaceURL: URL? {
        guard let activeID = window.conversationID else { return nil }
        return appState.conversations.effectiveWorkingDirectory(for: activeID)
    }

    private var allCards: [ExtensionCardItem] {
        ExtensionCardProjection.build(
            skills: appState.skills,
            mcp: appState.mcp,
            hooks: appState.hooks,
            computerUse: appState.computerUseActivation
        )
    }

    private var filteredCards: [ExtensionCardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [ExtensionCardItem]
        if query.isEmpty {
            matched = allCards
        } else {
            matched = allCards.filter { card in
                if card.title.localizedCaseInsensitiveContains(query) { return true }
                if card.description.localizedCaseInsensitiveContains(query) { return true }
                if card.linkedMCPServers.contains(where: { $0.id.localizedCaseInsensitiveContains(query) }) { return true }
                return false
            }
        }
        return ExtensionCardItem.sorted(matched, by: sortOrder)
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sections: [ExtensionGroupSection] {
        groupStore.buildSections(from: filteredCards, isFiltering: isFiltering)
    }

    var body: some View {
        SettingsPage {
            if appState.mcp.authorityState != .ready {
                InlineStatus(kind: .error, message: "\(appState.mcp.authorityState.message)")
            }
            if appState.mcp.authorityState == .recoveryRequired {
                Button("Retry MCP Recovery") { appState.mcp.retryRecovery() }
            }
            if appState.mcp.authorityState == .migrationRequired {
                Button(migrationInProgress ? "Migrating…" : "Migrate Existing MCP Configuration…") {
                    migrationInProgress = true
                    migrationError = nil
                    Task {
                        defer { migrationInProgress = false }
                        do { try await appState.mcp.migrateLegacyConfiguration() }
                        catch { migrationError = String(localized: "MCP migration did not complete. Original configuration and credentials were preserved.") }
                    }
                }
                .disabled(migrationInProgress)
            }
            if let migrationError { InlineStatus(kind: .error, message: "\(migrationError)") }
            if let admissionMessage = appState.mcp.runtimeAdmissionMessage {
                InlineStatus(kind: .warning, message: "\(admissionMessage)")
            }

            // Toolbar
            HStack(spacing: AppSpacing.small) {
                if selectingCards {
                    Button("Select All") {
                        selectedCardIDs.formUnion(filteredCards.map(\.id))
                    }
                    .buttonStyle(.settingsOutline)
                    .fixedSize()
                    .disabled(filteredCards.isEmpty)

                    Text("\(selectedCardIDs.count) selected")
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Enable") { applySelection(enabled: true) }
                        .buttonStyle(.settingsOutline)
                        .fixedSize()
                        .disabled(selectedCardIDs.isEmpty)
                    Button("Disable") { applySelection(enabled: false) }
                        .buttonStyle(.settingsOutline)
                        .fixedSize()
                        .disabled(selectedCardIDs.isEmpty)
                    moveToGroupSelectionMenu
                    Button("Cancel") { cancelSelection() }
                        .buttonStyle(.settingsOutline)
                        .fixedSize()
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    SettingsSearchField(text: $searchText, placeholder: "Search extensions…")
                        .frame(minWidth: 140, idealWidth: 210, maxWidth: 260)
                    Spacer()
                    Button("Select") { selectingCards = true }
                        .buttonStyle(.settingsOutline)
                        .fixedSize()
                    Button {
                        presentCreateGroup(initialCardIDs: [])
                    } label: {
                        Label(
                            String(localized: "extensions.newGroup", defaultValue: "New Group", comment: "Toolbar button to create an extension group"),
                            systemImage: "folder.badge.plus"
                        )
                    }
                    .buttonStyle(.settingsOutline)
                    .fixedSize()
                    sortMenu
                    Button {
                        refreshAll()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.settingsOutline)
                    .fixedSize()
                    .help("Rescan skills, reload hooks, and reconnect enabled MCP servers")
                    Menu {
                        Button {
                            openChatToConfigureExtension()
                        } label: {
                            Label("Ask Limare to Configure New Extension…", systemImage: "sparkles")
                        }
                        Divider()
                        Button {
                            showAddMCPSheet = true
                        } label: {
                            Label("Add MCP Connection Manually…", systemImage: "server.rack")
                        }
                        Button {
                            importHookPackage()
                        } label: {
                            Label("Import Hook Package…", systemImage: "arrow.triangle.branch")
                        }
                        Button {
                            openGlobalExtensionsFolder()
                        } label: {
                            Label("Open Global Extensions Folder in Finder", systemImage: "folder")
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("settings.extensions.addMenu")
                }
            }

            if let bulkMessage { InlineStatus(kind: .warning, message: "\(bulkMessage)") }

            if let hookImportErrorMessage {
                ThreeLevelErrorView(
                    explanation: "\(hookImportErrorMessage)",
                    recommendedAction: "Check that the selected folder contains a valid hooks.json configuration.",
                    technicalDetails: hookImportErrorDetails,
                    onRetry: {
                        self.hookImportErrorMessage = nil
                        self.hookImportErrorDetails = nil
                        importHookPackage()
                    },
                    retryTitle: "Try Again"
                )
            }

            // Card Grid (flat or sectioned by custom groups)
            if sections.isEmpty {
                ContentUnavailableView(
                    "No Matching Extensions",
                    systemImage: "puzzlepiece.extension",
                    description: Text(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No extensions match the selected filter."
                            : "No extensions match “\(searchText)”."
                    )
                )
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.large) {
                    ForEach(sections) { section in
                        sectionView(for: section)
                    }
                }
                .coordinateSpace(name: "extensionGrid")
                .contentShape(Rectangle())
                .onPreferenceChange(ExtensionCardFramesKey.self) { cardFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if let rect = selectionRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("extensionGrid"))
                        .onChanged { value in
                            if selectionOrigin == nil {
                                guard !cardFrames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                                selectionOrigin = value.startLocation
                                selectingCards = true
                            }
                            guard let origin = selectionOrigin else { return }
                            let rect = CGRect(x: min(origin.x, value.location.x), y: min(origin.y, value.location.y),
                                              width: abs(origin.x - value.location.x), height: abs(origin.y - value.location.y))
                            selectionRect = rect
                            selectedCardIDs = Set(cardFrames.compactMap { id, frame in rect.intersects(frame) ? id : nil })
                        }
                        .onEnded { _ in
                            selectionOrigin = nil
                            selectionRect = nil
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("extensionGrid"))
                        .onEnded { value in
                            if selectingCards && !cardFrames.values.contains(where: { $0.contains(value.location) }) {
                                cancelSelection()
                            }
                        }
                )
            }

            // Bottom Conversational Builder Guidance Banner
            HStack(spacing: AppSpacing.medium) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                    Text("Connect any tool by asking Limare")
                        .font(AppTypography.interfaceMedium)
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Need web scraping, GitHub, email, or another CLI/API? Describe what you want in chat and Limare will set it up as an Extension Card.")
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                Button("Configure in Chat") {
                    openChatToConfigureExtension()
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)
            }
            .padding(AppSpacing.medium)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                    .fill(AppColors.raisedSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                    .stroke(AppColors.hairline, lineWidth: 1)
            )
        }
        .accessibilityIdentifier("settings.extensions")
        .onAppear {
            syncExtensionReadiness()
        }
        .onChange(of: activeEffectiveWorkspaceURL) { _, _ in
            syncExtensionReadiness()
        }
        .sheet(isPresented: Binding(
            get: { selectedCardID != nil },
            set: { if !$0 { selectedCardID = nil } }
        )) {
            if let cardID = selectedCardID {
                ExtensionCardDetailSheet(
                    cardID: cardID,
                    onToggle: { card, enabled in handleToggle(for: card, isEnabled: enabled) }
                )
                .presentationSizing(.fitted)
            }
        }
        .sheet(isPresented: $showAddMCPSheet) {
            MCPServerEditSheet(
                existingConfig: nil,
                onSave: { newServer, clientSecret in
                    try await appState.mcp.saveConfiguration(newServer, clientSecret: clientSecret)
                },
                onImport: { jsonText in
                    try await appState.mcp.importJSON(jsonText)
                }
            )
        }
        .sheet(item: $reviewHookSource) { source in
            HookReviewSheet(
                source: source,
                onComplete: { reviewHookSource = nil },
                onCancel: { reviewHookSource = nil }
            )
        }
        .sheet(isPresented: $showGroupEditorSheet) {
            ExtensionGroupEditorSheet(
                isEditing: editingGroupID != nil,
                initialName: groupEditorNameDraft
            ) { submittedName in
                if let editingGroupID {
                    groupStore.renameGroup(id: editingGroupID, name: submittedName)
                } else {
                    groupStore.createGroup(name: submittedName, cardIDs: groupEditorInitialCardIDs)
                    if !groupEditorInitialCardIDs.isEmpty && selectingCards {
                        cancelSelection()
                    }
                }
            }
        }
    }

    // MARK: - Sectioned Layout

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(ExtensionCardSortOrder.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .fill(AppColors.workSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort extensions")
        .accessibilityLabel("Sort extensions")
    }

    @ViewBuilder
    private var moveToGroupSelectionMenu: some View {
        Menu {
            ForEach(groupStore.groups) { group in
                Button(group.name) {
                    groupStore.assignCards(Array(selectedCardIDs), toGroup: group.id)
                    cancelSelection()
                }
            }
            if !groupStore.groups.isEmpty {
                Button("Ungrouped") {
                    groupStore.assignCards(Array(selectedCardIDs), toGroup: nil)
                    cancelSelection()
                }
                Divider()
            }
            Button("New Group with Selection…") {
                presentCreateGroup(initialCardIDs: Array(selectedCardIDs))
            }
        } label: {
            HStack(spacing: 4) {
                Text("Move to Group")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(selectedCardIDs.isEmpty ? 0.45 : 0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .fill(AppColors.workSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(selectedCardIDs.isEmpty)
    }

    @ViewBuilder
    private func sectionView(for section: ExtensionGroupSection) -> some View {
        let isCollapsed = isSectionCollapsed(section)
        let isDropTarget = targetedDropSectionID == section.id

        let bodyContent = VStack(alignment: .leading, spacing: AppSpacing.small) {
            if section.kind != .flat {
                sectionHeader(for: section, isCollapsed: isCollapsed)
            }

            if !isCollapsed {
                if section.cards.isEmpty {
                    Text("Drag extension cards here or right-click a card to add it to this group.")
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, AppSpacing.large)
                        .padding(.horizontal, AppSpacing.medium)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .foregroundStyle(AppColors.hairline)
                        )
                } else {
                    cardGrid(for: section.cards)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard + 2, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.06) : Color.clear)
                .padding(-6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard + 2, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1.5)
                .padding(-6)
        )

        if section.kind == .flat {
            bodyContent
        } else {
            bodyContent
                .dropDestination(for: String.self) { droppedIDs, _ in
                    let targetGroupID: UUID?
                    switch section.kind {
                    case .custom(let groupID): targetGroupID = groupID
                    case .ungrouped: targetGroupID = nil
                    case .flat: return false
                    }
                    let idsToAssign: [String]
                    if let first = droppedIDs.first, selectedCardIDs.contains(first), !selectedCardIDs.isEmpty {
                        idsToAssign = Array(selectedCardIDs)
                    } else {
                        idsToAssign = droppedIDs
                    }
                    groupStore.assignCards(idsToAssign, toGroup: targetGroupID)
                    return !idsToAssign.isEmpty
                } isTargeted: { targeted in
                    if targeted {
                        targetedDropSectionID = section.id
                    } else if targetedDropSectionID == section.id {
                        targetedDropSectionID = nil
                    }
                }
        }
    }

    @ViewBuilder
    private func sectionHeader(for section: ExtensionGroupSection, isCollapsed: Bool) -> some View {
        let enabledCount = section.cards.filter(\.isEnabled).count

        HStack(spacing: AppSpacing.small) {
            Button {
                toggleSectionCollapsed(section)
            } label: {
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 12)

                    Text(section.title ?? "")
                        .font(AppTypography.interfaceHeadline)
                        .foregroundStyle(AppColors.textPrimary)

                    SettingsBadge("\(enabledCount)/\(section.cards.count)")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            if let group = section.group {
                let groupIndex = groupStore.groups.firstIndex(where: { $0.id == group.id })
                Menu {
                    Button("Rename Group…") {
                        presentRenameGroup(group)
                    }
                    Button("Move Up") {
                        groupStore.moveGroup(id: group.id, direction: -1)
                    }
                    .disabled(groupIndex == nil || groupIndex == 0)
                    Button("Move Down") {
                        groupStore.moveGroup(id: group.id, direction: 1)
                    }
                    .disabled(groupIndex == nil || groupIndex == groupStore.groups.count - 1)
                    Divider()
                    Button("Ungroup", role: .destructive) {
                        groupStore.deleteGroup(id: group.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, AppSpacing.xxSmall)
    }

    @ViewBuilder
    private func cardGrid(for cards: [ExtensionCardItem]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 290), spacing: AppSpacing.medium)],
            spacing: AppSpacing.medium
        ) {
            ForEach(cards) { card in
                ExtensionCardTileView(
                    card: card,
                    isSelecting: selectingCards,
                    isSelected: selectedCardIDs.contains(card.id),
                    onPrimaryAction: {
                        if selectingCards {
                            if !selectedCardIDs.insert(card.id).inserted {
                                selectedCardIDs.remove(card.id)
                            }
                        } else {
                            handleToggle(for: card, isEnabled: !card.isEnabled)
                        }
                    },
                    onOpenDetail: {
                        selectedCardID = card.id
                    }
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ExtensionCardFramesKey.self,
                            value: [card.id: proxy.frame(in: .named("extensionGrid"))]
                        )
                    }
                }
                .draggable(card.id)
                .contextMenu {
                    Button("View Details…") {
                        selectedCardID = card.id
                    }
                    Divider()
                    if selectedCardIDs.contains(card.id) {
                        Button("Enable Selected") {
                            applySelection(enabled: true, contextCard: card)
                        }
                        Button("Disable Selected") {
                            applySelection(enabled: false, contextCard: card)
                        }
                    } else {
                        let toggleLabel: LocalizedStringKey = card.isEnabled ? "Disable" : "Enable"
                        Button(toggleLabel) {
                            handleToggle(for: card, isEnabled: !card.isEnabled)
                        }
                    }
                    Divider()
                    let targetIDs = selectedCardIDs.contains(card.id) ? Array(selectedCardIDs) : [card.id]
                    let currentGroup = groupStore.currentGroupID(for: card.id)
                    Menu("Move to Group") {
                        ForEach(groupStore.groups) { group in
                            Button {
                                groupStore.assignCards(targetIDs, toGroup: group.id)
                                if selectedCardIDs.contains(card.id) { cancelSelection() }
                            } label: {
                                if !selectedCardIDs.contains(card.id) && currentGroup == group.id {
                                    Label(group.name, systemImage: "checkmark")
                                } else {
                                    Text(group.name)
                                }
                            }
                        }
                        if currentGroup != nil || (selectedCardIDs.contains(card.id) && !groupStore.groups.isEmpty) {
                            Button("Ungrouped") {
                                groupStore.assignCards(targetIDs, toGroup: nil)
                                if selectedCardIDs.contains(card.id) { cancelSelection() }
                            }
                        }
                        if !groupStore.groups.isEmpty {
                            Divider()
                        }
                        Button("New Group…") {
                            presentCreateGroup(initialCardIDs: targetIDs)
                        }
                    }
                }
            }
        }
    }

    private func isSectionCollapsed(_ section: ExtensionGroupSection) -> Bool {
        switch section.kind {
        case .flat:
            return false
        case .custom(let id):
            return groupStore.groups.first(where: { $0.id == id })?.isCollapsed ?? false
        case .ungrouped:
            return isUngroupedCollapsed
        }
    }

    private func toggleSectionCollapsed(_ section: ExtensionGroupSection) {
        withAnimation(AppMotion.resolved(AppMotion.layout)) {
            switch section.kind {
            case .flat:
                break
            case .custom(let id):
                groupStore.toggleCollapsed(id: id)
            case .ungrouped:
                isUngroupedCollapsed.toggle()
            }
        }
    }

    private func presentCreateGroup(initialCardIDs: [String]) {
        editingGroupID = nil
        groupEditorNameDraft = ""
        groupEditorInitialCardIDs = initialCardIDs
        showGroupEditorSheet = true
    }

    private func presentRenameGroup(_ group: ExtensionCustomGroup) {
        editingGroupID = group.id
        groupEditorNameDraft = group.name
        groupEditorInitialCardIDs = []
        showGroupEditorSheet = true
    }

    // MARK: - Actions

    private func cancelSelection() {
        selectingCards = false
        selectedCardIDs.removeAll()
        selectionOrigin = nil
        selectionRect = nil
    }

    private func applySelection(enabled: Bool, contextCard: ExtensionCardItem? = nil) {
        let cards: [ExtensionCardItem]
        if let contextCard, !selectedCardIDs.contains(contextCard.id) {
            cards = [contextCard]
        } else {
            cards = allCards.filter { selectedCardIDs.contains($0.id) }
        }
        setCards(cards, enabled: enabled)
        cancelSelection()
    }

    private func setCards(_ cards: [ExtensionCardItem], enabled: Bool) {
        var needsReview: [String] = []
        for card in cards {
            if enabled, case .standaloneHook(let sourceID) = card.origin,
               let source = appState.hooks.sources.first(where: { $0.id == sourceID }),
               !appState.hooks.isTrusted(source: source) {
                needsReview.append(card.title)
                continue
            }
            handleToggle(for: card, isEnabled: enabled)
        }
        bulkMessage = needsReview.isEmpty ? nil : String(localized: "Review these hooks before enabling: \(needsReview.joined(separator: ", "))")
    }

    private func handleToggle(for card: ExtensionCardItem, isEnabled: Bool) {
        switch card.origin {
        case .builtInComputerUse:
            guard card.isEnabled != isEnabled else { return }
            Task {
                await appState.computerUseActivation.setGloballyEnabled(isEnabled)
            }
        case .skill(let skillID):
            if card.primarySkill?.isEnabled != isEnabled {
                appState.skills.setEnabled(isEnabled, for: skillID)
            }
            for server in card.linkedMCPServers where server.enabled != isEnabled {
                appState.mcp.setEnabled(isEnabled, for: server.id)
            }
        case .standaloneMCP(let serverID):
            if card.isEnabled != isEnabled { appState.mcp.setEnabled(isEnabled, for: serverID) }
        case .standaloneHook(let sourceID):
            guard let source = appState.hooks.sources.first(where: { $0.id == sourceID }) else { return }
            if isEnabled && !appState.hooks.isTrusted(source: source) {
                reviewHookSource = source
                return
            }
            if source.isEnabled != isEnabled {
                appState.hooks.toggleSource(sourceID: sourceID)
            }
        }
    }

    private func syncExtensionReadiness() {
        appState.computerUseActivation.refreshReadiness()
        let targetWorkspace = activeEffectiveWorkspaceURL ?? appState.workspace.url
        if appState.skills.workspaceURL != targetWorkspace {
            appState.skills.rescan(workspaceURL: targetWorkspace)
        }
    }

    private func refreshAll() {
        appState.skills.rescan(workspaceURL: activeEffectiveWorkspaceURL ?? appState.workspace.url)
        appState.hooks.reloadAll()
        for server in appState.mcp.servers where server.enabled {
            Task {
                try? await appState.mcp.performRuntimeAction(
                    "reconnect",
                    serverID: server.id,
                    expectedRevision: appState.mcp.configurationRevision,
                    requestID: UUID()
                )
            }
        }
    }

    private func openChatToConfigureExtension() {
        let conversation = appState.conversations.newConversation(projectID: nil, reuseEmpty: false)
        window.show(conversation)
        window.openChatWithPrompt(String(localized: "I want to connect an external tool: "))
    }

    private func importHookPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a hooks.json file or a package folder containing hooks/hooks.json")
        panel.prompt = String(localized: "Import")

        if panel.runModal() == .OK, let url = panel.url {
            do {
                hookImportErrorMessage = nil
                hookImportErrorDetails = nil
                let imported = try appState.hooks.importPackage(from: url)
                reviewHookSource = imported
            } catch {
                hookImportErrorMessage = String(localized: "Hook package could not be imported.")
                hookImportErrorDetails = error.localizedDescription
            }
        }
    }

    private func openGlobalExtensionsFolder() {
        let dirURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".limare/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dirURL)
    }
}

private struct ExtensionCardFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - 3D Tilt Extension Card Tile

private struct ExtensionCardTileView: View {
    let card: ExtensionCardItem
    let isSelecting: Bool
    let isSelected: Bool
    let onPrimaryAction: () -> Void
    let onOpenDetail: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var isHoveringDetailButton = false
    @State private var tiltUnit: UnitPoint = .center
    @State private var glareUnit: UnitPoint = .center
    @State private var cardSize: CGSize = CGSize(width: 250, height: 96)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var isAttentionRequired: Bool {
        if case .needsAttention = card.readiness { return true }
        return false
    }

    private var shouldTilt: Bool {
        isHovering && !isSelecting && !reduceMotion
    }

    var body: some View {
        // Outer flat wrapper owns pointer tracking so rotating edges never slip out from under the cursor.
        tiltingCard
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { cardSize = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in cardSize = newSize }
                }
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let px = min(1.0, max(0.0, cardSize.width > 0 ? location.x / cardSize.width : 0.5))
                    let py = min(1.0, max(0.0, cardSize.height > 0 ? location.y / cardSize.height : 0.5))
                    let point = UnitPoint(x: px, y: py)
                    glareUnit = point
                    if reduceMotion {
                        isHovering = true
                        tiltUnit = point
                    } else {
                        withAnimation(.interactiveSpring(response: 0.13, dampingFraction: 0.66, blendDuration: 0.06)) {
                            isHovering = true
                            tiltUnit = point
                        }
                    }
                case .ended:
                    if reduceMotion {
                        isHovering = false
                        tiltUnit = .center
                        glareUnit = .center
                    } else {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) {
                            isHovering = false
                            tiltUnit = .center
                        }
                    }
                }
            }
            .zIndex(isHovering ? 10 : 0)
            .accessibilityElement(children: .contain)
    }

    private var tiltingCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
        let dx = shouldTilt ? (tiltUnit.x - 0.5) * 2.0 : 0.0
        let dy = shouldTilt ? (tiltUnit.y - 0.5) * 2.0 : 0.0
        let maxDegrees: Double = card.isEnabled ? 18.0 : 9.0
        let rotateX = -dy * maxDegrees
        let rotateY = dx * maxDegrees

        return VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(alignment: .top) {
                extensionIconBadge(
                    card: card,
                    size: 36,
                    cornerRadius: AppRadius.card,
                    fontSize: 16,
                    isDesaturated: !card.isEnabled
                )
                .offset(x: shouldTilt ? dx * 4.5 : 0, y: shouldTilt ? dy * 4.5 : 0)

                Spacer()

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isSelected ? AppColors.statusInfo : AppColors.textSecondary)
                        .frame(height: 24)
                } else {
                    Color.clear
                        .frame(width: 48, height: 24)
                }
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(card.title)
                    .font(AppTypography.interfaceMedium)
                    .foregroundStyle(card.isEnabled ? AppColors.textPrimary : AppColors.textSecondary)
                    .lineLimit(1)

                Text(card.subtitle)
                    .font(AppTypography.interfaceSecondary)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            .offset(x: shouldTilt ? dx * 2.5 : 0, y: shouldTilt ? dy * 2.5 : 0)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            cardShape
                .fill(cardBackgroundColor)
                .shadow(
                    color: card.isEnabled
                        ? .black.opacity(isHovering ? 0.18 : 0.035)
                        : (isHovering ? .black.opacity(0.077) : .clear),
                    radius: isHovering ? 22 : 5,
                    x: shouldTilt ? -dx * 11.0 : 0,
                    y: shouldTilt ? 8.0 - dy * 7.37 : 2
                )
                .shadow(
                    color: (isHovering && card.isEnabled)
                        ? card.color.iconForeground.opacity(colorScheme == .dark ? 0.28 : 0.16)
                        : .clear,
                    radius: isHovering ? 16 : 0,
                    x: shouldTilt ? -dx * 6.16 : 0,
                    y: shouldTilt ? 4.0 - dy * 4.84 : 0
                )
        )
        .overlay {
            if shouldTilt {
                glareOverlay(dx: dx, dy: dy)
                    .clipShape(cardShape)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay {
            if shouldTilt {
                cardShape
                    .strokeBorder(rimLightGradient, lineWidth: 1.5)
            } else {
                cardShape
                    .strokeBorder(cardBorderColor, lineWidth: isSelecting && isSelected ? 1.5 : 1)
            }
        }
        .contentShape(cardShape)
        .onTapGesture {
            onPrimaryAction()
        }
        .overlay(alignment: .topTrailing) {
            if !isSelecting {
                HStack(spacing: AppSpacing.xSmall) {
                    readinessIndicator
                    detailButton
                }
                .offset(x: shouldTilt ? dx * 3.5 : 0, y: shouldTilt ? dy * 3.5 : 0)
                .padding(AppSpacing.medium)
            }
        }
        .rotation3DEffect(.degrees(rotateX), axis: (x: 1, y: 0, z: 0), perspective: 0.80)
        .rotation3DEffect(.degrees(rotateY), axis: (x: 0, y: 1, z: 0), perspective: 0.80)
        .scaleEffect(shouldTilt ? 1.038 : 1.0)
        .offset(y: shouldTilt ? -3.0 : 0)
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76),
            value: shouldTilt
        )
    }

    private var detailButton: some View {
        Button {
            onOpenDetail()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHoveringDetailButton ? AppColors.textPrimary : AppColors.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(Color.primary.opacity(isHoveringDetailButton ? 0.10 : 0.05))
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHoveringDetailButton = $0 }
        .opacity(isHovering || isAttentionRequired ? 1 : 0)
        .allowsHitTesting(isHovering || isAttentionRequired)
        .help(String(localized: "Extension Details"))
        .accessibilityLabel(String(localized: "Extension Details"))
    }

    @ViewBuilder
    private func glareOverlay(dx: Double, dy: Double) -> some View {
        let sheenStart = UnitPoint(x: 0.5 - dx * 0.55, y: 0.5 - dy * 0.55)
        let sheenEnd = UnitPoint(x: 0.5 + dx * 0.55, y: 0.5 + dy * 0.55)

        if colorScheme == .dark {
            ZStack {
                RadialGradient(
                    colors: [
                        Color.white.opacity(card.isEnabled ? 0.36 : 0.15),
                        Color.white.opacity(card.isEnabled ? 0.12 : 0.05),
                        card.color.glareTint.opacity(card.isEnabled ? 0.09 : 0.0),
                        .clear
                    ],
                    center: glareUnit,
                    startRadius: 2,
                    endRadius: 240
                )
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(card.isEnabled ? 0.18 : 0.065),
                        .clear
                    ],
                    startPoint: sheenStart,
                    endPoint: sheenEnd
                )
            }
            .blendMode(.screen)
        } else {
            let tint = card.isEnabled ? card.color.glareTint : Color.primary
            ZStack {
                RadialGradient(
                    colors: [
                        Color.white.opacity(card.isEnabled ? 0.42 : 0.18),
                        tint.opacity(card.isEnabled ? 0.113 : 0.048),
                        tint.opacity(card.isEnabled ? 0.029 : 0.012),
                        .clear
                    ],
                    center: glareUnit,
                    startRadius: 2,
                    endRadius: 240
                )
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(card.isEnabled ? 0.40 : 0.14),
                        .clear
                    ],
                    startPoint: sheenStart,
                    endPoint: sheenEnd
                )
            }
        }
    }

    private var rimLightGradient: RadialGradient {
        let highlightColor: Color
        if card.isEnabled {
            highlightColor = colorScheme == .dark
                ? Color.white.opacity(0.42)
                : card.color.iconForeground.opacity(0.44)
        } else {
            highlightColor = Color.primary.opacity(colorScheme == .dark ? 0.23 : 0.15)
        }
        return RadialGradient(
            colors: [highlightColor, cardBorderColor],
            center: glareUnit,
            startRadius: 8,
            endRadius: 230
        )
    }

    private var cardBackgroundColor: Color {
        if card.isEnabled {
            return AppColors.workSurface
        }
        return Color.primary.opacity(isHovering ? 0.04 : 0.022)
    }

    private var cardBorderColor: Color {
        if isSelecting && isSelected {
            return Color.accentColor.opacity(0.85)
        }
        if card.isEnabled {
            return isHovering ? card.color.hoverStroke : AppColors.cardStroke
        }
        return Color.primary.opacity(isHovering ? 0.12 : 0.055)
    }

    @ViewBuilder
    private var readinessIndicator: some View {
        switch card.readiness {
        case .needsAttention(let reason):
            Circle()
                .fill(AppColors.statusWarning)
                .frame(width: 7, height: 7)
                .help(reason)
        case .connecting:
            ProgressView()
                .controlSize(.mini)
        case .ready, .disabled:
            EmptyView()
        }
    }

    private var subtitleColor: Color {
        if case .needsAttention = card.readiness {
            return AppColors.cautionIcon
        }
        return card.isEnabled ? AppColors.textSecondary : AppColors.textMuted
    }
}

// MARK: - Group Editor Sheet

private struct ExtensionGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let isEditing: Bool
    let initialName: String
    let onSubmit: (String) -> Void

    @State private var groupName: String
    @FocusState private var isNameFocused: Bool

    init(isEditing: Bool, initialName: String, onSubmit: @escaping (String) -> Void) {
        self.isEditing = isEditing
        self.initialName = initialName
        self.onSubmit = onSubmit
        self._groupName = State(initialValue: initialName)
    }

    private var trimmedName: String {
        groupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let titleText = isEditing
            ? String(localized: "Rename Group")
            : String(localized: "extensions.newGroup", defaultValue: "New Group", comment: "Sheet title when creating an extension group")
        let submitKey: LocalizedStringKey = isEditing ? "Save" : "Create"

        VStack(spacing: AppSpacing.medium) {
            Text(titleText)
                .font(.headline)

            FormField("Name") {
                TextField("e.g. Coding, Research, Daily Tools", text: $groupName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit { submit() }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(submitKey) {
                    submit()
                }
                .buttonStyle(.charcoalProminent)
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppSpacing.small)
        }
        .padding(AppSpacing.large)
        .frame(width: 380)
        .onAppear {
            isNameFocused = true
        }
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onSubmit(trimmedName)
        dismiss()
    }
}
