import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @AppStorage(StreamingSendPreference.storageKey) private var streamingSendPreference: StreamingSendPreference = .queue
    @AppStorage(BackgroundActivityNotifier.enabledKey) private var backgroundAlerts = false
    @State private var notificationsDenied = false

    var body: some View {
        @Bindable var typography = appState.typography
        SettingsPage {
            SettingsSection(title: "About Limare") {
                SettingsRow("Version", caption: "Apple Silicon · macOS 15.0+") {
                    Text(LimareBuild.current.displayVersion)
                }
                // Three of a kind: two pages on the web and the licenses panel.
                HStack(spacing: AppSpacing.small) {
                    Link("Privacy", destination: URL(string: "https://limare.app/privacy/")!)
                    Link("Support", destination: URL(string: "https://limare.app/support/")!)
                    Button("Licenses") { NSApp.orderFrontStandardAboutPanel(nil) }
                }
                .buttonStyle(.settingsOutline)
            }

            SettingsSection(title: "Language") {
                LanguageSettingsRow()
            }

            // Appearance Section
            SettingsSection(title: "Appearance") {
                SettingsRow(
                    "Theme",
                    caption: "Controls how Limare looks."
                ) {
                    SettingsSegmentedPicker(
                        selection: $appearance,
                        options: AppearancePreference.allCases.map { (value: $0, title: $0.displayName) }
                    )
                    .frame(width: 220)
                    .accessibilityLabel("Theme")
                    .onChange(of: appearance) { _, newPref in
                        newPref.apply()
                    }
                }

                SettingsDivider()

                SettingsRow(
                    "Interface",
                    caption: "Controls text used across navigation, settings, controls and supporting UI."
                ) {
                    Picker("", selection: $typography.interfaceSize) {
                        ForEach(TypographyPreferences.interfaceSizeOptions, id: \.self) { size in
                            Text(TypographyPreferences.formatSize(size)).tag(size)
                        }
                    }
                    .frame(width: 100)
                    .labelsHidden()
                }

                SettingsRow(
                    "Conversation",
                    caption: "Controls user messages, Agent responses and rich-text reading surfaces."
                ) {
                    Picker("", selection: $typography.conversationSize) {
                        ForEach(TypographyPreferences.conversationSizeOptions, id: \.self) { size in
                            Text(TypographyPreferences.formatSize(size)).tag(size)
                        }
                    }
                    .frame(width: 100)
                    .labelsHidden()
                }

                SettingsRow(
                    "Code",
                    caption: "Controls code blocks, source views and diff/code-oriented surfaces."
                ) {
                    Picker("", selection: $typography.codeSize) {
                        ForEach(TypographyPreferences.codeSizeOptions, id: \.self) { size in
                            Text(TypographyPreferences.formatSize(size)).tag(size)
                        }
                    }
                    .frame(width: 100)
                    .labelsHidden()
                }
            }

            // Composer & Run Section
            SettingsSection(title: "Composer & Run") {
                SettingsRow(
                    "When Agent is Running",
                    caption: "\(streamingSendPreference.detail)"
                ) {
                    Picker("", selection: $streamingSendPreference) {
                        ForEach(StreamingSendPreference.allCases) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .frame(width: 180)
                    .labelsHidden()
                }
            }

            // Background alerts and Computer Use share one card, a rule between them.
            SettingsSection(title: "Notifications & Capabilities") {
                SettingsRow(
                    "Background Alerts",
                    caption: "While Limare is in the background, notify when a task of 20 seconds or more ends, or when a tool needs your approval. Notifications never name the tool, command or path."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { backgroundAlerts },
                            set: { enabled in
                                guard enabled else {
                                    backgroundAlerts = false
                                    return
                                }
                                Task {
                                    let allowed = await appState.backgroundNotifier.requestAuthorizationIfNeeded()
                                    backgroundAlerts = allowed
                                    notificationsDenied = !allowed
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.general.backgroundAlerts")
                    .accessibilityLabel("Background Alerts")
                }
                if notificationsDenied {
                    InlineStatus(
                        kind: .error,
                        message: "Notifications are off for Limare in System Settings.",
                        actionTitle: "Open System Settings",
                        onAction: { PrivacySettingsOpener.openNotificationSettings() }
                    )
                }

                SettingsDivider()

                // A global app capability. Conversation policies (Subagent) live in the
                // Composer, not here.
                ComputerUseCapabilitySettingsRow()
            }
            .task {
                notificationsDenied = await appState.backgroundNotifier.isDenied()
                if notificationsDenied { backgroundAlerts = false }
            }

            // Default Workspace Section
            SettingsSection(title: "Workspace") {
                if let errorMessage = appState.workspace.errorMessage {
                    InlineStatus(kind: .error, message: "\(errorMessage)")
                }

                if let workspace = appState.workspace.configuration {
                    SettingsRow(
                        "Default Workspace",
                        caption: "Used when no Project workspace is selected."
                    ) {
                        HStack(spacing: AppSpacing.small) {
                            Button("Change…") {
                                appState.workspace.chooseWorkspace()
                            }

                            Button("Clear") {
                                appState.workspace.clearWorkspace()
                            }
                        }
                        .buttonStyle(.settingsOutline)
                    }

                    SettingsDivider()

                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "folder")
                            .foregroundStyle(AppColors.textSecondary)
                        Text(workspace.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppColors.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(workspace.path)
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.xxSmall)
                } else {
                    SettingsRow(
                        "Default Workspace",
                        caption: "No default workspace selected. Standalone conversations use the existing fallback behavior."
                    ) {
                        Button("Choose…") {
                            appState.workspace.chooseWorkspace()
                        }
                        .buttonStyle(.settingsOutline)
                    }
                }
            }

            WorktreeSettingsSection()
        }
    }
}

/// The display language. "System" follows macOS; the other choices are the languages the app
/// ships (see AppLanguage). The new language applies at the next launch, so the row offers a
/// relaunch until the language in effect matches the choice.
private struct LanguageSettingsRow: View {
    /// "" stands for following the system, so the picker can tag it.
    @State private var selection = AppLanguage.selected ?? ""

    private var needsRelaunch: Bool {
        let wanted = selection.isEmpty ? AppLanguage.systemResolved : selection
        return wanted != AppLanguage.inEffect
    }

    var body: some View {
        SettingsRow(
            "Language",
            caption: "The language of menus, settings and messages in Limare."
        ) {
            Picker("", selection: $selection) {
                Text("System").tag("")
                Divider()
                ForEach(AppLanguage.available, id: \.self) { language in
                    Text(verbatim: AppLanguage.displayName(for: language)).tag(language)
                }
            }
            .frame(width: 180)
            .labelsHidden()
            .accessibilityIdentifier("settings.general.language")
            .accessibilityLabel("Language")
            .onChange(of: selection) { _, language in
                AppLanguage.select(language.isEmpty ? nil : language)
            }
        }
        if needsRelaunch {
            InlineStatus(
                kind: .info,
                message: "Limare will use the new language after it restarts.",
                actionTitle: "Restart Now",
                onAction: { AppLanguage.relaunch() }
            )
        }
    }
}

/// Global Computer Use preference. The toggle is the user's choice; OS permission and runtime
/// facts are reported separately and never flip it. Execution authority is still granted per Run.
/// Problems stay on screen until fixed; "ready" is a confirmation that shows once, when the user
/// turns Computer Use on or grants the missing permission, and then goes away.
private struct ComputerUseCapabilitySettingsRow: View {
    @Environment(AppState.self) private var appState
    @State private var confirmsReady = false
    @State private var confirmationTask: Task<Void, Never>?

    private var store: ComputerUseActivationStore { appState.computerUseActivation }

    var body: some View {
        SettingsRow(
            "Computer Use",
            caption: "Allow Limare to use desktop observation and control when a task requires it."
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { store.isGloballyEnabled },
                    set: { enabled in Task { await store.setGloballyEnabled(enabled) } }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityIdentifier("settings.general.computerUse")
            .accessibilityLabel("Computer Use")
        }
        .onAppear { store.refreshReadiness() }
        #if canImport(AppKit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshReadiness()
        }
        #endif
        .onChange(of: store.capabilityStatus) { previous, current in
            switch (previous, current) {
            case (.disabled, .ready), (.needsScreenRecording, .ready), (.needsAccessibility, .ready):
                confirmReady()
            case (_, .ready):
                break
            default:
                confirmationTask?.cancel()
                confirmsReady = false
            }
        }
        .onDisappear {
            confirmationTask?.cancel()
            confirmsReady = false
        }

        switch store.capabilityStatus {
        case .disabled:
            EmptyView()
        case .ready:
            if confirmsReady {
                InlineStatus(kind: .success, message: "Ready. Each action still requires app approval and the current permission mode.")
                    .accessibilityIdentifier("settings.general.computerUse.status")
                    .transition(.opacity)
            }
        case .needsScreenRecording:
            InlineStatus(kind: .warning, message: "Enabled, but macOS Screen Recording permission is missing.",
                         actionTitle: "Open System Settings") { PrivacySettingsOpener.openScreenRecordingSettings() }
                .accessibilityIdentifier("settings.general.computerUse.status")
        case .needsAccessibility:
            InlineStatus(kind: .warning, message: "Enabled, but macOS Accessibility permission is missing for app control.",
                         actionTitle: "Open System Settings") { AccessibilitySettingsOpener.openAccessibilitySettings() }
                .accessibilityIdentifier("settings.general.computerUse.status")
        case .runtimeUnavailable:
            InlineStatus(kind: .error, message: "Enabled, but the Computer Use runtime is unavailable.")
                .accessibilityIdentifier("settings.general.computerUse.status")
        }
    }

    private func confirmReady() {
        confirmationTask?.cancel()
        withAnimation(AppMotion.resolved(AppMotion.confirm)) { confirmsReady = true }
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.resolved(AppMotion.confirmHold)) { confirmsReady = false }
        }
    }
}
