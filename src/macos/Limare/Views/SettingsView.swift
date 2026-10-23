import SwiftUI

struct SettingsDetailView: View {
    let screen: AppScreen

    var body: some View {
        Group {
            switch screen {
            case .settingsProviders:
                ProviderSettingsView()
            case .settingsModelGroups:
                ModelGroupsView()
            case .settingsSkills:
                SkillsSettingsView()
            case .settingsSoul:
                SoulSettingsView()
            case .settingsArchived:
                ArchivedConversationsSettingsView()
            case .settingsMCP:
                MCPSettingsView()
            case .settingsHooks:
                HooksSettingsView()
            case .settingsPermissions:
                PermissionSettingsView()
            case .settingsRemoteAccess:
                RemoteAccessSettingsView()
            case .settingsLogs:
                DebugLogsView()
            case .settingsGeneral, .chat, .scheduled:
                GeneralSettingsView()
            }
        }
        .accessibilityIdentifier("settings.surface")
        .navigationTitle(screen.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The same warm canvas as the chat, up under the title bar with no rule beneath it;
        // switches, links and other tinted controls in charcoal rather than the system blue.
        .background(AppColors.canvas.ignoresSafeArea())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(AppColors.controlOn)
    }
}
