enum AppScreen: String, Hashable {
    case chat
    case settingsGeneral
    case settingsProviders
    case settingsModelGroups
    case settingsSkills
    case settingsSoul
    case settingsMCP
    case settingsHooks
    case settingsPermissions
    case settingsRemoteAccess
    case settingsLogs

    var isSettings: Bool { self != .chat }

    var title: String {
        switch self {
        case .chat: "Limare"
        case .settingsGeneral: "General"
        case .settingsProviders: "Providers"
        case .settingsModelGroups: "Model Groups"
        case .settingsSkills: "Skills"
        case .settingsSoul: "Personalization"
        case .settingsMCP: "MCP"
        case .settingsHooks: "Hooks"
        case .settingsPermissions: "Permissions"
        case .settingsRemoteAccess: "Remote Access"
        case .settingsLogs: "Logs"
        }
    }
}
