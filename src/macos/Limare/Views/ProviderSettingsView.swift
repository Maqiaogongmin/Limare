import SwiftUI

// MARK: - Provider Settings Screen (Layer 3 Screen Composition)

public struct ProviderSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var state = ProviderSettingsState()
    @State private var confirmRemoveUnlisted = false

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            providerSidebar

            providerDetail
                .frame(
                    minWidth: AppLayout.settingsDetailMinimumWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .task {
            state.selectInitialProvider(store: appState.providers)
        }
        .onChange(of: state.selection) {
            state.loadSelection(store: appState.providers)
        }
        .onDisappear {
            state.cancelOperation()
        }
        .confirmationDialog(
            "Delete this Provider and its stored API key?",
            isPresented: Binding(
                get: { state.pendingDeletionID != nil },
                set: { if !$0 { state.pendingDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Provider", role: .destructive) {
                if let id = state.pendingDeletionID {
                    state.deleteProvider(id: id, store: appState.providers)
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingDeletionID = nil
            }
        } message: {
            Text("This will remove the provider configuration and its stored credentials. Any Model Groups using this provider will need attention.")
        }
        .confirmationDialog("Remove unlisted models and their settings?", isPresented: $confirmRemoveUnlisted, titleVisibility: .visible) {
            Button("Remove Unlisted Models", role: .destructive) {
                appState.providers.removeUnlistedModels(providerID: state.draft.id)
                state.draft.models.removeAll { !$0.isCustom && $0.discovery.isAbsent }
            }
        } message: {
            Text("Only models with complete discovery absence evidence are removed. Existing conversation and group bindings are retained.")
        }
        .sheet(item: $state.quickTestingModel) { model in
            ModelQuickTestSheet(
                provider: state.draft,
                model: model,
                apiKey: state.pendingAPIKey ?? (try? appState.providers.credential(for: state.draft)),
                client: appState.providers.networkClient
            )
        }
        .sheet(item: $state.inspectingModel) { model in
            ModelInspectorSheet(
                model: model,
                onSave: { updated in
                    state.updateModel(model: updated, store: appState.providers)
                },
                onDelete: { modelToDelete in
                    state.deleteCustomModel(model: modelToDelete, store: appState.providers)
                },
                onQuickTest: { modelToTest in
                    state.inspectingModel = nil
                    state.quickTestingModel = modelToTest
                }
            )
        }
        .sheet(isPresented: $state.showAddCustomModel) {
            AddCustomModelSheet(
                existingIDs: Set(state.draft.models.map(\.id)),
                onAdd: { newModel in
                    state.addCustomModel(model: newModel, store: appState.providers)
                }
            )
        }
    }

    // MARK: - Left Sidebar List

    // The page title already says Providers; the list's header holds only its add button.
    private var providerSidebar: some View {
        SettingsMasterList {
            HStack {
                Spacer()
                Button {
                    state.beginNewProvider()
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
                .buttonStyle(.settingsOutline)
                .help("Add a new AI model provider")
            }
        } content: {
            ForEach(appState.providers.providers) { provider in
                let isSelected = state.selection == provider.id && !state.isNew
                let hasKey = appState.providers.hasStoredAPIKey(providerID: provider.id) || provider.authenticationMode == .none
                let statusColor: Color? = hasKey ? nil : AppColors.statusWarning
                let subtitle: String = {
                    if !hasKey {
                        return String(localized: "Needs API Key")
                    }
                    let count = provider.models.count
                    return count == 0 ? String(localized: "Configured • 0 models") : String(localized: "\(count) models")
                }()

                SettingsMasterRow(isSelected: isSelected, onSelect: { state.selection = provider.id }) {
                    ResourceRow(
                        title: provider.name.isEmpty ? String(localized: "Untitled Provider") : provider.name,
                        subtitle: subtitle,
                        statusColor: statusColor,
                        isSelected: isSelected
                    )
                }
            }

            if state.isNew {
                SettingsMasterRow(isSelected: state.selection == state.draft.id, onSelect: { state.selection = state.draft.id }) {
                    ResourceRow(
                        title: state.draft.name.isEmpty ? String(localized: "New Provider") : state.draft.name,
                        subtitle: String(localized: "Unsaved Draft"),
                        statusColor: nil,
                        isSelected: state.selection == state.draft.id
                    )
                }
            }
        }
    }

    // MARK: - Right Detail Content

    private var providerDetail: some View {
        Group {
            if state.selection == nil && !state.isNew {
                ContentUnavailableView(
                    "Select a Provider",
                    systemImage: "network",
                    description: Text("Choose a provider from the list to manage settings and models, or click + to add a new provider.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                        detailHeader

                        if let error = state.userError {
                            ThreeLevelErrorView(
                                explanation: "\(error.explanation)",
                                recommendedAction: error.recommendedAction.map { "\($0)" },
                                technicalDetails: error.technicalDetails,
                                onRetry: state.isNew ? { state.connect(store: appState.providers) } : { state.refreshModels(store: appState.providers) },
                                retryTitle: state.isNew ? "Retry Connect" : "Retry Refresh"
                            )
                        } else if let statusMsg = state.userStatusMessage {
                            InlineStatus(kind: .success, message: "\(statusMsg)")
                        }

                        connectionSection

                        modelsSection

                        advancedSection
                    }
                    .frame(maxWidth: AppSemanticLayout.settingsPageMaxWidth, alignment: .leading)
                    .padding(.horizontal, AppSemanticLayout.settingsPageLeading)
                    .padding(.vertical, AppSemanticLayout.settingsPageTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .settingsScrollEdgeFade()
            }
        }
    }

    // MARK: - Detail Header

    private var detailHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpacing.small) {
                    Text(state.isNew ? (state.draft.name.isEmpty ? String(localized: "New Provider") : state.draft.name) : state.draft.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(AppColors.textPrimary)

                    if state.isNew {
                        SettingsBadge("Draft")
                    }
                }

                Text(state.draft.baseURL.isEmpty ? String(localized: "Configure endpoint and authentication") : state.draft.baseURL)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: AppSpacing.small) {
                if state.activeOperation.isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(state.activeOperation.label)
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                if state.isNew {
                    Button("Connect") {
                        state.connect(store: appState.providers)
                    }
                    .buttonStyle(.charcoalProminent)
                    .disabled(!state.canConnectOrSave)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Save Changes") {
                        state.saveChanges(store: appState.providers)
                    }
                    .buttonStyle(.charcoalProminent)
                    .disabled(!state.canConnectOrSave)
                }
            }
        }
    }

    // MARK: - Connection Section

    private var connectionSection: some View {
        SettingsSection(title: "Connection", description: "Provider, protocol and credentials. Browser authorization opens in your default browser.") {
            FormField("Service") {
                Picker("", selection: Binding(get: { state.draft.providerIdentity }, set: { state.selectPreset($0) })) {
                    ForEach(ProviderProductPolicy.selectableIdentities, id: \.self) { identity in
                        Text(identity.displayName).tag(identity)
                    }
                }
                .labelsHidden()
                .disabled(!state.isNew)
            }
            FormField("Provider Name") {
                TextField("e.g. OpenAI, OpenRouter, Local Ollama", text: $state.draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            FormField("Base URL", caption: "API host address. Suffix /v1 is configured in Advanced options below.") {
                TextField("https://api.openai.com", text: $state.draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
            }

            FormField("Authentication") {
                Picker("", selection: Binding(get: { state.draft.authenticationSelection.acquisitionMethod }, set: { method in
                    state.selectAcquisition(method)
                    state.draft.hasStoredSecret = appState.providers.hasCredential(providerID: state.draft.id, selection: state.draft.authenticationSelection)
                })) {
                    ForEach(ProviderProductPolicy.acquisitions(for: state.draft.providerIdentity, protocol: state.draft.protocolAdapter), id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .labelsHidden()
            }
            if [.authorizationCodePKCE, .vendorWebAPIKey].contains(state.draft.authenticationSelection.acquisitionMethod) {
                FormField("Account") { browserAccountControls }
            }

            if [.manualAPIKey, .azureAPIKey].contains(state.draft.authenticationSelection.acquisitionMethod) {
                FormField("API Key") {
                    SecretField(
                        identity: CredentialFieldIdentity(providerID: state.draft.id, selection: state.draft.authenticationSelection),
                        hasStoredSecret: state.draft.hasStoredSecret,
                        replacementSecret: $state.pendingAPIKey,
                        placeholder: state.draft.authenticationMode == .azureAPIKey ? String(localized: "Enter Azure API Key") : String(localized: "Enter API Key"),
                        onReveal: {
                            try appState.providers.storedAPIKey(providerID: state.draft.id, selection: state.draft.authenticationSelection)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Models Section

    private var modelsSection: some View {
        SettingsSection(
            title: "Models",
            description: "These models are discovered from or added to this provider. Presence here does not guarantee current reachability. Use Quick Test for an on-demand execution check.",
            trailing: {
                HStack(spacing: AppSpacing.small) {
                    if !state.isNew {
                        Button {
                            state.refreshModels(store: appState.providers)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(state.activeOperation.isWorking)
                        .help("Refresh model list from provider endpoint")
                    }

                    Menu {
                        if state.draft.models.contains(where: { !$0.isCustom && $0.discovery.isAbsent }) {
                            Button("Remove Unlisted Models…", role: .destructive) { confirmRemoveUnlisted = true }
                        }
                        Button("Add Model Manually…") {
                            state.showAddCustomModel = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("More Model Actions")
                }
            }
        ) {
            if state.draft.models.isEmpty {
                VStack(spacing: AppSpacing.small) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(AppColors.textMuted)

                    if state.isNew {
                        Text("Connect this provider to discover available models automatically.")
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                    } else if case .failed = state.discoveryStatus {
                        Text("No models discovered. Check connection settings or add a model manually.")
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("No models loaded yet.")
                            .font(.callout)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    HStack(spacing: AppSpacing.small) {
                        if !state.isNew {
                            Button("Refresh Models") {
                                state.refreshModels(store: appState.providers)
                            }
                            .controlSize(.small)
                            .disabled(state.activeOperation.isWorking)
                        }

                        Button("Add Model Manually") {
                            state.showAddCustomModel = true
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.large)
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    SettingsSearchField(text: $state.modelSearchText, placeholder: "Search \(state.draft.models.count) models…")

                    if state.filteredModels.isEmpty {
                        HStack {
                            Spacer()
                            Text("No models match “\(state.modelSearchText)”.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.vertical, AppSpacing.medium)
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(state.filteredModels) { model in
                                    let isSelected = state.draft.selectedModelID == model.id
                                    ModelListRow(
                                        model: model,
                                        isSelected: isSelected,
                                        onSelect: {
                                            state.draft.selectedModelID = model.id
                                        },
                                        onQuickTest: {
                                            state.quickTestingModel = model
                                        },
                                        onInspect: {
                                            state.inspectingModel = model
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(minHeight: 140, maxHeight: 260)
                    }
                }
            }
        }
    }

    // MARK: - Advanced Section

    /// One row per state: rejected by policy, waiting for the browser, connected, or not yet connected.
    @ViewBuilder
    private var browserAccountControls: some View {
        let method = state.draft.authenticationSelection.acquisitionMethod
        HStack(spacing: AppSpacing.small) {
            if ProviderProductPolicy.availability(state.draft) != .supported {
                Text(Self.policyReason(state.draft))
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
                if state.draft.hasStoredSecret {
                    Button("Disconnect") { state.logout(store: appState.providers) }
                }
            } else if state.activeOperation == .authenticating {
                ProgressView().controlSize(.small)
                Text(state.activeOperation.label)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
                Button("Cancel") {
                    state.cancelOperation()
                    appState.providers.cancelAuthentication(providerID: state.draft.id)
                }
            } else if state.draft.hasStoredSecret {
                Label {
                    Text(appState.providers.authenticationSummary(providerID: state.draft.id,
                                                                  selection: state.draft.authenticationSelection) ?? String(localized: "Connected"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.statusSuccess)
                }
                Spacer(minLength: 0)
                if method == .authorizationCodePKCE {
                    Button("Use Another Account") { state.authenticate(store: appState.providers, newAccount: true) }
                        .disabled(state.activeOperation.isWorking)
                }
                Button("Disconnect") { state.logout(store: appState.providers) }
            } else {
                Button(method.actionTitle) { state.authenticate(store: appState.providers) }
                    .buttonStyle(.charcoalProminent)
                    .disabled(state.activeOperation.isWorking || state.draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("Opens your browser.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Why the shared policy rejects the edited configuration; shown instead of an entry the runtime would refuse.
    private static func policyReason(_ draft: ProviderConfiguration) -> String {
        do {
            try ProviderProductPolicy.validate(draft)
            return String(localized: "This sign-in is unavailable for the current configuration.")
        } catch { return error.localizedDescription }
    }

    private var advancedSection: some View {
        DisclosureSection(
            title: "Advanced Configuration",
            summary: "Protocol format, /v1 suffix, custom headers, and deletion.",
            isExpanded: $state.isAdvancedExpanded
        ) {
            FormField("API Protocol Format") {
                Picker("", selection: Binding(get: { state.draft.protocolAdapter }, set: { format in
                    state.selectProtocol(format)
                    state.draft.hasStoredSecret = appState.providers.hasCredential(providerID: state.draft.id, selection: state.draft.authenticationSelection)
                })) {
                    ForEach(ProviderProductPolicy.protocols(for: state.draft.providerIdentity), id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
            }

            if state.draft.providerIdentity == .custom || state.draft.protocolAdapter == .anthropicMessages {
                FormField("Models URL", caption: "Optional full URL for model discovery. Leave empty to use this API base.") {
                    TextField("https://host/v1/models", text: Binding(
                        get: { state.draft.modelsURL ?? "" },
                        set: { state.draft.modelsURL = $0.isEmpty ? nil : $0 }
                    )).textFieldStyle(.roundedBorder)
                }
            }

            FormField("URL Handling") {
                Toggle("Append /v1 suffix automatically", isOn: $state.draft.appendV1Suffix)
                    .toggleStyle(.charcoalCheckbox)
            }

            if state.draft.authenticationMode == .azureAPIKey && state.draft.appendV1Suffix {
                InlineStatus(
                    kind: .warning,
                    message: "Azure deployment URLs usually require using the URL verbatim. Consider disabling Append /v1."
                )
            }

            FormField("User-Agent", caption: "Custom User-Agent header for proxy routing or tracing.") {
                TextField(
                    "Limare (Default)",
                    text: Binding(
                        get: { state.draft.customUserAgent ?? "" },
                        set: { state.draft.customUserAgent = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            customHeadersEditor

            if let err = state.headerValidationError {
                InlineStatus(kind: .error, message: "\(err)")
            } else if let warning = state.legacyReservedWarning {
                InlineStatus(kind: .warning, message: "\(warning)")
            }

            if !state.isNew {
                SettingsDivider()
                    .padding(.vertical, AppSpacing.xxSmall)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete Provider")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(AppColors.statusError)
                        Text("Permanently removes this provider configuration and stored credentials.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        state.pendingDeletionID = state.draft.id
                    } label: {
                        Text("Delete Provider…")
                            .foregroundStyle(AppColors.statusError)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Custom Headers Editor

    private var customHeadersEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Custom HTTP Headers")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer()
                Button {
                    state.headerRows.append(ProviderHeaderRow(name: "", value: ""))
                } label: {
                    Label("Add Header", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if state.headerRows.isEmpty {
                Text("No custom HTTP headers configured.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textMuted)
            } else {
                ForEach($state.headerRows) { $row in
                    HStack(spacing: 6) {
                        TextField("Header Name", text: $row.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                        if row.isLegacyReserved && ProviderRequestConfigurator.isReservedHeader(row.name) {
                            Text("Legacy")
                                .font(.caption2)
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppColors.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.small))
                        }
                        TextField("Header Value", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            if let idx = state.headerRows.firstIndex(where: { $0.id == row.id }) {
                                state.headerRows.remove(at: idx)
                                state.syncHeadersToDraft()
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .onChange(of: row.name) { state.syncHeadersToDraft() }
                    .onChange(of: row.value) { state.syncHeadersToDraft() }
                }
            }
        }
    }
}

// MARK: - Model List Row Component

private struct ModelListRow: View {
    let model: ProviderModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onQuickTest: () -> Void
    let onInspect: () -> Void

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Button(action: onSelect) {
                HStack(spacing: AppSpacing.small) {
                    SettingsRadioMark(isSelected: isSelected)
                        .scaleEffect(0.85)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(AppColors.textPrimary)
                                .lineLimit(1)

                            modelBadges
                        }

                        if model.displayName != model.id {
                            Text(model.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(AppColors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Secondary until the pointer reaches them.
            Button(action: onQuickTest) {
                Image(systemName: "bolt.badge.checkmark")
            }
            .buttonStyle(GhostIconButtonStyle(size: 22, iconSize: 11))
            .help("Run Quick Test diagnostics on this model")

            Button(action: onInspect) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(GhostIconButtonStyle(size: 22, iconSize: 11))
            .help("Inspect model capabilities & overrides")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 6)
        .background(isSelected ? Color.primary.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
    }

    @ViewBuilder
    private var modelBadges: some View {
        HStack(spacing: 4) {
            if let badge = model.discovery.badge {
                Text(badge).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(model.discovery.isRemoved ? AppColors.statusError : AppColors.statusWarning)
            }
            if model.isHidden {
                Text("Hidden")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppColors.surfaceSecondary)
                    .foregroundStyle(AppColors.textSecondary)
                    .clipShape(Capsule())
            }
            if model.isCustom {
                Text("Custom")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppColors.statusWarning.opacity(0.18))
                    .foregroundStyle(AppColors.statusWarning)
                    .clipShape(Capsule())
            }
            if let modality = model.modality {
                if modality.contains(.imageInput) {
                    Image(systemName: "photo")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textSecondary)
                        .help("Supports Image Input (Vision)")
                }
                if modality.contains(.audioInput) || modality.contains(.audioOutput) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textSecondary)
                        .help("Supports Audio / Speech")
                }
            }
            if model.supportsReasoning == true {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10))
                    .foregroundStyle(AppColors.textSecondary)
                    .help("Supports Reasoning / Thinking")
            }
            if let ctx = model.contextWindow, ctx > 0 {
                Text(formatTokens(ctx))
                    .font(.system(size: 9, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppColors.surfaceSecondary)
                    .foregroundStyle(AppColors.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                    .help("Context Window: \(ctx) tokens")
            }
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K"
        }
        return "\(tokens)"
    }
}

// MARK: - Model Inspector Sheet (Progressive Disclosure)

private enum ReasoningOverrideChoice: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case supported = "Supported"
    case notSupported = "Not Supported"

    var id: String { rawValue }
}

public struct ModelInspectorSheet: View {
    public let model: ProviderModel
    public let onSave: (ProviderModel) -> Void
    public let onDelete: (ProviderModel) -> Void
    public var onQuickTest: ((ProviderModel) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var displayNameOverride: String = ""
    @State private var contextWindowText: String = ""
    @State private var maxTokensText: String = ""
    @State private var reasoningChoice: ReasoningOverrideChoice = .auto
    @State private var isHidden: Bool = false
    @State private var isOverridesExpanded: Bool = false

    // Modality 3-state override choices
    @State private var textInputChoice: ModalityOverrideChoice = .auto
    @State private var textOutputChoice: ModalityOverrideChoice = .auto
    @State private var visionChoice: ModalityOverrideChoice = .auto
    @State private var pdfChoice: ModalityOverrideChoice = .auto
    @State private var audioInputChoice: ModalityOverrideChoice = .auto
    @State private var videoInputChoice: ModalityOverrideChoice = .auto

    @State private var imageOutputChoice: ModalityOverrideChoice = .auto
    @State private var audioOutputChoice: ModalityOverrideChoice = .auto
    @State private var videoOutputChoice: ModalityOverrideChoice = .auto

    public init(
        model: ProviderModel,
        onSave: @escaping (ProviderModel) -> Void,
        onDelete: @escaping (ProviderModel) -> Void,
        onQuickTest: ((ProviderModel) -> Void)? = nil
    ) {
        self.model = model
        self.onSave = onSave
        self.onDelete = onDelete
        self.onQuickTest = onQuickTest
    }

    private var parsedContextWindow: OptionalPositiveIntInput {
        NumericOverrideParser.parse(contextWindowText)
    }

    private var parsedMaxTokens: OptionalPositiveIntInput {
        NumericOverrideParser.parse(maxTokensText)
    }

    private var isInputValid: Bool {
        parsedContextWindow != .invalid && parsedMaxTokens != .invalid
    }

    private var autoReasoningSummary: String {
        switch model.baseSupportsReasoning {
        case .some(true): String(localized: "Supported")
        case .some(false): String(localized: "Not Supported")
        case .none: String(localized: "Unknown")
        }
    }

    private var resolvedModalities: ModelModalitiesTruth {
        ModelCapabilityTruthResolver.resolveModalities(for: model)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    // 1. Identity Card
                    SettingsSection(title: "Model Identity") {
                        FormField("Model ID") {
                            Text(model.id)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }

                        FormField("Display Name") {
                            Text(model.displayName)
                                .font(.body.weight(.medium))
                        }

                        FormField("Discovery Source") {
                            Text(model.baseMetadataSource?.displayName ?? (model.isCustom ? String(localized: "Custom Entry") : String(localized: "Unknown")))
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }

                        if let catalogVersion = model.capabilityCatalogVersion {
                            FormField("Official Facts") {
                                HStack(spacing: 4) {
                                    Text(catalogVersion)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                    if let url = model.capabilitySourceURL, let destination = URL(string: url) {
                                        Text("•")
                                            .font(.caption2)
                                            .foregroundStyle(AppColors.textMuted)
                                        Link("Documentation", destination: destination)
                                            .font(.caption)
                                    }
                                }
                            }
                        }

                        if let conflict = model.officialFactsConflict {
                            FormField("Facts Conflict") {
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(AppColors.statusWarning)
                                    Text(conflict)
                                        .font(.caption)
                                        .foregroundStyle(AppColors.statusWarning)
                                }
                            }
                        }
                    }

                    // 2. Detected Capabilities (Unknown is explicitly distinct from Not Supported)
                    SettingsSection(title: "Detected Capabilities", description: "Inferred from provider catalog and models metadata.") {
                        FormField("Reasoning Support") {
                            HStack(spacing: 6) {
                                Text(autoReasoningSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(model.baseSupportsReasoning == true ? Color.purple : AppColors.textPrimary)
                                provenanceBadge(model.capabilityProvenance.reasoning)
                                if model.overrides.supportsReasoning != nil {
                                    Text("(Overridden)")
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.statusWarning)
                                }
                            }
                        }

                        if let effort = model.reasoningEffortValues, !effort.isEmpty {
                            FormField("Effort Tiers") {
                                HStack(spacing: 6) {
                                    Text(effort.joined(separator: ", "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(AppColors.textSecondary)
                                    provenanceBadge(model.capabilityProvenance.reasoningEffort)
                                }
                            }
                        }

                        FormField("Input Modalities") {
                            HStack(spacing: 6) {
                                truthChip("Text", truth: resolvedModalities.textInput)
                                truthChip("Vision", truth: resolvedModalities.imageInput)
                                truthChip("PDF", truth: resolvedModalities.pdfInput)
                                truthChip("Audio", truth: resolvedModalities.audioInput)
                                truthChip("Video", truth: resolvedModalities.videoInput)
                                provenanceBadge(resolvedModalities.provenance)
                            }
                        }

                        FormField("Output Modalities") {
                            HStack(spacing: 6) {
                                truthChip("Text", truth: resolvedModalities.textOutput)
                                truthChip("Image", truth: resolvedModalities.imageOutput)
                                truthChip("Audio", truth: resolvedModalities.audioOutput)
                                truthChip("Video", truth: resolvedModalities.videoOutput)
                                provenanceBadge(resolvedModalities.provenance)
                            }
                        }

                        FormField("Context Window") {
                            HStack(spacing: 6) {
                                if let baseCtx = model.baseContextWindow {
                                    Text("\(baseCtx) tokens")
                                        .font(.caption.monospaced())
                                    provenanceBadge(model.baseCapabilityProvenance?.contextWindow ?? model.baseMetadataSource ?? .unknown)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                    provenanceBadge(.unknown)
                                }
                                if let overrideCtx = model.overrides.contextWindow {
                                    Text("(Overridden: \(overrideCtx) tokens)")
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.statusWarning)
                                }
                            }
                        }

                        FormField("Max Output Tokens") {
                            HStack(spacing: 6) {
                                if let baseOut = model.baseMaxOutputTokens {
                                    Text("\(baseOut) tokens")
                                        .font(.caption.monospaced())
                                    provenanceBadge(model.baseCapabilityProvenance?.maxOutputTokens ?? model.baseMetadataSource ?? .unknown)
                                } else {
                                    Text("Unknown")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.textSecondary)
                                    provenanceBadge(.unknown)
                                }
                                if let overrideOut = model.overrides.maxOutputTokens {
                                    Text("(Overridden: \(overrideOut) tokens)")
                                        .font(.caption2)
                                        .foregroundStyle(AppColors.statusWarning)
                                }
                            }
                        }
                    }

                    // 3. Overrides (Progressive Disclosure)
                    DisclosureSection(
                        title: "Custom Overrides",
                        summary: model.overrides.isEmpty ? "No active overrides." : "Display name, tokens, reasoning, or modality overridden.",
                        isExpanded: $isOverridesExpanded
                    ) {
                        FormField("Display Name Override") {
                            TextField(model.baseDisplayName, text: $displayNameOverride)
                                .textFieldStyle(.roundedBorder)
                        }

                        FormField("Hide from Pickers") {
                            Toggle("Hide this model from new conversation picker", isOn: $isHidden)
                                .toggleStyle(.charcoalCheckbox)
                        }

                        FormField("Context Window") {
                            TextField("Tokens (e.g. 128000)", text: $contextWindowText)
                                .textFieldStyle(.roundedBorder)
                        }

                        FormField("Max Output Tokens") {
                            TextField("Tokens (e.g. 4096)", text: $maxTokensText)
                                .textFieldStyle(.roundedBorder)
                        }

                        FormField("Reasoning Support") {
                            Picker("", selection: $reasoningChoice) {
                                Text("Auto (Detected: \(autoReasoningSummary))").tag(ReasoningOverrideChoice.auto)
                                Text("Supported").tag(ReasoningOverrideChoice.supported)
                                Text("Not Supported").tag(ReasoningOverrideChoice.notSupported)
                            }
                            .labelsHidden()
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Text("Modality Overrides")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.textSecondary)

                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Input Modality").font(.caption2.weight(.bold)).foregroundStyle(AppColors.textSecondary)
                                Text("Output Modality").font(.caption2.weight(.bold)).foregroundStyle(AppColors.textSecondary)
                            }
                            GridRow {
                                modalityPickerRow("Text Input", selection: $textInputChoice)
                                modalityPickerRow("Text Output", selection: $textOutputChoice)
                            }
                            GridRow {
                                modalityPickerRow("Vision (Image)", selection: $visionChoice)
                                modalityPickerRow("Image Output", selection: $imageOutputChoice)
                            }
                            GridRow {
                                modalityPickerRow("PDF Document", selection: $pdfChoice)
                                modalityPickerRow("Audio Output", selection: $audioOutputChoice)
                            }
                            GridRow {
                                modalityPickerRow("Audio Input", selection: $audioInputChoice)
                                modalityPickerRow("Video Output", selection: $videoOutputChoice)
                            }
                            GridRow {
                                modalityPickerRow("Video Input", selection: $videoInputChoice)
                                Color.clear
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Reset Overrides to Detected") {
                                resetToAutoDetected()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    }

                    if model.isCustom || model.discovery.isAbsent {
                        HStack {
                            Spacer()
                            Button(role: .destructive) {
                                onDelete(model)
                                dismiss()
                            } label: {
                                Text("Delete Model")
                                    .foregroundStyle(AppColors.statusError)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(AppSemanticSpacing.settingsPageInset)
            }
            .navigationTitle("Model Inspector")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if let onQuickTest {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            onQuickTest(model)
                        } label: {
                            Label("Quick Test", systemImage: "bolt.badge.checkmark")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(!isInputValid)
                }
            }
            .onAppear {
                populateFields()
            }
        }
        .frame(minWidth: 500, minHeight: 540)
    }

    private func truthChip(_ label: LocalizedStringKey, truth: CapabilityTruth) -> some View {
        HStack(spacing: 3) {
            Text(label)
            switch truth {
            case .supported:
                EmptyView()
            case .unsupported:
                Text("✕").font(.system(size: 8, weight: .bold))
            case .unknown:
                Text("?").font(.system(size: 8, weight: .bold))
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            truth == .supported
                ? Color.primary.opacity(0.08)
                : (truth == .unsupported ? AppColors.surfaceSecondary.opacity(0.6) : AppColors.surfaceSecondary)
        )
        .foregroundStyle(
            truth == .supported
                ? Color.primary.opacity(0.8)
                : (truth == .unsupported ? AppColors.textMuted : AppColors.textSecondary)
        )
        .clipShape(Capsule())
    }

    private func modalityPickerRow(_ label: LocalizedStringKey, selection: Binding<ModalityOverrideChoice>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            Picker("", selection: selection) {
                Text("Auto").tag(ModalityOverrideChoice.auto)
                Text("Supported").tag(ModalityOverrideChoice.supported)
                Text("Unsupported").tag(ModalityOverrideChoice.unsupported)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 105)
        }
    }

    private func provenanceBadge(_ prov: ModelMetadataSource) -> some View {
        Text(prov.displayName)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(prov == .inferred ? Color.orange.opacity(0.12) : (prov == .userOverride ? Color.primary.opacity(0.12) : AppColors.surfaceSecondary))
            .foregroundStyle(prov == .inferred ? Color.orange : (prov == .userOverride ? Color.primary : AppColors.textSecondary))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
    }

    private func populateFields() {
        displayNameOverride = model.overrides.displayName ?? ""
        contextWindowText = model.contextWindow.map { "\($0)" } ?? ""
        maxTokensText = model.maxOutputTokens.map { "\($0)" } ?? ""
        if let sr = model.overrides.supportsReasoning {
            reasoningChoice = sr ? .supported : .notSupported
        } else {
            reasoningChoice = .auto
        }
        isHidden = model.isHidden
        isOverridesExpanded = !model.overrides.isEmpty

        let modOverrides = model.overrides.modalityOverrides
        textInputChoice = modOverrides?.textInput.map { $0 ? .supported : .unsupported } ?? .auto
        textOutputChoice = modOverrides?.textOutput.map { $0 ? .supported : .unsupported } ?? .auto
        visionChoice = modOverrides?.vision.map { $0 ? .supported : .unsupported } ?? .auto
        pdfChoice = modOverrides?.pdfInput.map { $0 ? .supported : .unsupported } ?? .auto
        audioInputChoice = modOverrides?.audioInput.map { $0 ? .supported : .unsupported } ?? .auto
        videoInputChoice = modOverrides?.videoInput.map { $0 ? .supported : .unsupported } ?? .auto
        imageOutputChoice = modOverrides?.imageOutput.map { $0 ? .supported : .unsupported } ?? .auto
        audioOutputChoice = modOverrides?.audioOutput.map { $0 ? .supported : .unsupported } ?? .auto
        videoOutputChoice = modOverrides?.videoOutput.map { $0 ? .supported : .unsupported } ?? .auto
    }

    private func resetToAutoDetected() {
        displayNameOverride = ""
        contextWindowText = model.baseContextWindow.map { "\($0)" } ?? ""
        maxTokensText = model.baseMaxOutputTokens.map { "\($0)" } ?? ""
        reasoningChoice = .auto

        textInputChoice = .auto
        textOutputChoice = .auto
        visionChoice = .auto
        pdfChoice = .auto
        audioInputChoice = .auto
        videoInputChoice = .auto
        imageOutputChoice = .auto
        audioOutputChoice = .auto
        videoOutputChoice = .auto
    }

    private func saveChanges() {
        guard isInputValid else { return }

        var updated = model
        updated.isHidden = isHidden

        let trimmedName = displayNameOverride.trimmingCharacters(in: .whitespaces)
        updated.overrides.displayName = trimmedName.isEmpty ? nil : trimmedName

        switch parsedContextWindow {
        case .clear:
            updated.overrides.contextWindow = nil
        case .value(let val):
            updated.overrides.contextWindow = (val == model.baseContextWindow) ? nil : val
        case .invalid:
            return
        }

        switch parsedMaxTokens {
        case .clear:
            updated.overrides.maxOutputTokens = nil
        case .value(let val):
            updated.overrides.maxOutputTokens = (val == model.baseMaxOutputTokens) ? nil : val
        case .invalid:
            return
        }

        switch reasoningChoice {
        case .auto:
            updated.overrides.supportsReasoning = nil
        case .supported:
            updated.overrides.supportsReasoning = true
        case .notSupported:
            updated.overrides.supportsReasoning = false
        }

        updated.overrides.modalityOverrides = ModelCapabilityTruthResolver.buildModalityOverrides(
            textInput: textInputChoice,
            textOutput: textOutputChoice,
            vision: visionChoice,
            pdf: pdfChoice,
            audioInput: audioInputChoice,
            videoInput: videoInputChoice,
            imageOutput: imageOutputChoice,
            audioOutput: audioOutputChoice,
            videoOutput: videoOutputChoice
        )

        onSave(updated)
        dismiss()
    }
}

// MARK: - Add Custom Model Sheet

public struct AddCustomModelSheet: View {
    public let existingIDs: Set<String>
    public let onAdd: (ProviderModel) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var modelID: String = ""
    @State private var displayName: String = ""
    @State private var errorMessage: String?

    public init(existingIDs: Set<String>, onAdd: @escaping (ProviderModel) -> Void) {
        self.existingIDs = existingIDs
        self.onAdd = onAdd
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Custom Model") {
                    TextField("Model ID (e.g. gpt-4.5-preview)", text: $modelID)
                        .font(.system(.body, design: .monospaced))
                    TextField("Display Name (optional)", text: $displayName)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(AppColors.statusError)
                            .font(.caption)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Model Manually")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedID.isEmpty else {
                            errorMessage = String(localized: "Model ID is required.")
                            return
                        }
                        guard !existingIDs.contains(trimmedID) else {
                            errorMessage = String(localized: "Model ID '\(trimmedID)' already exists in this provider.")
                            return
                        }
                        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
                        let newModel = ProviderModel(
                            id: trimmedID,
                            displayName: trimmedName.isEmpty ? trimmedID : trimmedName,
                            isCustom: true
                        )
                        onAdd(newModel)
                        dismiss()
                    }
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
    }
}

/// One stored credential: Provider, credential kind and authentication identity.
struct CredentialFieldIdentity: Hashable {
    let providerID: UUID
    let credentialKind: ProviderCredentialKind
    let authenticationIdentityID: String

    init(providerID: UUID, selection: ProviderAuthenticationSelection) {
        self.providerID = providerID
        credentialKind = selection.credentialKind
        authenticationIdentityID = selection.authenticationIdentityID
    }
}
