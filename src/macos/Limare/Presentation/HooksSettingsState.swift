import Foundation
import Observation

public enum HookManagementRoute: Hashable, Sendable {
    case overview
    case automations
    case review
}

public enum HookHandlerAvailability: String, Sendable, Equatable {
    case available
    case disabledByPackage
    case disabledByUser
    case unsupportedEvent
    case unsupportedHandlerType
    case unsupportedAsync
    case invalidConfiguration

    public var isRunnable: Bool {
        self == .available
    }

    public var displayText: String {
        switch self {
        case .available:
            return "Enabled"
        case .disabledByPackage:
            return "Disabled by package configuration"
        case .disabledByUser:
            return "Disabled"
        case .unsupportedEvent:
            return "Unavailable — Event not supported by this version of Limare"
        case .unsupportedHandlerType:
            return "Unavailable — Handler type not supported"
        case .unsupportedAsync:
            return "Unavailable — Async execution not supported"
        case .invalidConfiguration:
            return "Unavailable — Command is missing"
        }
    }
}

@MainActor
@Observable
final class HooksSettingsState {
    var presentedSourceID: UUID?
    var reviewSource: HookSource?
    var managementRoute: HookManagementRoute = .overview
    var searchText: String = ""
    var isAdvancedExpanded: Bool = false
    var pendingDeleteSourceID: UUID?
    var importErrorMessage: String?
    var importErrorDetails: String?

    init(
        presentedSourceID: UUID? = nil,
        reviewSource: HookSource? = nil,
        managementRoute: HookManagementRoute = .overview,
        searchText: String = "",
        isAdvancedExpanded: Bool = false,
        pendingDeleteSourceID: UUID? = nil,
        importErrorMessage: String? = nil,
        importErrorDetails: String? = nil
    ) {
        self.presentedSourceID = presentedSourceID
        self.reviewSource = reviewSource
        self.managementRoute = managementRoute
        self.searchText = searchText
        self.isAdvancedExpanded = isAdvancedExpanded
        self.pendingDeleteSourceID = pendingDeleteSourceID
        self.importErrorMessage = importErrorMessage
        self.importErrorDetails = importErrorDetails
    }

    func resetSheetState() {
        presentedSourceID = nil
        managementRoute = .overview
        isAdvancedExpanded = false
        pendingDeleteSourceID = nil
    }

    func filteredSources(from allSources: [HookSource]) -> [HookSource] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return allSources }
        return allSources.filter { source in
            source.name.localizedCaseInsensitiveContains(query)
                || (source.description ?? "").localizedCaseInsensitiveContains(query)
                || source.configURL.path.localizedCaseInsensitiveContains(query)
                || source.sourceKind.displayName.localizedCaseInsensitiveContains(query)
                || source.config.hooks.keys.contains { friendlyEventName(for: $0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func friendlyEventName(for rawKey: String) -> String {
        switch rawKey {
        case HookEventName.sessionStart.rawValue:
            return "When a conversation starts"
        case HookEventName.userPromptSubmit.rawValue:
            return "When you send a message"
        case HookEventName.preToolUse.rawValue:
            return "Before Limare uses a tool"
        case HookEventName.postToolUse.rawValue:
            return "After Limare uses a tool"
        case HookEventName.postToolUseFailure.rawValue:
            return "After a tool fails"
        case HookEventName.stop.rawValue:
            return "When Limare finishes a response"
        case HookEventName.sessionEnd.rawValue:
            return "When a conversation ends"
        case HookEventName.preCompact.rawValue:
            return "Before history compaction"
        case HookEventName.postCompact.rawValue:
            return "After history compaction"
        case HookEventName.subagentStart.rawValue:
            return "When a subagent starts"
        case HookEventName.subagentStop.rawValue:
            return "When a subagent stops"
        case HookEventName.notification.rawValue:
            return "On agent notification"
        case HookEventName.taskCompleted.rawValue:
            return "When task completes"
        case HookEventName.permissionRequest.rawValue:
            return "On permission request"
        case HookEventName.interrupt.rawValue:
            return "When task interrupted"
        default:
            return rawKey
        }
    }

    func automationPresentationStatus(
        source: HookSource,
        eventKey: String,
        hook: HookHandlerConfig
    ) -> HookHandlerAvailability {
        let eventSupported = HookEventName(rawValue: eventKey)?.isSupported ?? false
        if !eventSupported {
            return .unsupportedEvent
        }
        if !hook.type.isSupported {
            return .unsupportedHandlerType
        }
        if hook.isAsync == true {
            return .unsupportedAsync
        }
        if !hook.hasRunnableCommand {
            return .invalidConfiguration
        }
        if hook.enabled == false {
            return .disabledByPackage
        }
        if source.disabledHandlerIDs.contains(hook.id) {
            return .disabledByUser
        }
        return .available
    }

    func automationCounts(for source: HookSource) -> (available: Int, unavailable: Int, total: Int) {
        var available = 0
        var total = 0
        for (eventKey, groups) in source.config.hooks {
            for group in groups {
                for hook in group.hooks {
                    total += 1
                    let status = automationPresentationStatus(source: source, eventKey: eventKey, hook: hook)
                    if status == .available {
                        available += 1
                    }
                }
            }
        }
        let unavailable = total - available
        return (available: available, unavailable: unavailable, total: total)
    }

    func automationSummaryText(for source: HookSource) -> String {
        let counts = automationCounts(for: source)
        if counts.total == 0 {
            return "No automations"
        }
        if counts.unavailable == 0 {
            return "\(counts.available) \(counts.available == 1 ? "automation" : "automations")"
        }
        return "\(counts.available) available · \(counts.unavailable) unavailable"
    }

    func overviewEventBullets(for source: HookSource) -> [String] {
        var bullets: [String] = []
        for key in source.config.hooks.keys.sorted() {
            let groups = source.config.hooks[key] ?? []
            let hasAvailableHandler = groups.contains { group in
                group.hooks.contains { hook in
                    automationPresentationStatus(source: source, eventKey: key, hook: hook) == .available
                }
            }
            if hasAvailableHandler {
                bullets.append(friendlyEventName(for: key))
            }
        }
        return bullets
    }

    func shouldShowEnableToggle(for source: HookSource, isTrusted: Bool) -> Bool {
        isTrusted && source.loadError == nil
    }

    func trustStatusText(for source: HookSource, isTrusted: Bool) -> String {
        if source.loadError != nil {
            return "Load Error"
        }
        return isTrusted ? "Trusted" : "Needs Review"
    }

    func trustStatusKind(for source: HookSource, isTrusted: Bool) -> InlineStatusKind {
        if source.loadError != nil {
            return .error
        }
        return isTrusted ? .success : .warning
    }
}
