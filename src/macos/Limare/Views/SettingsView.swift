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
            case .settingsGeneral, .chat:
                GeneralSettingsView()
            }
        }
        .accessibilityIdentifier("settings.surface")
        .navigationTitle(screen.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
