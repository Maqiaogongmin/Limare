import SwiftUI
import AppKit

struct HooksSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var state = HooksSettingsState()

    private var filteredSources: [HookSource] {
        state.filteredSources(from: appState.hooks.sources)
    }

    private var presentedSource: HookSource? {
        guard let id = state.presentedSourceID else { return nil }
        return appState.hooks.sources.first(where: { $0.id == id })
    }

    var body: some View {
        SettingsPage {
            // Header / Controls Section
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(spacing: AppSpacing.medium) {
                    if !appState.hooks.sources.isEmpty {
                        SettingsSearchField(text: $state.searchText, placeholder: "Search hooks…")
                            .frame(minWidth: 120, idealWidth: 220, maxWidth: 300)
                    }

                    Spacer()

                    if !appState.hooks.sources.isEmpty {
                        Button {
                            appState.hooks.reloadAll()
                        } label: {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Reload all installed hook packages")
                    }

                    Button {
                        importHookPackage()
                    } label: {
                        Label("Import…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Import Hook Package from folder")
                }
            }

            if let importError = state.importErrorMessage {
                ThreeLevelErrorView(
                    explanation: importError,
                    recommendedAction: "Check that the selected folder contains a valid hooks.json configuration.",
                    technicalDetails: state.importErrorDetails,
                    onRetry: {
                        state.importErrorMessage = nil
                        state.importErrorDetails = nil
                        importHookPackage()
                    },
                    retryTitle: "Try Again"
                )
            }

            // Hook Packages List Section
            if appState.hooks.sources.isEmpty {
                ContentUnavailableView {
                    Label("No Hook Packages Installed", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Hooks run at specific moments during tasks. Import a package folder or hooks.json configuration to get started.")
                } actions: {
                    Button("Import Hook Package…") { importHookPackage() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else if filteredSources.isEmpty {
                ContentUnavailableView(
                    "No Matching Hooks",
                    systemImage: "magnifyingglass",
                    description: Text("No hook packages match “\(state.searchText)”.")
                )
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else {
                SettingsSection(
                    title: "Configured Hook Packages",
                    description: "\(filteredSources.count) \(filteredSources.count == 1 ? "package" : "packages") configured"
                ) {
                    ForEach(Array(filteredSources.enumerated()), id: \.element.id) { index, source in
                        if index > 0 {
                            Divider()
                        }
                        HookPackageRowView(source: source, state: state)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { presentedSource },
            set: {
                state.presentedSourceID = $0?.id
                if $0 == nil {
                    state.resetSheetState()
                }
            }
        )) { source in
            HookDetailSheet(source: source, state: state)
        }
        .sheet(item: $state.reviewSource) { source in
            HookReviewSheet(source: source)
        }
    }

    private func importHookPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a hooks.json file or a package folder containing hooks/hooks.json"
        panel.prompt = "Import"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                state.importErrorMessage = nil
                state.importErrorDetails = nil
                let imported = try appState.hooks.importPackage(from: url)
                state.reviewSource = imported
            } catch {
                state.importErrorMessage = "Hook package could not be imported."
                state.importErrorDetails = error.localizedDescription
            }
        }
    }
}

// MARK: - Hook Package Row View

private struct HookPackageRowView: View {
    @Environment(AppState.self) private var appState
    let source: HookSource
    let state: HooksSettingsState

    private var isTrusted: Bool {
        appState.hooks.isTrusted(source: source)
    }

    private var statusKind: InlineStatusKind {
        state.trustStatusKind(for: source, isTrusted: isTrusted)
    }

    private var statusText: String {
        state.trustStatusText(for: source, isTrusted: isTrusted)
    }

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            // Left Action: Isolated Toggle or Review button or Error Icon
            if state.shouldShowEnableToggle(for: source, isTrusted: isTrusted) {
                Toggle(
                    isOn: Binding(
                        get: { source.isEnabled },
                        set: { _ in appState.hooks.toggleSource(sourceID: source.id) }
                    )
                ) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Enable hook package \(source.name)")
            } else if !isTrusted && source.loadError == nil {
                Button("Review…") {
                    state.managementRoute = .review
                    state.presentedSourceID = source.id
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.statusError)
            }

            // Main Row Button: Opens Detail Sheet
            Button {
                state.managementRoute = .overview
                state.presentedSourceID = source.id
            } label: {
                HStack(alignment: .center, spacing: AppSpacing.small) {
                    Circle()
                        .fill(statusKind.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        HStack(spacing: AppSpacing.xSmall) {
                            Text(source.name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(isTrusted && source.isEnabled ? AppColors.textPrimary : AppColors.textSecondary)
                                .lineLimit(1)

                            Text(source.sourceKind.displayName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AppColors.textSecondary)
                                .padding(.horizontal, AppSemanticSpacing.badgePaddingHorizontal)
                                .padding(.vertical, AppSemanticSpacing.badgePaddingVertical)
                                .background(AppColors.textSecondary.opacity(0.12))
                                .clipShape(Capsule())

                            Text(statusText)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(statusKind.color)
                                .padding(.horizontal, AppSemanticSpacing.badgePaddingHorizontal)
                                .padding(.vertical, AppSemanticSpacing.badgePaddingVertical)
                                .background(statusKind.color.opacity(0.12))
                                .clipShape(Capsule())
                        }

                        Text(state.automationSummaryText(for: source))
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: AppSpacing.small)

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

// MARK: - Hook Detail Sheet

private struct HookDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let source: HookSource
    @Bindable var state: HooksSettingsState

    private var isTrusted: Bool {
        appState.hooks.isTrusted(source: source)
    }

    private var statusKind: InlineStatusKind {
        state.trustStatusKind(for: source, isTrusted: isTrusted)
    }

    private var statusText: String {
        state.trustStatusText(for: source, isTrusted: isTrusted)
    }

    var body: some View {
        Group {
            if state.managementRoute == .review {
                HookReviewSheet(
                    source: source,
                    onComplete: {
                        state.managementRoute = .overview
                    },
                    onCancel: {
                        state.managementRoute = .overview
                    }
                )
            } else {
                VStack(spacing: 0) {
                    // Header Bar
                    HStack(alignment: .center) {
                        if state.managementRoute == .automations {
                            Button {
                                state.managementRoute = .overview
                            } label: {
                                HStack(spacing: AppSpacing.xxSmall) {
                                    Image(systemName: "chevron.left")
                                    Text(source.name)
                                }
                                .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.plain)
                        } else {
                            HStack(spacing: AppSpacing.xSmall) {
                                Text(source.name)
                                    .font(.headline)
                                    .foregroundStyle(AppColors.textPrimary)

                                Text(source.sourceKind.displayName)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(AppColors.textSecondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(AppColors.textSecondary.opacity(0.12))
                                    .clipShape(Capsule())

                                Text(statusText)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(statusKind.color)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(statusKind.color.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }

                        Spacer()

                        HStack(spacing: AppSpacing.medium) {
                            if state.shouldShowEnableToggle(for: source, isTrusted: isTrusted) {
                                HStack(spacing: AppSpacing.small) {
                                    Text("Package Enabled")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppColors.textSecondary)

                                    Toggle(
                                        "Enable this hook package",
                                        isOn: Binding(
                                            get: { source.isEnabled },
                                            set: { _ in appState.hooks.toggleSource(sourceID: source.id) }
                                        )
                                    )
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .accessibilityLabel("Enable this hook package")
                                }
                            } else if !isTrusted && source.loadError == nil {
                                Button("Review…") {
                                    state.managementRoute = .review
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Button("Done") {
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(AppSpacing.medium)

                    Divider()

                    // Sheet Body
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                            if state.managementRoute == .automations {
                                automationsView
                            } else {
                                overviewView
                            }
                        }
                        .padding(AppSpacing.medium)
                    }
                }
            }
        }
        .frame(minWidth: 580, minHeight: 480)
        .confirmationDialog(
            "Delete Hook Package?",
            isPresented: Binding(
                get: { state.pendingDeleteSourceID != nil },
                set: { if !$0 { state.pendingDeleteSourceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Package", role: .destructive) {
                if let id = state.pendingDeleteSourceID {
                    appState.hooks.removeSource(sourceID: id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                state.pendingDeleteSourceID = nil
            }
        } message: {
            Text("Are you sure you want to delete “\(source.name)”? Its configuration and trust record will be removed.")
        }
    }

    // MARK: - Overview Route

    @ViewBuilder
    private var overviewView: some View {
        // Section: What it does
        SettingsSection(title: "What it does") {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                let bullets = state.overviewEventBullets(for: source)
                if bullets.isEmpty {
                    Text("No available automations in this package.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    Text("Runs actions at:")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)

                    VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                        ForEach(bullets, id: \.self) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
                                Text("•")
                                    .foregroundStyle(Color.accentColor)
                                Text(bullet)
                                    .font(.subheadline)
                                    .foregroundStyle(AppColors.textPrimary)
                            }
                        }
                    }
                }

                Button {
                    state.managementRoute = .automations
                } label: {
                    Label("Manage Automations…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, AppSpacing.xxSmall)
            }
        }

        if let loadError = source.loadError {
            SettingsSection(title: "Status") {
                ThreeLevelErrorView(
                    explanation: "This Hook Package could not be loaded.",
                    recommendedAction: "Check that its hooks.json file still exists and is valid.",
                    technicalDetails: loadError,
                    onRetry: {
                        appState.hooks.reloadSource(sourceID: source.id)
                    },
                    retryTitle: "Reload"
                )
            }
        }

        // Section: Advanced Details & Maintenance
        SettingsSection(title: "Advanced") {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Button {
                    withAnimation(AppMotion.resolved(AppMotion.standard)) {
                        state.isAdvancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: state.isAdvancedExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text(state.isAdvancedExpanded ? "Hide Technical Details" : "Show Technical Details")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                if state.isAdvancedExpanded {
                    VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                        detailRow(label: "Config File", value: source.configURL.path, isMonospaced: true)
                        detailRow(label: "Package Root", value: source.packageRootURL.path, isMonospaced: true)
                        detailRow(label: "Definition Hash", value: source.definitionHash, isMonospaced: true)
                    }
                    .padding(.top, AppSpacing.xxSmall)
                }

                Divider()
                    .padding(.vertical, AppSpacing.xxSmall)

                HStack(spacing: AppSpacing.small) {
                    Button("Reload Package") {
                        appState.hooks.reloadSource(sourceID: source.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if isTrusted {
                        Button("Revoke Trust") {
                            appState.hooks.revokeTrust(sourceID: source.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Review Package…") {
                            state.managementRoute = .review
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button("Delete Package", role: .destructive) {
                        state.pendingDeleteSourceID = source.id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Automations Route

    @ViewBuilder
    private var automationsView: some View {
        let allKeys = source.config.hooks.keys.sorted()
        if allKeys.isEmpty {
            ContentUnavailableView(
                "No Automations",
                systemImage: "slider.horizontal.3",
                description: Text("This hook package does not define any lifecycle handlers.")
            )
            .padding(.vertical, AppSpacing.large)
        } else {
            VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                ForEach(allKeys, id: \.self) { eventKey in
                    let groups = source.config.hooks[eventKey] ?? []
                    let friendlyName = state.friendlyEventName(for: eventKey)
                    let isSupported = HookEventName(rawValue: eventKey)?.isSupported ?? false

                    SettingsSection(
                        title: friendlyName,
                        description: isSupported ? nil : "Unavailable — Not supported by this version of Limare."
                    ) {
                        ForEach(groups) { group in
                            ForEach(group.hooks) { hook in
                                automationHandlerRow(eventKey: eventKey, group: group, hook: hook)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func automationHandlerRow(eventKey: String, group: HookMatcherGroup, hook: HookHandlerConfig) -> some View {
        let status = state.automationPresentationStatus(source: source, eventKey: eventKey, hook: hook)
        let isUserDisabled = source.disabledHandlerIDs.contains(hook.id)

        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(alignment: .center, spacing: AppSpacing.small) {
                if status == .available || status == .disabledByUser {
                    Toggle(
                        "Enable this automation",
                        isOn: Binding(
                            get: { !isUserDisabled },
                            set: { _ in appState.hooks.toggleHandler(sourceID: source.id, handlerID: hook.id) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Enable this automation")
                } else {
                    Toggle("Enable this automation", isOn: .constant(false))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(true)
                        .accessibilityLabel("Enable this automation")
                }

                if status != .available {
                    Text(status.displayText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppColors.statusWarning)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppColors.statusWarning.opacity(0.12))
                        .clipShape(Capsule())
                }

                if let matcher = group.matcher, !matcher.isEmpty {
                    Text("matcher: \(matcher)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppColors.textSecondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }

                if let timeout = hook.timeout {
                    Text("timeout: \(timeout)s")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }

                if let msg = hook.statusMessage {
                    Text("“\(msg)”")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()
            }

            if let cmd = hook.command, !cmd.isEmpty {
                Text(cmd)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .padding(AppSpacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.surfaceSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
            }
        }
        .padding(.vertical, AppSpacing.xxSmall)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, isMonospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
