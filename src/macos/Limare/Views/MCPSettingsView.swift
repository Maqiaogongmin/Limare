import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var state = MCPSettingsState()
    @State private var migrationError: String?
    @State private var migrationInProgress = false

    private var filteredServers: [MCPServerConfig] {
        state.filteredServers(from: appState.mcp.servers)
    }

    private var presentedServer: MCPServerConfig? {
        guard let id = state.presentedServerID else { return nil }
        return appState.mcp.servers.first(where: { $0.id == id })
    }

    var body: some View {
        SettingsPage {
            if appState.mcp.authorityState != .ready {
                InlineStatus(kind: .error, message: "\(appState.mcp.authorityState.message)")
            }
            if appState.mcp.authorityState == .recoveryRequired {
                // Re-runs reconciliation against the durable records; nothing falls back to files.
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
            // Header / Controls Section
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(spacing: AppSpacing.medium) {
                    if !appState.mcp.servers.isEmpty {
                        SettingsSearchField(text: $state.searchText, placeholder: "Search connections…")
                            .frame(minWidth: 120, idealWidth: 220, maxWidth: 300)
                    }

                    Spacer()

                    if !appState.mcp.servers.isEmpty {
                        Button {
                            // Each reconnect is its own durable runtime operation, as from mcp_manage.
                            Task {
                                for server in appState.mcp.servers where server.enabled {
                                    _ = try? await appState.mcp.performRuntimeAction("reconnect", serverID: server.id,
                                        expectedRevision: appState.mcp.configurationRevision, requestID: UUID())
                                }
                            }
                        } label: {
                            Label("Refresh All", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.settingsOutline)
                        .help("Reconnect and refresh tools for all enabled servers")
                    }

                    Button {
                        state.showAddSheet = true
                    } label: {
                        Label("Add MCP", systemImage: "plus")
                    }
                    .buttonStyle(.settingsOutline)
                    .disabled(appState.mcp.authorityState != .ready)
                }
            }

            // Server List Section
            if appState.mcp.servers.isEmpty && appState.mcp.authorityState == .ready {
                ContentUnavailableView {
                    Label("No MCP Connections", systemImage: "server.rack")
                } description: {
                    Text("Connect external tools and resources via Model Context Protocol servers. Add a local command or remote endpoint to get started.")
                } actions: {
                    Button("Add MCP") { state.showAddSheet = true }
                        .buttonStyle(.charcoalProminent)
                }
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else if appState.mcp.servers.isEmpty {
                // Storage not ready: the status above says why; there is nothing to search.
                EmptyView()
            } else if filteredServers.isEmpty {
                ContentUnavailableView(
                    "No Matching Connections",
                    systemImage: "magnifyingglass",
                    description: Text("No MCP connections match “\(state.searchText)”.")
                )
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else {
                SettingsSection(
                    title: "Configured Connections",
                    description: "\(filteredServers.count) connections configured"
                ) {
                    ForEach(Array(filteredServers.enumerated()), id: \.element.id) { index, server in
                        if index > 0 {
                            SettingsDivider()
                        }
                        MCPRowView(server: server, state: state)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { presentedServer },
            set: {
                state.presentedServerID = $0?.id
                if $0 == nil {
                    state.resetSheetState()
                }
            }
        )) { server in
            MCPManagementSheet(server: server, state: state)
        }
        .sheet(isPresented: $state.showAddSheet) {
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
    }
}

// MARK: - MCP Row View

private struct MCPRowView: View {
    @Environment(AppState.self) private var appState
    let server: MCPServerConfig
    let state: MCPSettingsState

    private var status: MCPServerStatus {
        appState.mcp.status(for: server.id)
    }

    private var statusColor: Color {
        guard server.enabled else { return AppColors.textSecondary }
        switch status {
        case .connected: return AppColors.positiveText
        case .connecting: return AppColors.statusWarning
        case .credentialRequired: return AppColors.statusWarning
        case .signInRequired, .signingIn: return AppColors.statusWarning
        case .configSaved: return AppColors.textSecondary
        case .failed: return AppColors.statusError
        case .disconnected: return AppColors.textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            Toggle(
                isOn: Binding(
                    get: { server.enabled },
                    set: { appState.mcp.setEnabled($0, for: server.id) }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.charcoalCheckbox)
            .labelsHidden()
            .accessibilityLabel("Enable MCP connection \(server.id)")

            Button {
                state.managementRoute = .overview
                state.presentedServerID = server.id
            } label: {
                HStack(alignment: .center, spacing: AppSpacing.small) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        HStack(spacing: AppSpacing.xSmall) {
                            Text(server.id)
                                .font(.body.weight(.medium))
                                .foregroundStyle(server.enabled ? AppColors.textPrimary : AppColors.textSecondary)
                                .lineLimit(1)

                            SettingsBadge(state.connectionTypeDisplayName(for: server))
                        }

                        if let note = server.note, !note.isEmpty {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: AppSpacing.small)

                    // A healthy connection is a green badge; other states stay quiet text.
                    if server.enabled, case .connected = status {
                        SettingsBadge(state.statusDisplayText(for: status, isEnabled: server.enabled), tone: .positive)
                    } else {
                        Text(state.statusDisplayText(for: status, isEnabled: server.enabled))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(statusColor)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppColors.textSecondary.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, AppSemanticSpacing.settingsRowVerticalPadding)
    }
}

// MARK: - MCP Management Sheet

private struct MCPManagementSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let server: MCPServerConfig
    @Bindable var state: MCPSettingsState

    @State private var didCopyConfig = false
    @State private var runtimeActionError: String?

    private var status: MCPServerStatus {
        appState.mcp.status(for: server.id)
    }

    private var tools: [MCPTool] {
        appState.mcp.tools(for: server.id)
    }

    private var usesOAuth: Bool {
        appState.mcp.usesOAuth(serverID: server.id)
    }

    /// Reconnect, authenticate and sign-out run through the same durable runtime operation as the
    /// Agent's mcp_manage. Outcomes land in the server status; refusals are shown here.
    private func perform(_ action: String) {
        runtimeActionError = nil
        Task {
            do {
                _ = try await appState.mcp.performRuntimeAction(action, serverID: server.id,
                    expectedRevision: appState.mcp.configurationRevision, requestID: UUID())
            } catch {
                runtimeActionError = error.localizedDescription
            }
        }
    }

    /// Browser sign-in or the protected token prompt, whichever the server allows.
    private func authenticate() { perform("authenticate") }

    /// The authenticate action's label for this connection, or nil when it takes no credential.
    private var authenticateTitle: LocalizedStringKey? {
        if usesOAuth { return "Sign In…" }
        if !server.credentialSlots.isEmpty { return "Replace Credentials…" }
        return nil
    }

    var body: some View {
        Group {
            switch state.managementRoute {
            case .overview:
                overviewContent
            case .edit:
                MCPServerEditFormView(
                    existingConfig: server,
                    onSave: { updated, clientSecret in
                        try await appState.mcp.saveConfiguration(updated, clientSecret: clientSecret)
                        state.managementRoute = .overview
                    },
                    onCancel: {
                        state.managementRoute = .overview
                    }
                )
            case .tools:
                MCPToolsListView(
                    serverID: server.id,
                    tools: tools,
                    onBack: {
                        state.managementRoute = .overview
                    }
                )
            }
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 660, minHeight: 440, idealHeight: 520, maxHeight: 680)
        .confirmationDialog(
            "Delete MCP Server “\(server.id)”?",
            isPresented: Binding(
                get: { state.pendingDeleteServerID == server.id },
                set: { if !$0 { state.pendingDeleteServerID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete MCP Server", role: .destructive) {
                do {
                    try appState.mcp.delete(id: server.id)
                    state.resetSheetState()
                    dismiss()
                } catch {
                    state.pendingDeleteServerID = nil
                    state.deleteErrorMessage = String(localized: "Failed to delete server “\(server.id)”: \(error.localizedDescription)")
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingDeleteServerID = nil
            }
        } message: {
            Text("This will remove the server configuration and all stored credentials. It will not delete external files or processes from your Mac.")
        }
        .alert(
            "Delete Failed",
            isPresented: Binding(
                get: { state.deleteErrorMessage != nil },
                set: { if !$0 { state.deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                state.deleteErrorMessage = nil
            }
        } message: {
            Text(state.deleteErrorMessage ?? String(localized: "An unexpected error occurred."))
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(server.id)
                        .font(AppTypography.interfaceTitle2)
                        .foregroundStyle(AppColors.textPrimary)

                    SettingsBadge(state.connectionTypeDisplayName(for: server))
                }

                Spacer()

                HStack(spacing: AppSpacing.medium) {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { server.enabled },
                            set: { appState.mcp.setEnabled($0, for: server.id) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.charcoalProminent)
                    .controlSize(.small)
                }
            }
            .padding(AppSpacing.medium)

            Divider()

            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    // Status Section
                    statusView
                    if let runtimeActionError {
                        InlineStatus(kind: .error, message: "\(runtimeActionError)")
                    }

                    if server.requiresReview {
                        SettingsSection(
                            title: "Imported Fields Need Review",
                            description: "Limare does not understand these imported fields and has not applied them: \((server.quarantinedFields ?? []).joined(separator: ", ")). Their values are held in secure storage. The connection stays off until they are discarded."
                        ) {
                            Button("Discard Imported Fields") {
                                do { try appState.mcp.discardQuarantinedFields(serverID: server.id) }
                                catch { appState.mcp.setServerStatus(.failed(message: String(localized: "The imported fields could not be discarded."), kind: .credentialStorage), for: server.id) }
                            }
                        }
                    }

                    // Tools Section
                    SettingsSection(
                        title: "Tools",
                        description: "\(tools.count) tools discovered"
                    ) {
                        HStack {
                            Text(tools.isEmpty ? "No tools available from this server." : "\(tools.count) tools ready for agent execution.")
                                .font(.body)
                                .foregroundStyle(AppColors.textSecondary)

                            Spacer()

                            Button("View Tools (\(tools.count))") {
                                state.managementRoute = .tools
                            }
                            .controlSize(.small)
                            .disabled(tools.isEmpty)
                        }
                    }

                    // Connection Section
                    SettingsSection(
                        title: "Connection Details",
                        description: server.isHTTP ? "Remote HTTP Endpoint" : "Local Process Command"
                    ) {
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            Text(server.transportSummary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(AppColors.textPrimary)
                                .textSelection(.enabled)
                                .padding(AppSpacing.small)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AppColors.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))

                            HStack {
                                Spacer()
                                Button("Edit Connection…") {
                                    state.managementRoute = .edit
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(AppSpacing.medium)
            }

            Divider()

            // Footer Actions
            HStack(spacing: AppSpacing.medium) {
                Button("Reconnect") { perform("reconnect") }
                .controlSize(.small)
                .disabled(!server.enabled)

                if usesOAuth && appState.mcp.credentialPresence(serverID: server.id, key: MCPSecretKey.oauthToken) == .present {
                    Button("Sign Out") { perform("logout") }
                    .controlSize(.small)
                    .disabled(!server.enabled)
                    .help("Forget the OAuth token stored for this connection")
                } else if let authenticateTitle {
                    Button(authenticateTitle) { authenticate() }
                        .controlSize(.small)
                        .disabled(!server.enabled || status == .signingIn)
                }

                Button(didCopyConfig ? "✓ Copied" : "Copy Config") {
                    if let json = appState.mcp.exportJSON(for: server.id, redacted: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(json, forType: .string)
                        didCopyConfig = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didCopyConfig = false
                        }
                    }
                }
                .controlSize(.small)

                Spacer()

                Button("Delete MCP…", role: .destructive) {
                    state.pendingDeleteServerID = server.id
                }
                .controlSize(.small)
                .foregroundStyle(AppColors.statusError)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .background(AppColors.surfaceSecondary.opacity(0.4))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if !server.enabled {
            InlineStatus(
                kind: .info,
                message: "Connection is currently turned off."
            )
        } else {
            switch status {
            case .connected(let toolCount):
                InlineStatus(
                    kind: toolCount == 0 ? .warning : .success,
                    message: toolCount == 0 ? "Connected · no tools discovered" : "Connected and ready · \(toolCount) tools available"
                )
            case .connecting:
                InlineStatus(
                    kind: .warning,
                    message: "Connecting to server…"
                )
            case .configSaved:
                InlineStatus(
                    kind: .info,
                    message: "Configuration saved."
                )
            case .credentialRequired:
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    InlineStatus(
                        kind: .warning,
                        message: appState.mcp.missingCredentials[server.id].map { "This connection needs: \(ListFormatter.localizedString(byJoining: $0))." }
                            ?? "This connection needs an access token."
                    )
                    Button("Enter Credentials…") { authenticate() }
                        .controlSize(.small)
                }
            case .signInRequired:
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    InlineStatus(
                        kind: .warning,
                        message: "This server uses OAuth. Sign in through your browser to connect."
                    )
                    Button("Sign In…") { authenticate() }
                        .controlSize(.small)
                }
            case .signingIn:
                InlineStatus(
                    kind: .warning,
                    message: "Waiting for you to finish signing in in your browser…"
                )
            case .disconnected:
                InlineStatus(
                    kind: .info,
                    message: "Server is not currently connected."
                )
            case .failed(let message, let kind):
                let classified = MCPErrorClassifier.details(for: kind, message: message)
                let retryAuthenticates = kind == .authentication && authenticateTitle != nil
                ThreeLevelErrorView(
                    explanation: "\(classified.explanation)",
                    recommendedAction: "\(classified.recommendedAction)",
                    technicalDetails: classified.technicalDetails,
                    onRetry: {
                        perform(retryAuthenticates ? "authenticate" : "reconnect")
                    },
                    retryTitle: retryAuthenticates ? (authenticateTitle ?? "Try Again") : "Try Again"
                )
            }
        }
    }
}
