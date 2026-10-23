enum AppScreen: String, Hashable {
    case chat
    /// The scheduled-task manager: its list in the sidebar, the selected task beside it.
    case scheduled
    case settingsGeneral
    case settingsProviders
    case settingsModelGroups
    case settingsSkills
    case settingsSoul
    case settingsArchived
    case settingsMCP
    case settingsHooks
    case settingsPermissions
    case settingsRemoteAccess
    case settingsLogs

    var isSettings: Bool { self != .chat && self != .scheduled }

    var title: String {
        switch self {
        case .chat: "Limare"
        case .scheduled: "Schedules"
        case .settingsGeneral: "General"
        case .settingsProviders: "Providers"
        case .settingsModelGroups: "Model Groups"
        case .settingsSkills: "Skills"
        case .settingsSoul: "Personalization"
        case .settingsArchived: "Archived"
        case .settingsMCP: "MCP"
        case .settingsHooks: "Hooks"
        case .settingsPermissions: "Permissions"
        case .settingsRemoteAccess: "Remote Access"
        case .settingsLogs: "Logs"
        }
    }
}
