import SwiftUI
import AppKit

enum ExtensionFilterScope: String, CaseIterable, Hashable {
    case all
    case enabled
    case project

    var displayName: String {
        switch self {
        case .all: String(localized: "All")
        case .enabled: String(localized: "Enabled")
        case .project: String(localized: "Current Project")
        }
    }
}

struct ExtensionsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var searchText = ""
    @State private var filterScope: ExtensionFilterScope = .all
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
        return allCards.filter { card in
            switch filterScope {
            case .all:
                break
            case .enabled:
                guard card.isEnabled else { return false }
            case .project:
                guard card.isWorkspaceScoped else { return false }
            }

            guard !query.isEmpty else { return true }
            if card.title.localizedCaseInsensitiveContains(query) { return true }
            if card.description.localizedCaseInsensitiveContains(query) { return true }
            if card.linkedMCPServers.contains(where: { $0.id.localizedCaseInsensitiveContains(query) }) { return true }
            return false
        }
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
            HStack(spacing: AppSpacing.medium) {
                if selectingCards {
                    Button("Select All") {
                        selectedCardIDs.formUnion(filteredCards.map(\.id))
                    }
                    .buttonStyle(.settingsOutline)
                    .disabled(filteredCards.isEmpty)

                    Text("\(selectedCardIDs.count) selected")
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Button("Enable") { applySelection(enabled: true) }
                        .buttonStyle(.settingsOutline)
                        .disabled(selectedCardIDs.isEmpty)
                    Button("Disable") { applySelection(enabled: false) }
                        .buttonStyle(.settingsOutline)
                        .disabled(selectedCardIDs.isEmpty)
                    Button("Cancel") { cancelSelection() }
                        .buttonStyle(.settingsOutline)
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    SettingsSearchField(text: $searchText, placeholder: "Search extensions…")
                        .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
                    SettingsSegmentedPicker(
                        selection: $filterScope,
                        options: ExtensionFilterScope.allCases.map { (value: $0, title: $0.displayName) }
                    )
                    .fixedSize()
                    .accessibilityLabel("Scope")
                    Spacer()
                    Button("Select") { selectingCards = true }
                        .buttonStyle(.settingsOutline)
                    Button {
                        refreshAll()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.settingsOutline)
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

            // Card Grid
            if filteredCards.isEmpty {
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
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 290), spacing: AppSpacing.medium)],
                    spacing: AppSpacing.medium
                ) {
                    ForEach(filteredCards) { card in
                        ExtensionCardTileView(
                            card: card,
                            isSelecting: selectingCards,
                            isSelected: selectedCardIDs.contains(card.id),
                            onSelect: {
                                if selectingCards {
                                    if !selectedCardIDs.insert(card.id).inserted { selectedCardIDs.remove(card.id) }
                                } else { selectedCardID = card.id }
                            },
                            onToggle: { enabled in handleToggle(for: card, isEnabled: enabled) }
                        )
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ExtensionCardFramesKey.self,
                                    value: [card.id: proxy.frame(in: .named("extensionGrid"))]
                                )
                            }
                        }
                        .contextMenu {
                            Button(selectedCardIDs.contains(card.id) ? "Enable Selected" : "Enable") {
                                applySelection(enabled: true, contextCard: card)
                            }
                            Button(selectedCardIDs.contains(card.id) ? "Disable Selected" : "Disable") {
                                applySelection(enabled: false, contextCard: card)
                            }
                        }
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

// MARK: - Sticky Note Card Tile

private struct ExtensionCardTileView: View {
    let card: ExtensionCardItem
    let isSelecting: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(alignment: .top) {
                extensionIconBadge(card: card, size: 36, cornerRadius: AppRadius.card, fontSize: 16)

                Spacer()

                HStack(spacing: AppSpacing.xSmall) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? AppColors.statusInfo : AppColors.textSecondary)
                    } else {
                        readinessIndicator
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { card.isEnabled },
                                set: { onToggle($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(card.title)
                    .font(AppTypography.interfaceMedium)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Text(card.subtitle)
                    .font(AppTypography.interfaceSecondary)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                .fill(card.color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                .stroke(isHovering ? AppColors.composerStroke : AppColors.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { onSelect() }
        .opacity(card.isEnabled ? 1.0 : 0.78)
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
        return AppColors.textSecondary
    }
}
