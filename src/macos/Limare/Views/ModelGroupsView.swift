import SwiftUI

struct ModelGroupsView: View {
    @Environment(AppState.self) private var appState
    @State private var state = ModelGroupsSettingsState()

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane

            detailPane
                .frame(
                    minWidth: AppLayout.settingsDetailMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .sheet(isPresented: $state.showCreateGroupSheet) {
            NewModelGroupSheet(state: state)
        }
        .sheet(isPresented: $state.showSpecialistModelsSheet) {
            SpecialistModelsSheet()
        }
        .sheet(isPresented: $state.showAddModelsSheet) {
            if case .group(let gid) = state.selection,
               let group = appState.modelGroups.group(for: gid) {
                AddModelsToGroupSheet(group: group)
            }
        }
        .confirmationDialog(
            "Delete Model Group?",
            isPresented: Binding(
                get: { state.pendingDeleteGroupID != nil },
                set: { if !$0 { state.pendingDeleteGroupID = nil } }
            )
        ) {
            Button("Delete Group", role: .destructive) {
                if let gid = state.pendingDeleteGroupID {
                    appState.modelGroups.removeGroup(gid)
                    if case .group(let currentID) = state.selection, currentID == gid {
                        if let nextID = appState.modelGroups.groups.first?.id {
                            state.selection = .group(nextID)
                        } else {
                            state.selection = .modelUse
                        }
                    }
                    state.pendingDeleteGroupID = nil
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingDeleteGroupID = nil
            }
        } message: {
            if let gid = state.pendingDeleteGroupID, let group = appState.modelGroups.group(for: gid) {
                Text("Delete “\(group.name)”?\n\nThis removes the group. The models themselves are not deleted. Any defaults using this group will be cleared.")
            } else {
                Text("This removes the group. The models themselves are not deleted. Any defaults using this group will be cleared.")
            }
        }
    }

    // MARK: - Left Sidebar

    // The page title already says Model Groups; the list's header holds only its add button.
    private var sidebarPane: some View {
        SettingsMasterList {
            HStack {
                Spacer()
                Button {
                    state.showCreateGroupSheet = true
                } label: {
                    Label("New Group", systemImage: "plus")
                }
                .buttonStyle(.settingsOutline)
                .help("Create a new Model Group")
            }
        } content: {
            masterSectionLabel("Model Settings")
            SettingsMasterRow(isSelected: state.selection == .modelUse, onSelect: { state.selection = .modelUse }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Use")
                        .font(AppTypography.interface.weight(state.selection == .modelUse ? .semibold : .regular))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Chat, images, voice & extra help")
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .padding(.horizontal, AppSemanticSpacing.resourceListRowPaddingHorizontal)
                .padding(.vertical, AppSemanticSpacing.resourceListRowPaddingVertical)
            }

            masterSectionLabel("Groups")
                .padding(.top, AppSpacing.small)
            if appState.modelGroups.groups.isEmpty {
                Text("No Groups Yet")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.medium)
            } else {
                ForEach(Array(appState.modelGroups.groups.enumerated()), id: \.element.id) { index, group in
                    let selection = ModelGroupsSelection.group(group.id)
                    SettingsMasterRow(isSelected: state.selection == selection, onSelect: { state.selection = selection }) {
                        GroupSidebarRow(group: group, state: state, isSelected: state.selection == selection)
                    }
                    .contextMenu {
                        Button("Move Up") {
                            moveGroup(from: index, to: index - 1)
                        }
                        .disabled(index == 0)

                        Button("Move Down") {
                            moveGroup(from: index, to: index + 1)
                        }
                        .disabled(index >= appState.modelGroups.groups.count - 1)

                        Divider()

                        Button("Delete Group…", role: .destructive) {
                            state.pendingDeleteGroupID = group.id
                        }
                    }
                }
            }
        }
    }

    /// A small caption over a part of the list, in place of a List section header.
    private func masterSectionLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(AppTypography.interfaceCaption.weight(.semibold))
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, AppSpacing.small)
            .padding(.top, AppSpacing.xxSmall)
            .accessibilityAddTraits(.isHeader)
    }

    private func moveGroup(from source: Int, to destination: Int) {
        guard source >= 0, source < appState.modelGroups.groups.count,
              destination >= 0, destination < appState.modelGroups.groups.count else { return }
        var ids = appState.modelGroups.groups.map(\.id)
        let moved = ids.remove(at: source)
        ids.insert(moved, at: destination)
        appState.modelGroups.reorderGroups(ids)
    }

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        switch state.selection {
        case .modelUse:
            ModelUseView(state: state)
        case .group(let groupID):
            if let group = appState.modelGroups.group(for: groupID) {
                ModelGroupDetailView(group: group, state: state)
            } else {
                ContentUnavailableView(
                    "Select a Model Group",
                    systemImage: "square.stack.3d.up",
                    description: Text("Choose a group from the list or configure Model Use.")
                )
            }
        }
    }
}

// MARK: - Group Sidebar Row

private struct GroupSidebarRow: View {
    @Environment(AppState.self) private var appState
    let group: ModelGroup
    let state: ModelGroupsSettingsState
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppSpacing.xSmall) {
                Text(group.name)
                    .font(AppTypography.interface.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer()

                ForEach(state.roleBadges(for: group, store: appState.modelGroups), id: \.self) { badge in
                    SettingsBadge(badge)
                }
            }

            Text(state.summary(for: group))
                .font(AppTypography.interfaceCaption2)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, AppSemanticSpacing.resourceListRowPaddingHorizontal)
        .padding(.vertical, AppSemanticSpacing.resourceListRowPaddingVertical)
    }
}

// MARK: - Model Use View

private struct ModelUseView: View {
    @Environment(AppState.self) private var appState
    let state: ModelGroupsSettingsState

    var body: some View {
        SettingsPage {
            // Common Tasks Section
            SettingsSection(title: "Common Tasks") {
                // Chat Role
                SettingsRow(
                    "Chat",
                    caption: "Default model group for new conversations."
                ) {
                    groupPicker(
                        selection: Binding(
                            get: { appState.modelGroups.defaultPrimaryGroupId },
                            set: { appState.modelGroups.defaultPrimaryGroupId = $0 }
                        ),
                        placeholder: "None"
                    )
                }

                SettingsDivider()

                // Images Role
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    SettingsRow(
                        "Images",
                        caption: "Used when Limare needs to understand images."
                    ) {
                        groupPicker(
                            selection: Binding(
                                get: { appState.modelGroups.visionGroupId },
                                set: { appState.modelGroups.visionGroupId = $0 }
                            ),
                            placeholder: "None"
                        )
                    }

                    if let note = state.imagesStatus(
                        for: appState.modelGroups.visionGroupId,
                        store: appState.modelGroups,
                        providers: appState.providers.providers
                    ) {
                        InlineStatus(kind: .warning, message: "\(note)")
                    }
                }

                SettingsDivider()

                // Voice Input Role
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    SettingsRow(
                        "Voice Input",
                        caption: "Speech recognition with automatic system voice fallback."
                    ) {
                        groupPicker(
                            selection: Binding(
                                get: { appState.modelGroups.voiceInputGroupId },
                                set: { appState.modelGroups.voiceInputGroupId = $0 }
                            ),
                            placeholder: "System Speech (Auto)"
                        )
                    }

                    if let note = state.voiceInputStatus(
                        for: appState.modelGroups.voiceInputGroupId,
                        store: appState.modelGroups,
                        providers: appState.providers.providers
                    ) {
                        InlineStatus(kind: .info, message: "\(note)")
                    }
                }

                SettingsDivider()

                // Voice Output Role
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    SettingsRow(
                        "Voice Output",
                        caption: "Text-to-speech with automatic system voice fallback."
                    ) {
                        groupPicker(
                            selection: Binding(
                                get: { appState.modelGroups.voiceOutputGroupId },
                                set: { appState.modelGroups.voiceOutputGroupId = $0 }
                            ),
                            placeholder: "System Voice (Auto)"
                        )
                    }

                    if let note = state.voiceOutputStatus(
                        for: appState.modelGroups.voiceOutputGroupId,
                        store: appState.modelGroups,
                        providers: appState.providers.providers
                    ) {
                        InlineStatus(kind: .info, message: "\(note)")
                    }
                }
            }

            // Extra Help Section (Optional)
            SettingsSection(
                title: "Extra Help",
                description: "Optional. Limare works normally with the defaults below."
            ) {
                // Helper Model Row
                SettingsRow(
                    "Helper model",
                    caption: "Default for helper work in new conversations."
                ) {
                    groupPicker(
                        selection: Binding(
                            get: { appState.modelGroups.defaultSubGroupId },
                            set: { appState.modelGroups.defaultSubGroupId = $0 }
                        ),
                        placeholder: "Same as Chat"
                    )
                }

                SettingsDivider()

                // Specialist Models Row
                SettingsRow(
                    "Specialist models",
                    caption: "Optional models Limare may call directly for specialized jobs, such as image generation."
                ) {
                    HStack(spacing: AppSpacing.medium) {
                        Text(state.specialistSummary(store: appState.modelGroups))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.textSecondary)

                        Button("Manage…") {
                            state.showSpecialistModelsSheet = true
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func groupPicker(selection: Binding<String?>, placeholder: LocalizedStringKey) -> some View {
        Picker("", selection: selection) {
            Text(placeholder).tag(nil as String?)
            ForEach(appState.modelGroups.groups) { grp in
                Text(grp.name).tag(grp.id as String?)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 220, alignment: .trailing)
        .labelsHidden()
    }
}

// MARK: - Model Group Detail View

private struct ModelGroupDetailView: View {
    @Environment(AppState.self) private var appState
    let group: ModelGroup
    let state: ModelGroupsSettingsState

    @State private var draftName: String = ""
    @State private var isAdvancedExpanded = false

    var body: some View {
        SettingsPage {
            // Header Section: Name, Summary & Actions
            headerSection

            // Section 1: Models (Visual Core)
            modelsSection

            // Section 2: Routing
            routingSection

            // Section 3: Reasoning
            reasoningSection

            // Section 4: Advanced
            advancedSection
        }
        .onAppear {
            draftName = group.name
        }
        .onChange(of: group.name) {
            draftName = group.name
        }
    }

    // MARK: Header Section

    private var headerSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(alignment: .center, spacing: AppSpacing.medium) {
                    TextField("Group Name", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.weight(.semibold))
                        .onSubmit {
                            saveName()
                        }

                    if draftName.trimmingCharacters(in: .whitespacesAndNewlines) != group.name &&
                       !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Save") {
                            saveName()
                        }
                        .buttonStyle(.charcoalProminent)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("Delete Group…", role: .destructive) {
                        state.pendingDeleteGroupID = group.id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(AppColors.statusError)
                }

                HStack(spacing: AppSpacing.small) {
                    Text(state.summary(for: group))
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)

                    ForEach(state.roleBadges(for: group, store: appState.modelGroups), id: \.self) { badge in
                        SettingsBadge(badge)
                    }
                }
            }
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        var updated = group
        updated.name = trimmed
        appState.modelGroups.updateGroup(updated)
    }

    // MARK: Models Section

    private var modelsSection: some View {
        SettingsSection(
            title: "Models",
            description: group.strategy == .fallback
                ? "Models are tried in priority order from top to bottom."
                : "Conversations are distributed across available models."
        ) {
            let members = state.resolvedMembers(for: group, providers: appState.providers.providers, store: appState.modelGroups)

            if members.isEmpty {
                VStack(spacing: AppSpacing.small) {
                    Text("No Models Yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                    Text("Add models to define how this group works.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)

                    Button {
                        state.showAddModelsSheet = true
                    } label: {
                        Label("Add Models", systemImage: "plus")
                    }
                    .buttonStyle(.charcoalProminent)
                    .controlSize(.small)
                    .padding(.top, AppSpacing.xxSmall)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.medium)
            } else {
                VStack(spacing: AppSpacing.xSmall) {
                    ForEach(members) { item in
                        memberRow(item: item, totalCount: members.count)
                    }

                    SettingsDivider()
                        .padding(.vertical, AppSpacing.xxSmall)

                    HStack {
                        Spacer()
                        Button {
                            state.showAddModelsSheet = true
                        } label: {
                            Label("Add Models", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func memberRow(item: GroupMemberDisplayItem, totalCount: Int) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            Text("\(item.index).")
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(item.modelName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item.isAvailable ? AppColors.textPrimary : AppColors.textSecondary)
                        .lineLimit(1)

                    if item.isUnbound {
                        SettingsBadge("Unassigned")
                        ForEach(item.knownCapabilities, id: \.self) { cap in
                            SettingsBadge(cap)
                        }
                    } else if !item.roleStatuses.isEmpty {
                        ForEach(item.roleStatuses.indices, id: \.self) { idx in
                            roleStatusBadge(item.roleStatuses[idx])
                        }
                    } else {
                        if item.isAvailable {
                            SettingsBadge("Ready for Chat", tone: .positive)
                        } else {
                            SettingsBadge(item.unavailableReason ?? String(localized: "Not Ready for Chat"))
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(item.providerName)
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)

                    if !item.isAvailable, let reason = item.unavailableReason {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textMuted)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(AppColors.statusWarning)
                        Text(reason)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(AppColors.statusWarning)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Controls
            HStack(spacing: 2) {
                Button {
                    moveMember(from: item.index - 1, to: item.index - 2)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(item.index == 1)
                .help("Move Up")

                Button {
                    moveMember(from: item.index - 1, to: item.index)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(item.index == totalCount)
                .help("Move Down")

                Button(role: .destructive) {
                    removeMember(at: item.index - 1)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(AppColors.statusError)
                }
                .buttonStyle(.plain)
                .help("Remove from Group")
                .padding(.leading, 6)
            }
        }
        .padding(.vertical, AppSemanticSpacing.settingsRowVerticalPadding)
    }

    @ViewBuilder
    private func roleStatusBadge(_ status: RoleMemberStatusItem) -> some View {
        switch status.readiness {
        case .ready:
            SettingsBadge(status.readiness.label, tone: .positive)
        case .capabilityUnknown:
            SettingsBadge(status.readiness.label)
        case .protocolUnsupported(_, let reason):
            SettingsBadge("Protocol Unsupported")
                .help(reason)
        case .credentialMissing:
            SettingsBadge("Credential Missing")
        case .modelRemoved:
            SettingsBadge("Model Removed", tone: .danger)
        case .notReady(_, let reason):
            SettingsBadge(reason)
        }
    }

    private func moveMember(from source: Int, to destination: Int) {
        guard source >= 0, source < group.memberEntryIds.count,
              destination >= 0, destination < group.memberEntryIds.count else { return }
        var updated = group
        let moved = updated.memberEntryIds.remove(at: source)
        updated.memberEntryIds.insert(moved, at: destination)
        appState.modelGroups.updateGroup(updated)
    }

    private func removeMember(at index: Int) {
        guard index >= 0, index < group.memberEntryIds.count else { return }
        var updated = group
        updated.memberEntryIds.remove(at: index)
        appState.modelGroups.updateGroup(updated)
    }

    // MARK: Routing Section

    private var routingSection: some View {
        SettingsSection(title: "Routing") {
            SettingsRow(
                "Routing Strategy",
                caption: group.strategy == .fallback
                    ? "Try models from top to bottom. If one cannot complete the request, Limare can continue with the next model."
                    : "New conversations are distributed across available models. A conversation normally stays with the selected model."
            ) {
                SettingsSegmentedPicker(
                    selection: Binding(
                        get: { group.strategy },
                        set: { newStrategy in
                            var updated = group
                            updated.strategy = newStrategy
                            appState.modelGroups.updateGroup(updated)
                        }
                    ),
                    options: [(value: RoutingStrategy.fallback, title: String(localized: "Fallback")),
                              (value: RoutingStrategy.loadBalance, title: String(localized: "Load Balance"))]
                )
                .fixedSize()
                .accessibilityLabel("Routing Strategy")
            }

            if group.strategy == .fallback {
                SettingsDivider()

                SettingsRow(
                    "Fallback Behavior",
                    caption: group.fallbackStrategy == .limited
                        ? "Retry temporary failures before switching models."
                        : "Move to the next model when a provider request fails."
                ) {
                    SettingsSegmentedPicker(
                        selection: Binding(
                            get: { group.fallbackStrategy },
                            set: { newFallback in
                                var updated = group
                                updated.fallbackStrategy = newFallback
                                appState.modelGroups.updateGroup(updated)
                            }
                        ),
                        options: [(value: FallbackStrategy.limited, title: String(localized: "Standard")),
                                  (value: FallbackStrategy.always, title: String(localized: "Switch immediately"))]
                    )
                    .fixedSize()
                    .accessibilityLabel("Fallback Behavior")
                }
            }
        }
    }

    // MARK: Reasoning Section

    private var groupThinkingLevels: [ThinkingLevel] {
        let levels = group.memberEntryIds.flatMap { entry -> [ThinkingLevel] in
            guard let parsed = ModelGroup.parseEntryId(entry),
                  let provider = appState.providers.providers.first(where: { $0.id == parsed.providerID }),
                  let model = provider.models.first(where: { $0.id == parsed.modelID }) else { return [] }
            return ProviderThinkingResolution.supportedLevels(for: model, provider: provider)
        }
        return Array(Set(levels + [.off])).sorted()
    }

    private var reasoningSection: some View {
        SettingsSection(title: "Reasoning") {
            SettingsRow(
                "Default Thinking Level",
                caption: "Sets the initial reasoning effort for models in this group that support reasoning."
            ) {
                Picker("", selection: Binding(
                    get: { group.defaultThinkingLevel ?? .off },
                    set: { newLevel in
                        var updated = group
                        updated.defaultThinkingLevel = newLevel == .off ? nil : newLevel
                        appState.modelGroups.updateGroup(updated)
                    }
                )) {
                    ForEach(groupThinkingLevels, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .labelsHidden()
            }

            if let currentLevel = group.defaultThinkingLevel, currentLevel != .off {
                let unsupported = state.unsupportedReasoningMembers(for: group, providers: appState.providers.providers)
                if !unsupported.isEmpty {
                    InlineStatus(
                        kind: .warning,
                        message: "Some models in this group (\(unsupported.joined(separator: ", "))) do not support reasoning. They will run without thinking."
                    )
                }
            }
        }
    }

    // MARK: Advanced Section

    private var advancedSection: some View {
        DisclosureSection(
            title: "Advanced",
            summary: group.contextLimitTokens != nil ? "Context Limit: \(group.contextLimitTokens!) tokens" : nil,
            isExpanded: $isAdvancedExpanded
        ) {
            SettingsRow(
                "Context Limit",
                caption: "Optional maximum context window tokens to reserve for this group."
            ) {
                HStack(spacing: AppSpacing.xSmall) {
                    TextField("Unlimited", value: Binding<Int?>(
                        get: { group.contextLimitTokens },
                        set: { newLimit in
                            var updated = group
                            updated.contextLimitTokens = (newLimit != nil && newLimit! > 0) ? newLimit : nil
                            appState.modelGroups.updateGroup(updated)
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)

                    if group.contextLimitTokens != nil {
                        Button("Clear") {
                            var updated = group
                            updated.contextLimitTokens = nil
                            appState.modelGroups.updateGroup(updated)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

// MARK: - New Model Group Sheet

private struct NewModelGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let state: ModelGroupsSettingsState

    @State private var groupName = ""

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Text("New Model Group")
                .font(.headline)

            FormField("Group Name", caption: "Choose a memorable name for this group.") {
                TextField("e.g. Fast, Coding, Research", text: $groupName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let newGroup = ModelGroup(name: trimmed)
                    appState.modelGroups.addGroup(newGroup)
                    state.selection = .group(newGroup.id)
                    dismiss()
                }
                .buttonStyle(.charcoalProminent)
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppSpacing.small)
        }
        .padding(AppSpacing.large)
        .frame(width: 380)
    }
}

// MARK: - Specialist Models Sheet

private struct SpecialistModelsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showAddGroupsSheet = false
    @State private var showAddModelsSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Specialist Models")
                        .font(.headline)
                    Text("Choose models Limare may call directly for specialized jobs. Normal chat and helper work do not depend on this list.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.charcoalProminent)
                .controlSize(.small)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    // Groups Section
                    SettingsSection(
                        title: "Groups",
                        description: "Groups configured for specialist use. Models within these groups become executable by the Agent runtime when their credentials and actions are satisfied."
                    ) {
                        if appState.modelGroups.agentLoopGroupIds.isEmpty {
                            Text("No specialist groups configured.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.vertical, AppSpacing.xSmall)
                        } else {
                            ForEach(Array(appState.modelGroups.agentLoopGroupIds.enumerated()), id: \.element) { index, gid in
                                let grp = appState.modelGroups.group(for: gid)
                                HStack {
                                    Text(grp?.name ?? String(localized: "Unknown Group (\(gid))"))
                                        .font(.subheadline)
                                    Spacer()
                                    Button {
                                        moveGroup(from: index, to: index - 1)
                                    } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0)
                                    .buttonStyle(.plain)

                                    Button {
                                        moveGroup(from: index, to: index + 1)
                                    } label: { Image(systemName: "arrow.down") }
                                    .disabled(index >= appState.modelGroups.agentLoopGroupIds.count - 1)
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        appState.modelGroups.removeRuntimeGroup(gid)
                                    } label: { Image(systemName: "trash").foregroundStyle(AppColors.statusError) }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        HStack {
                            Spacer()
                            Button {
                                showAddGroupsSheet = true
                            } label: {
                                Label("Add Group", systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    // Individual Models Section
                    SettingsSection(
                        title: "Individual Models",
                        description: "Specific models configured for specialist use. Models become executable by the Agent runtime when their credentials and actions are satisfied."
                    ) {
                        if appState.modelGroups.agentLoopModelEntryIds.isEmpty {
                            Text("No individual specialist models configured.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.vertical, AppSpacing.xSmall)
                        } else {
                            ForEach(Array(appState.modelGroups.agentLoopModelEntryIds.enumerated()), id: \.element) { index, entryID in
                                let resolved = resolveEntry(entryID)
                                let readiness = appState.runtimeModelRegistry.executionStatus(for: entryID)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: AppSpacing.xSmall) {
                                            Text(resolved?.model.displayName ?? entryID)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(readiness.isExecutable ? AppColors.textPrimary : AppColors.textSecondary)
                                                .lineLimit(1)

                                            if readiness.isExecutable {
                                                SettingsBadge("Agent Runtime Ready", tone: .positive)
                                            } else {
                                                SettingsBadge("Configured · Not executable")
                                            }
                                        }

                                        HStack(spacing: 4) {
                                            Text(resolved?.provider.name ?? String(localized: "Unknown Provider"))
                                                .font(.caption2)
                                                .foregroundStyle(AppColors.textSecondary)

                                            if !readiness.isExecutable, let reason = readiness.unexecutableReason {
                                                Text("·")
                                                    .font(.caption2)
                                                    .foregroundStyle(AppColors.textMuted)
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(AppColors.statusWarning)
                                                Text(reason)
                                                    .font(.caption2.weight(.medium))
                                                    .foregroundStyle(AppColors.statusWarning)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Button {
                                        moveModel(from: index, to: index - 1)
                                    } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0)
                                    .buttonStyle(.plain)

                                    Button {
                                        moveModel(from: index, to: index + 1)
                                    } label: { Image(systemName: "arrow.down") }
                                    .disabled(index >= appState.modelGroups.agentLoopModelEntryIds.count - 1)
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        appState.modelGroups.removeRuntimeModelEntry(entryID)
                                    } label: { Image(systemName: "trash").foregroundStyle(AppColors.statusError) }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        }

                        HStack {
                            Spacer()
                            Button {
                                showAddModelsSheet = true
                            } label: {
                                Label("Add Model", systemImage: "plus.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(AppSemanticSpacing.settingsPageInset)
            }
        }
        .frame(width: 520, height: 500)
        .sheet(isPresented: $showAddGroupsSheet) {
            AddSpecialistGroupsModal()
        }
        .sheet(isPresented: $showAddModelsSheet) {
            AddSpecialistModelsModal()
        }
    }

    private func resolveEntry(_ entryID: String) -> (provider: ProviderConfiguration, model: ProviderModel)? {
        guard let parsed = ModelGroup.parseEntryId(entryID),
              let provider = appState.providers.providers.first(where: { $0.id == parsed.providerID }),
              let model = provider.models.first(where: { $0.id == parsed.modelID }) else { return nil }
        return (provider, model)
    }

    private func moveGroup(from source: Int, to destination: Int) {
        var ids = appState.modelGroups.agentLoopGroupIds
        guard source >= 0, source < ids.count, destination >= 0, destination < ids.count else { return }
        ids.swapAt(source, destination)
        appState.modelGroups.reorderRuntimeGroups(ids)
    }

    private func moveModel(from source: Int, to destination: Int) {
        var ids = appState.modelGroups.agentLoopModelEntryIds
        guard source >= 0, source < ids.count, destination >= 0, destination < ids.count else { return }
        ids.swapAt(source, destination)
        appState.modelGroups.reorderRuntimeModelEntries(ids)
    }
}

// MARK: - Add Specialist Groups Modal

private struct AddSpecialistGroupsModal: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []

    private var availableGroups: [ModelGroup] {
        appState.modelGroups.groups.filter { !appState.modelGroups.agentLoopGroupIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Specialist Groups")
                    .font(.headline)
                Spacer()
                Button("Add") {
                    selected.forEach(appState.modelGroups.addRuntimeGroup)
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .buttonStyle(.charcoalProminent)
            }
            .padding()

            Divider()

            if availableGroups.isEmpty {
                ContentUnavailableView(
                    "All Groups Added",
                    systemImage: "checkmark.circle",
                    description: Text("All available groups are already configured.")
                )
            } else {
                List(availableGroups) { group in
                    Button {
                        if let index = selected.firstIndex(of: group.id) {
                            selected.remove(at: index)
                        } else {
                            selected.append(group.id)
                        }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(group.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(group.id) ? AppColors.sendFill : Color.secondary)
                            Text(group.name)
                                .font(.body)
                                .foregroundStyle(AppColors.textPrimary)
                            Spacer()
                            Text("\(group.memberEntryIds.count) models")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 440, height: 380)
    }
}

// MARK: - Add Specialist Models Modal

private struct AddSpecialistModelsModal: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [String] = []

    private var sections: [ProviderPickerSection] {
        appState.providers.providers.compactMap { provider in
            let models = provider.models.filter { model in
                let id = ModelGroup.makeEntryId(providerID: provider.id, modelID: model.id)
                return !model.isHidden && !appState.modelGroups.agentLoopModelEntryIds.contains(id)
            }
            guard !models.isEmpty else { return nil }
            return ProviderPickerSection(provider: provider, entries: models.map {
                ModelPickerEntry(providerID: provider.id, providerName: provider.name, model: $0)
            })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Specialist Models")
                    .font(.headline)
                Spacer()
                Button("Add") {
                    selected.forEach(appState.modelGroups.addRuntimeModelEntry)
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .buttonStyle(.charcoalProminent)
            }
            .padding()

            Divider()

            if sections.isEmpty {
                ContentUnavailableView(
                    "No Models Available",
                    systemImage: "tray",
                    description: Text("All available models are already configured or hidden.")
                )
            } else {
                List {
                    ForEach(sections) { section in
                        Section(section.provider.name) {
                            ForEach(section.entries) { entry in
                                Button {
                                    if let idx = selected.firstIndex(of: entry.id) {
                                        selected.remove(at: idx)
                                    } else {
                                        selected.append(entry.id)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(entry.id) ? AppColors.sendFill : Color.secondary)
                                        Text(entry.model.displayName)
                                            .font(.body)
                                            .foregroundStyle(AppColors.textPrimary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - Add Models To Group Sheet

private struct AddModelsToGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let group: ModelGroup

    @State private var selectedEntryIds: [String] = []
    @State private var filterQuery = ""

    private var filteredSections: [ProviderPickerSection] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return appState.providers.providers.compactMap { provider in
            let matchingModels = provider.models.filter { model in
                let entryID = "\(provider.id):\(model.id)"
                let alreadyInGroup = group.memberEntryIds.contains(entryID)
                if model.isHidden && !alreadyInGroup {
                    return false
                }
                if query.isEmpty { return true }
                return model.displayName.lowercased().contains(query) ||
                       model.id.lowercased().contains(query) ||
                       provider.name.lowercased().contains(query)
            }
            guard !matchingModels.isEmpty else { return nil }
            let entries = matchingModels.map {
                ModelPickerEntry(providerID: provider.id, providerName: provider.name, model: $0)
            }
            return ProviderPickerSection(provider: provider, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Models to “\(group.name)”")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    var updated = group
                    for id in selectedEntryIds {
                        if !updated.memberEntryIds.contains(id) {
                            updated.memberEntryIds.append(id)
                        }
                    }
                    appState.modelGroups.updateGroup(updated)
                    dismiss()
                }
                .buttonStyle(.charcoalProminent)
            }
            .padding()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppColors.textSecondary)
                TextField("Filter models by name or provider…", text: $filterQuery)
                    .textFieldStyle(.plain)
                if !filterQuery.isEmpty {
                    Button {
                        filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppSpacing.small)
            .background(AppColors.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            .padding(.horizontal)

            if appState.providers.providers.allSatisfy({ $0.models.isEmpty }) {
                ContentUnavailableView(
                    "No Available Models",
                    systemImage: "network.slash",
                    description: Text("Please configure a provider and fetch models in Provider settings first.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSections.isEmpty {
                ContentUnavailableView(
                    "No Matching Models",
                    systemImage: "magnifyingglass",
                    description: Text("No models match “\(filterQuery)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredSections) { section in
                        Section(section.provider.name) {
                            ForEach(section.entries) { entry in
                                let alreadyInGroup = group.memberEntryIds.contains(entry.id)
                                let isSelected = selectedEntryIds.contains(entry.id)

                                Button {
                                    if !alreadyInGroup {
                                        if let idx = selectedEntryIds.firstIndex(of: entry.id) {
                                            selectedEntryIds.remove(at: idx)
                                        } else {
                                            selectedEntryIds.append(entry.id)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: alreadyInGroup ? "checkmark.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                                            .foregroundStyle(alreadyInGroup ? AppColors.textSecondary : (isSelected ? AppColors.sendFill : AppColors.textSecondary.opacity(0.5)))

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(entry.model.displayName)
                                                .font(.subheadline)
                                                .foregroundStyle(alreadyInGroup ? AppColors.textSecondary : AppColors.textPrimary)
                                            if entry.model.displayName != entry.model.id {
                                                Text(entry.model.id)
                                                    .font(.caption2)
                                                    .foregroundStyle(AppColors.textSecondary)
                                            }
                                        }

                                        Spacer()

                                        if alreadyInGroup {
                                            Text("Already in group")
                                                .font(.caption2)
                                                .foregroundStyle(AppColors.textSecondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(alreadyInGroup)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 480, height: 440)
    }
}
