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
        case .scheduled: String(localized: "Schedules")
        case .settingsGeneral: String(localized: "General")
        case .settingsProviders: String(localized: "Providers")
        case .settingsModelGroups: String(localized: "Model Groups")
        case .settingsSkills: String(localized: "Skills")
        case .settingsSoul: String(localized: "Personalization")
        case .settingsArchived: String(localized: "Archived")
        case .settingsMCP: String(localized: "MCP")
        case .settingsHooks: String(localized: "Hooks")
        case .settingsPermissions: String(localized: "Permissions")
        case .settingsRemoteAccess: String(localized: "Remote Access")
        case .settingsLogs: String(localized: "Logs")
        }
    }
}
