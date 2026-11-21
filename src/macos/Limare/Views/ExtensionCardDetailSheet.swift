import SwiftUI
import AppKit

struct ExtensionCardDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @Environment(\.dismiss) private var dismiss

    let cardID: String
    let onToggle: (ExtensionCardItem, Bool) -> Void

    @State private var mcpState = MCPSettingsState()
    @State private var skillState = SkillsSettingsState()
    @State private var hookState = HooksSettingsState()

    @State private var presentedMCP: MCPServerConfig?
    @State private var presentedSkill: Skill?
    @State private var presentedHook: HookSource?
    @State private var presentedHookReview: HookSource?
    @State private var authErrorMessage: String?
    @State private var showUninstallConfirm = false
    @State private var showRemoveHookConfirm = false
    @State private var showRemoveMCPConfirm = false

    private var liveCard: ExtensionCardItem? {
        ExtensionCardProjection.build(
            skills: appState.skills,
            mcp: appState.mcp,
            hooks: appState.hooks,
            computerUse: appState.computerUseActivation
        ).first(where: { $0.id == cardID })
    }

    private var activeEffectiveWorkspaceURL: URL? {
        guard let activeID = window.conversationID else { return nil }
        return appState.conversations.effectiveWorkingDirectory(for: activeID)
    }

    var body: some View {
        if let card = liveCard {
            Group {
                if let source = presentedHookReview {
                    HookReviewSheet(
                        source: source,
                        onComplete: { presentedHookReview = nil },
                        onCancel: { presentedHookReview = nil }
                    )
                } else if let selected = presentedMCP,
                          let server = appState.mcp.servers.first(where: { $0.id == selected.id }) {
                    MCPManagementSheet(server: server, state: mcpState, onBack: {
                        presentedMCP = nil
                        mcpState.resetSheetState()
                    }, onDelete: {
                        presentedMCP = nil
                        mcpState.resetSheetState()
                    })
                } else if let selected = presentedSkill, let skill = card.primarySkill, skill.id == selected.id {
                    SkillDetailSheet(skill: skill, state: skillState, onBack: {
                        presentedSkill = nil
                        skillState.resetSheetState()
                    })
                } else if let selected = presentedHook,
                          let source = appState.hooks.sources.first(where: { $0.id == selected.id }) {
                    HookDetailSheet(source: source, state: hookState, onBack: {
                        presentedHook = nil
                        hookState.resetSheetState()
                    }, onDelete: {
                        presentedHook = nil
                        hookState.resetSheetState()
                    })
                } else if case .standaloneMCP(let serverID) = card.origin,
                          let server = appState.mcp.servers.first(where: { $0.id == serverID }) {
                    MCPManagementSheet(server: server, state: mcpState)
                } else if case .standaloneHook(let sourceID) = card.origin,
                          let source = appState.hooks.sources.first(where: { $0.id == sourceID }) {
                    HookDetailSheet(source: source, state: hookState)
                } else {
                    overview(for: card)
                }
            }
        } else {
            VStack(spacing: AppSpacing.medium) {
                Text("Extension no longer available.")
                    .font(AppTypography.interface)
                    .foregroundStyle(AppColors.textSecondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.charcoalProminent)
            }
            .padding(AppSpacing.xLarge)
            .frame(minWidth: 400, minHeight: 220)
        }
    }

    private func overview(for card: ExtensionCardItem) -> some View {
            VStack(spacing: 0) {
                headerView(for: card)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                        if !card.examples.isEmpty {
                            examplesBanner(for: card)
                        }

                        descriptionSection(for: card)

                        if card.origin == .builtInComputerUse {
                            computerUsePermissionsSection
                        }

                        if !card.linkedMCPServers.isEmpty || card.primarySkill != nil || !card.linkedHooks.isEmpty {
                            ingredientsSection(for: card)
                        }
                    }
                    .padding(AppSpacing.standard)
                }

                if card.primarySkill != nil || !card.linkedHooks.isEmpty || !card.linkedMCPServers.isEmpty {
                    Divider()
                    footerView(for: card)
                }
            }
            .frame(minWidth: 520, idealWidth: 580, maxWidth: 660, minHeight: 460, idealHeight: 560, maxHeight: 720)
            .confirmationDialog(
                String(localized: "Uninstall “\(card.title)”?" ),
                isPresented: $showUninstallConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Move to Trash"), role: .destructive) {
                    if let skill = card.primarySkill {
                        uninstallSkill(skill)
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("This moves the extension folder to the Trash. Any connected MCP servers can be managed separately if needed.")
            }
            .confirmationDialog("Delete MCP Connection?", isPresented: $showRemoveMCPConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if case .standaloneMCP(let serverID) = card.origin {
                        do { try appState.mcp.delete(id: serverID); dismiss() }
                        catch { authErrorMessage = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The connection and its saved credentials will be removed.")
            }
            .confirmationDialog(
                "Remove Hook?",
                isPresented: $showRemoveHookConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove Hook", role: .destructive) {
                    if let hook = card.linkedHooks.first {
                        appState.hooks.removeSource(sourceID: hook.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let hook = card.linkedHooks.first {
                    Text("Remove “\(hook.name)” from Limare? Its files will remain on disk.")
                }
            }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerView(for card: ExtensionCardItem) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            extensionIconBadge(card: card, size: 48, cornerRadius: AppRadius.modal, fontSize: 20)

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(card.title)
                        .font(AppTypography.interfaceTitle2)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    SettingsBadge(card.scopeLabel)
                }

                if !card.description.isEmpty {
                    Text(card.description)
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AppSpacing.small)

            HStack(spacing: AppSpacing.small) {
                headerActionButton(for: card)

                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { card.isEnabled },
                        set: { onToggle(card, $0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.charcoalProminent)
                .controlSize(.small)
            }
        }
        .padding(AppSpacing.medium)
    }

    @ViewBuilder
    private func headerActionButton(for card: ExtensionCardItem) -> some View {
        if card.origin == .builtInComputerUse {
            switch appState.computerUseActivation.capabilityStatus {
            case .needsScreenRecording:
                Button("Open System Settings…") {
                    PrivacySettingsOpener.openScreenRecordingSettings()
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)
            case .needsAccessibility:
                Button("Open System Settings…") {
                    AccessibilitySettingsOpener.openAccessibilitySettings()
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)
            default:
                EmptyView()
            }
        } else if let authTarget = firstAuthRequiredMCP(in: card.linkedMCPServers) {
            let status = appState.mcp.status(for: authTarget.id)
            let isOAuth = status == .signInRequired || appState.mcp.usesOAuth(serverID: authTarget.id)
            let label = isOAuth
                ? String(localized: "Sign In…")
                : String(localized: "Configure Credentials…")
            Button(label) {
                authenticateMCP(serverID: authTarget.id)
            }
            .buttonStyle(.settingsOutline)
            .controlSize(.small)
        } else if let untrustedHook = card.linkedHooks.first(where: { !appState.hooks.isTrusted(source: $0) }) {
            Button("Review Trust…") {
                presentedHookReview = untrustedHook
            }
            .buttonStyle(.settingsOutline)
            .controlSize(.small)
        }
    }

    // MARK: - Examples Banner

    @ViewBuilder
    private func examplesBanner(for card: ExtensionCardItem) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text("Try asking")
                .font(AppTypography.interfaceSubheadline.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)

            VStack(spacing: AppSpacing.xxSmall) {
                ForEach(card.examples, id: \.self) { example in
                    Button {
                        appState.skills.recordExtensionUsage(cardID: card.id)
                        dismiss()
                        window.openChatWithPrompt(example, preferEmptyOverwrite: true)
                    } label: {
                        HStack(spacing: AppSpacing.small) {
                            extensionIconBadge(card: card, size: 22, cornerRadius: AppRadius.small, fontSize: 11)

                            Text(example)
                                .font(AppTypography.interface)
                                .foregroundStyle(AppColors.textPrimary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(card.color.iconForeground)
                        }
                        .padding(.horizontal, AppSpacing.small)
                        .padding(.vertical, AppSpacing.xSmall)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                                .fill(AppColors.raisedSurface.opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                                .stroke(AppColors.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                .fill(card.color.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.settingsCard, style: .continuous)
                .stroke(AppColors.hairline, lineWidth: 1)
        )
    }

    // MARK: - Description & Computer Use Permissions

    @ViewBuilder
    private func descriptionSection(for card: ExtensionCardItem) -> some View {
        SettingsSection(title: "What it does") {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                if card.description.isEmpty {
                    Text("No description provided.")
                        .font(AppTypography.interface)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    Text(card.description)
                        .font(AppTypography.interface)
                        .foregroundStyle(AppColors.textPrimary)
                        .textSelection(.enabled)
                }

                if let authErrorMessage {
                    Text(authErrorMessage)
                        .font(AppTypography.interfaceSecondary)
                        .foregroundStyle(AppColors.dangerText)
                }
            }
            .padding(AppSpacing.medium)
        }
    }

    private var computerUsePermissionsSection: some View {
        SettingsSection(title: "macOS Permissions") {
            VStack(spacing: 0) {
                permissionRow(
                    title: String(localized: "Screen Recording"),
                    granted: appState.screenRecordingPermission.authorizationStatus() == .authorized,
                    action: { PrivacySettingsOpener.openScreenRecordingSettings() }
                )
                SettingsDivider()
                permissionRow(
                    title: String(localized: "Accessibility"),
                    granted: appState.accessibilityPermission.authorizationStatus() == .authorized,
                    action: { AccessibilitySettingsOpener.openAccessibilitySettings() }
                )
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: AppSpacing.small) {
            Circle()
                .fill(granted ? AppColors.statusSuccess : AppColors.statusWarning)
                .frame(width: 8, height: 8)
            Text(title)
                .font(AppTypography.interface)
                .foregroundStyle(AppColors.textPrimary)
            Spacer()
            if granted {
                Text("Granted")
                    .font(AppTypography.interfaceSecondary)
                    .foregroundStyle(AppColors.positiveText)
            } else {
                Button("Open System Settings") {
                    action()
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    // MARK: - Ingredients

    @ViewBuilder
    private func ingredientsSection(for card: ExtensionCardItem) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            if !card.linkedMCPServers.isEmpty {
                SettingsSection(title: "Connected Services (\(card.linkedMCPServers.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(card.linkedMCPServers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { SettingsDivider() }
                            Button {
                                presentedMCP = server
                            } label: {
                                HStack(spacing: AppSpacing.small) {
                                    let status = appState.mcp.status(for: server.id)
                                    Circle()
                                        .fill(mcpStatusDotColor(server: server, status: status))
                                        .frame(width: 8, height: 8)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.id)
                                            .font(AppTypography.interfaceMedium)
                                            .foregroundStyle(AppColors.textPrimary)
                                        Text(mcpStatusSummary(server: server, status: status))
                                            .font(AppTypography.interfaceSecondary)
                                            .foregroundStyle(AppColors.textSecondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AppColors.textMuted)
                                }
                                .padding(.horizontal, AppSpacing.medium)
                                .padding(.vertical, AppSpacing.small)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let skill = card.primarySkill {
                SettingsSection(title: "Included Skills (1)") {
                    Button {
                        presentedSkill = skill
                    } label: {
                        HStack(spacing: AppSpacing.small) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 13))
                                .foregroundStyle(AppColors.textSecondary)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(AppTypography.interfaceMedium)
                                    .foregroundStyle(AppColors.textPrimary)
                                Text("Inspect SKILL.md instructions and files")
                                    .font(AppTypography.interfaceSecondary)
                                    .foregroundStyle(AppColors.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColors.textMuted)
                        }
                        .padding(.horizontal, AppSpacing.medium)
                        .padding(.vertical, AppSpacing.small)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !card.linkedHooks.isEmpty {
                SettingsSection(title: "Automation Hooks (\(card.linkedHooks.count))") {
                    VStack(spacing: 0) {
                        ForEach(Array(card.linkedHooks.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { SettingsDivider() }
                            Button {
                                if appState.hooks.isTrusted(source: source) {
                                    presentedHook = source
                                } else {
                                    presentedHookReview = source
                                }
                            } label: {
                                HStack(spacing: AppSpacing.small) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 13))
                                        .foregroundStyle(AppColors.textSecondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.name)
                                            .font(AppTypography.interfaceMedium)
                                            .foregroundStyle(AppColors.textPrimary)
                                        let handlerCount = source.config.hooks.values.flatMap { $0 }.reduce(0) { $0 + $1.hooks.count }
                                        Text("\(handlerCount) handlers")
                                            .font(AppTypography.interfaceSecondary)
                                            .foregroundStyle(AppColors.textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(AppColors.textMuted)
                                }
                                .padding(.horizontal, AppSpacing.medium)
                                .padding(.vertical, AppSpacing.small)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footerView(for card: ExtensionCardItem) -> some View {
        HStack {
            if let skill = card.primarySkill {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)

                Spacer()

                if isUserWritableSkill(skill) {
                    Button("Uninstall…", role: .destructive) {
                        showUninstallConfirm = true
                    }
                    .buttonStyle(.settingsOutline)
                    .controlSize(.small)
                }
            } else if case .standaloneMCP = card.origin {
                Spacer()
                Button("Delete…", role: .destructive) { showRemoveMCPConfirm = true }
                    .buttonStyle(.settingsOutline)
                    .controlSize(.small)
            } else if let hook = card.linkedHooks.first {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([hook.configURL])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)

                Spacer()

                Button("Remove Hook…", role: .destructive) {
                    showRemoveHookConfirm = true
                }
                .buttonStyle(.settingsOutline)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
    }

    // MARK: - Helpers

    private func firstAuthRequiredMCP(in servers: [MCPServerConfig]) -> MCPServerConfig? {
        servers.first { server in
            guard server.enabled else { return false }
            let status = appState.mcp.status(for: server.id)
            switch status {
            case .credentialRequired, .signInRequired:
                return true
            case .failed(_, .authentication):
                return !server.credentialSlots.isEmpty || appState.mcp.usesOAuth(serverID: server.id)
            default:
                return false
            }
        }
    }

    private func authenticateMCP(serverID: String) {
        authErrorMessage = nil
        Task {
            do {
                _ = try await appState.mcp.performRuntimeAction(
                    "authenticate",
                    serverID: serverID,
                    expectedRevision: appState.mcp.configurationRevision,
                    requestID: UUID()
                )
            } catch {
                authErrorMessage = error.localizedDescription
            }
        }
    }

    private func mcpStatusDotColor(server: MCPServerConfig, status: MCPServerStatus) -> Color {
        guard server.enabled else { return AppColors.textMuted }
        if server.requiresReview { return AppColors.statusWarning }
        switch status {
        case .connected: return AppColors.statusSuccess
        case .credentialRequired, .signInRequired, .failed: return AppColors.statusWarning
        case .connecting, .signingIn: return AppColors.statusInfo
        case .configSaved, .disconnected: return AppColors.textMuted
        }
    }

    private func mcpStatusSummary(server: MCPServerConfig, status: MCPServerStatus) -> String {
        guard server.enabled else { return String(localized: "Disabled") }
        if server.requiresReview { return String(localized: "Needs security review") }
        return status.displayText
    }

    private func isUserWritableSkill(_ skill: Skill) -> Bool {
        let path = skill.directoryURL.standardizedFileURL.path
        let root = skill.location.rootURL.standardizedFileURL.path
        let builtIn = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/builtin/skills").standardizedFileURL.path
        return root != builtIn && path.hasPrefix(root + "/") && FileManager.default.isWritableFile(atPath: path)
    }

    private func uninstallSkill(_ skill: Skill) {
        do {
            try FileManager.default.trashItem(at: skill.directoryURL, resultingItemURL: nil)
            appState.skills.rescan(workspaceURL: activeEffectiveWorkspaceURL ?? appState.workspace.url)
            dismiss()
        } catch {
            authErrorMessage = error.localizedDescription
        }
    }
}

@ViewBuilder
func extensionIconBadge(
    card: ExtensionCardItem,
    size: CGFloat,
    cornerRadius: CGFloat,
    fontSize: CGFloat,
    isDesaturated: Bool = false
) -> some View {
    let backgroundColor = isDesaturated ? Color.primary.opacity(0.06) : card.color.iconBackground
    let foregroundColor = isDesaturated ? AppColors.textMuted : card.color.iconForeground

    ZStack {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(backgroundColor)
            .frame(width: size, height: size)

        if let symbol = card.iconSymbol {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(foregroundColor)
        } else {
            Text(card.monogram)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(foregroundColor)
        }
    }
}
