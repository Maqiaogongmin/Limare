import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum ExtensionCardColor: String, Codable, CaseIterable, Sendable, Hashable {
    case amber
    case coral
    case sage
    case slate
    case plum
    case stone

    /// Deterministic palette color for skills, standalone MCP servers, or hooks without an explicit color.
    static func deterministic(for seed: String) -> ExtensionCardColor {
        let palette = Self.allCases
        var hash: UInt64 = 14695981039346656037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    var cardBackground: Color {
        switch self {
        case .amber: Color(nsColor: AppColors.dynamicNSColor(light: 0xFEF8EC, dark: 0x221E15))
        case .coral: Color(nsColor: AppColors.dynamicNSColor(light: 0xFEF3F2, dark: 0x241819))
        case .sage:  Color(nsColor: AppColors.dynamicNSColor(light: 0xF3FAF5, dark: 0x16221B))
        case .slate: Color(nsColor: AppColors.dynamicNSColor(light: 0xF3F7FD, dark: 0x161D29))
        case .plum:  Color(nsColor: AppColors.dynamicNSColor(light: 0xF9F5FE, dark: 0x1F1826))
        case .stone: Color(nsColor: AppColors.dynamicNSColor(light: 0xFFFFFF, dark: 0x17181E))
        }
    }

    var iconBackground: Color {
        switch self {
        case .amber: Color(nsColor: AppColors.dynamicNSColor(light: 0xFDECC8, dark: 0x3A2E16))
        case .coral: Color(nsColor: AppColors.dynamicNSColor(light: 0xFDE2DE, dark: 0x3F2220))
        case .sage:  Color(nsColor: AppColors.dynamicNSColor(light: 0xDCFCE7, dark: 0x1E3A2A))
        case .slate: Color(nsColor: AppColors.dynamicNSColor(light: 0xDBEAFE, dark: 0x1E2E47))
        case .plum:  Color(nsColor: AppColors.dynamicNSColor(light: 0xEDE9FE, dark: 0x322245))
        case .stone: Color(nsColor: AppColors.dynamicNSColor(light: 0xF1F1F3, dark: 0x262832))
        }
    }

    var iconForeground: Color {
        switch self {
        case .amber: Color(nsColor: AppColors.dynamicNSColor(light: 0xB45309, dark: 0xFBBF24))
        case .coral: Color(nsColor: AppColors.dynamicNSColor(light: 0xC2410C, dark: 0xFB923C))
        case .sage:  Color(nsColor: AppColors.dynamicNSColor(light: 0x15803D, dark: 0x4ADE80))
        case .slate: Color(nsColor: AppColors.dynamicNSColor(light: 0x1D4ED8, dark: 0x60A5FA))
        case .plum:  Color(nsColor: AppColors.dynamicNSColor(light: 0x6D28D9, dark: 0xA78BFA))
        case .stone: Color(nsColor: AppColors.dynamicNSColor(light: 0x3F3F46, dark: 0xD4D4D8))
        }
    }

    var hoverStroke: Color {
        iconForeground.opacity(0.32)
    }

    var glareTint: Color {
        iconForeground
    }
}

enum ExtensionCardOrigin: Equatable, Sendable {
    case builtInComputerUse
    case skill(id: String)
    case standaloneMCP(serverID: String)
    case standaloneHook(sourceID: UUID)
}

enum ExtensionCardReadiness: Equatable, Sendable {
    case ready
    case connecting
    case needsAttention(String)
    case disabled
}

enum ExtensionCardSortOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case name
    case usageFrequency
    case dateAdded

    var displayName: String {
        switch self {
        case .name: String(localized: "Name")
        case .usageFrequency: String(localized: "Usage Frequency")
        case .dateAdded: String(localized: "Date Added")
        }
    }
}

struct ExtensionCardItem: Identifiable, Equatable, Sendable {
    let id: String
    let origin: ExtensionCardOrigin
    let title: String
    let subtitle: String
    let description: String
    let iconSymbol: String?
    let monogram: String
    let color: ExtensionCardColor
    let scopeLabel: String
    let isWorkspaceScoped: Bool
    let examples: [String]
    let isEnabled: Bool
    let readiness: ExtensionCardReadiness
    let primarySkill: Skill?
    let linkedMCPServers: [MCPServerConfig]
    let linkedHooks: [HookSource]
    var addedAt: Date = .distantPast
    var usageCount: Int = 0

    static func sorted(_ cards: [ExtensionCardItem], by order: ExtensionCardSortOrder) -> [ExtensionCardItem] {
        cards.sorted { lhs, rhs in
            switch order {
            case .name:
                let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            case .usageFrequency:
                if lhs.usageCount != rhs.usageCount {
                    return lhs.usageCount > rhs.usageCount
                }
                if lhs.isEnabled != rhs.isEnabled {
                    return lhs.isEnabled
                }
                let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            case .dateAdded:
                if lhs.addedAt != rhs.addedAt {
                    return lhs.addedAt > rhs.addedAt
                }
                let cmp = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
    }
}

enum ExtensionCardProjection {
    @MainActor
    static func build(
        skills: SkillStore,
        mcp: MCPStore,
        hooks: HookStore,
        computerUse: ComputerUseActivationStore
    ) -> [ExtensionCardItem] {
        var statuses: [String: MCPServerStatus] = [:]
        for server in mcp.servers {
            statuses[server.id] = mcp.status(for: server.id)
        }
        var usageCounts = skills.extensionUsageCounts
        var recentHookCounts: [String: Int] = [:]
        for exec in hooks.recentExecutions {
            recentHookCounts["hook:\(exec.sourceID.uuidString)", default: 0] += 1
        }
        for (key, count) in recentHookCounts where usageCounts[key] == nil {
            usageCounts[key] = count
        }
        return build(
            skills: skills.skills,
            mcpServers: mcp.servers,
            mcpStatuses: statuses,
            hookSources: hooks.sources,
            isHookTrusted: { hooks.isTrusted(source: $0) },
            computerUseStatus: computerUse.capabilityStatus,
            isComputerUseGloballyEnabled: computerUse.isGloballyEnabled,
            usageCounts: usageCounts
        )
    }

    static func build(
        skills: [Skill],
        mcpServers: [MCPServerConfig],
        mcpStatuses: [String: MCPServerStatus],
        hookSources: [HookSource],
        isHookTrusted: (HookSource) -> Bool,
        computerUseStatus: ComputerUseCapabilityStatus,
        isComputerUseGloballyEnabled: Bool,
        usageCounts: [String: Int] = [:]
    ) -> [ExtensionCardItem] {
        var cards: [ExtensionCardItem] = []

        // 1. Built-in Computer Use card (always pinned first)
        let cuReadiness: ExtensionCardReadiness = {
            guard isComputerUseGloballyEnabled else { return .disabled }
            switch computerUseStatus {
            case .disabled:
                return .disabled
            case .ready:
                return .ready
            case .needsScreenRecording:
                return .needsAttention(String(localized: "Needs Screen Recording permission"))
            case .needsAccessibility:
                return .needsAttention(String(localized: "Needs Accessibility permission"))
            case .runtimeUnavailable:
                return .needsAttention(String(localized: "Runtime unavailable"))
            }
        }()
        let cuDescription = String(localized: "Observe the screen and control Mac apps directly when enabled.")
        cards.append(ExtensionCardItem(
            id: "builtin:computer-use",
            origin: .builtInComputerUse,
            title: String(localized: "Computer Use"),
            subtitle: cuSubtitle(for: cuReadiness, fallback: cuDescription),
            description: cuDescription,
            iconSymbol: validSymbol("display"),
            monogram: "C",
            color: .slate,
            scopeLabel: String(localized: "Built-in"),
            isWorkspaceScoped: false,
            examples: [
                String(localized: "Open System Settings and check my battery health"),
                String(localized: "Inspect the currently active app window and summarize what is on screen")
            ],
            isEnabled: isComputerUseGloballyEnabled,
            readiness: cuReadiness,
            primarySkill: nil,
            linkedMCPServers: [],
            linkedHooks: [],
            addedAt: .distantPast,
            usageCount: usageCounts["builtin:computer-use"] ?? 0
        ))

        // 2. Visible Skill cards (claiming any linked MCP servers)
        var claimedMCPIDs = Set<String>()
        for skill in skills where !skill.isHidden {
            let linked = resolveLinkedMCPServers(requestedIDs: skill.mcpServers, from: mcpServers)
            for server in linked {
                claimedMCPIDs.insert(server.id)
            }

            let isEnabled = skill.isEnabled || linked.contains(where: \.enabled)
            let readiness = computeMCPCollectionReadiness(isEnabled: isEnabled, servers: linked, statuses: mcpStatuses)
            let desc = skill.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitle: String
            if case .needsAttention(let reason) = readiness {
                subtitle = reason
            } else {
                subtitle = desc.isEmpty ? skill.location.displayName : desc
            }

            let skillUsage = (usageCounts["skill:\(skill.id)"] ?? 0)
                + linked.reduce(0) { $0 + (usageCounts["mcp:\($1.id)"] ?? 0) }
            cards.append(ExtensionCardItem(
                id: "skill:\(skill.id)",
                origin: .skill(id: skill.id),
                title: skill.name,
                subtitle: subtitle,
                description: desc,
                iconSymbol: validSymbol(skill.icon),
                monogram: makeMonogram(from: skill.name),
                color: skill.color ?? .deterministic(for: skill.id),
                scopeLabel: skill.location.displayName,
                isWorkspaceScoped: skill.location.isWorkspace,
                examples: Array(skill.examples.prefix(3)),
                isEnabled: isEnabled,
                readiness: readiness,
                primarySkill: skill,
                linkedMCPServers: linked,
                linkedHooks: [],
                addedAt: skill.addedAt,
                usageCount: skillUsage
            ))
        }

        // 3. Standalone MCP cards (unclaimed by any visible skill)
        for server in mcpServers where !claimedMCPIDs.contains(server.id) {
            let status = mcpStatuses[server.id] ?? .disconnected
            let readiness = computeMCPCollectionReadiness(isEnabled: server.enabled, servers: [server], statuses: [server.id: status])
            let note = (server.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let transportDesc = server.url != nil
                ? String(localized: "Remote HTTP MCP server")
                : String(localized: "Local stdio MCP server")
            let desc = note.isEmpty ? transportDesc : note
            let subtitle: String
            if case .needsAttention(let reason) = readiness {
                subtitle = reason
            } else {
                subtitle = desc
            }

            let addedAt = (server.createdAt ?? server.updatedAt).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            cards.append(ExtensionCardItem(
                id: "mcp:\(server.id)",
                origin: .standaloneMCP(serverID: server.id),
                title: server.id,
                subtitle: subtitle,
                description: desc,
                iconSymbol: validSymbol("server.rack"),
                monogram: makeMonogram(from: server.id),
                color: .deterministic(for: "mcp:\(server.id)"),
                scopeLabel: String(localized: "Global"),
                isWorkspaceScoped: false,
                examples: [],
                isEnabled: server.enabled,
                readiness: readiness,
                primarySkill: nil,
                linkedMCPServers: [server],
                linkedHooks: [],
                addedAt: addedAt,
                usageCount: usageCounts["mcp:\(server.id)"] ?? 0
            ))
        }

        // 4. Standalone Hook cards
        for source in hookSources {
            let readiness: ExtensionCardReadiness = {
                guard source.isEnabled else { return .disabled }
                if !isHookTrusted(source) {
                    return .needsAttention(String(localized: "Needs trust review"))
                }
                if let loadError = source.loadError, !loadError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .needsAttention(loadError)
                }
                return .ready
            }()
            let desc = (source.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let handlerCount = source.config.hooks.values.flatMap { $0 }.reduce(0) { $0 + $1.hooks.count }
            let fallbackDesc = String(localized: "Automation hook (\(handlerCount) handlers)")
            let effectiveDesc = desc.isEmpty ? fallbackDesc : desc
            let subtitle: String
            if case .needsAttention(let reason) = readiness {
                subtitle = reason
            } else {
                subtitle = effectiveDesc
            }
            let isWorkspace = source.sourceKind == .codexProject
            let addedAt = Self.fileAddedDate(for: source.packageRootURL)
                ?? Self.fileAddedDate(for: source.configURL)
                ?? source.lastLoadedAt
                ?? .distantPast
            let hookCardID = "hook:\(source.id.uuidString)"

            cards.append(ExtensionCardItem(
                id: hookCardID,
                origin: .standaloneHook(sourceID: source.id),
                title: source.name,
                subtitle: subtitle,
                description: effectiveDesc,
                iconSymbol: validSymbol("arrow.triangle.branch"),
                monogram: makeMonogram(from: source.name),
                color: .deterministic(for: hookCardID),
                scopeLabel: isWorkspace ? String(localized: "Project") : String(localized: "Global"),
                isWorkspaceScoped: isWorkspace,
                examples: [],
                isEnabled: source.isEnabled,
                readiness: readiness,
                primarySkill: nil,
                linkedMCPServers: [],
                linkedHooks: [source],
                addedAt: addedAt,
                usageCount: usageCounts[hookCardID] ?? 0
            ))
        }

        // Sort: Built-in pinned first, then enabled sorted by title, then disabled sorted by title.
        return cards.sorted { lhs, rhs in
            let lhsBuiltIn = lhs.origin == .builtInComputerUse
            let rhsBuiltIn = rhs.origin == .builtInComputerUse
            if lhsBuiltIn != rhsBuiltIn {
                return lhsBuiltIn
            }
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func fileAddedDate(for url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let values = try? url.resourceValues(forKeys: keys)
        return values?.addedToDirectoryDate ?? values?.creationDate ?? values?.contentModificationDate
    }

    private static func cuSubtitle(for readiness: ExtensionCardReadiness, fallback: String) -> String {
        if case .needsAttention(let reason) = readiness {
            return reason
        }
        return fallback
    }

    private static func resolveLinkedMCPServers(requestedIDs: [String], from allServers: [MCPServerConfig]) -> [MCPServerConfig] {
        var matched: [MCPServerConfig] = []
        var seenIDs = Set<String>()
        for reqID in requestedIDs {
            let exact = allServers.first(where: { $0.id == reqID })
            let found = exact ?? allServers.first(where: { $0.id.lowercased() == reqID.lowercased() })
            if let server = found, seenIDs.insert(server.id).inserted {
                matched.append(server)
            }
        }
        return matched
    }

    private static func computeMCPCollectionReadiness(
        isEnabled: Bool,
        servers: [MCPServerConfig],
        statuses: [String: MCPServerStatus]
    ) -> ExtensionCardReadiness {
        guard isEnabled else { return .disabled }
        for server in servers {
            if server.requiresReview {
                return .needsAttention(String(localized: "Needs security review"))
            }
        }
        var hasConnecting = false
        for server in servers where server.enabled {
            let status = statuses[server.id] ?? .disconnected
            switch status {
            case .credentialRequired:
                return .needsAttention(String(localized: "Credentials required"))
            case .signInRequired:
                return .needsAttention(String(localized: "Sign-in required"))
            case .failed(let message, _):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return .needsAttention(trimmed.isEmpty ? String(localized: "Connection failed") : trimmed)
            case .connecting, .signingIn:
                hasConnecting = true
            case .connected, .configSaved, .disconnected:
                break
            }
        }
        return hasConnecting ? .connecting : .ready
    }

    private static func validSymbol(_ name: String?) -> String? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        #if canImport(AppKit)
        return NSImage(systemSymbolName: raw, accessibilityDescription: nil) != nil ? raw : nil
        #else
        return raw
        #endif
    }

    private static func makeMonogram(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "E" }
        return String(first).uppercased()
    }
}

// MARK: - Custom Extension Groups

struct ExtensionCustomGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var cardIDs: [String]
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, cardIDs: [String] = [], isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.cardIDs = cardIDs
        self.isCollapsed = isCollapsed
    }
}

struct ExtensionGroupsPayload: Codable, Equatable, Sendable {
    var groups: [ExtensionCustomGroup] = []
    var hasSeededBuiltInGroup: Bool? = nil
}

enum ExtensionGroupSectionKind: Hashable, Sendable {
    case flat
    case custom(UUID)
    case ungrouped
}

struct ExtensionGroupSection: Identifiable, Equatable, Sendable {
    let kind: ExtensionGroupSectionKind
    let title: String?
    let group: ExtensionCustomGroup?
    let cards: [ExtensionCardItem]

    var id: String {
        switch kind {
        case .flat: return "flat"
        case .custom(let uuid): return "group:\(uuid.uuidString)"
        case .ungrouped: return "ungrouped"
        }
    }
}

@MainActor
@Observable
final class ExtensionGroupStore {
    static let builtInPresetGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let builtInComputerUseCardID = "builtin:computer-use"

    private(set) var groups: [ExtensionCustomGroup] = []
    private let fileURL: URL

    init(storageRootURL: URL = LimareStorage.defaultRoot) {
        self.fileURL = storageRootURL.appendingPathComponent("extension_groups_v1.json")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(ExtensionGroupsPayload.self, from: data) {
            self.groups = payload.groups
            if payload.hasSeededBuiltInGroup != true {
                seedBuiltInGroupIfNeeded()
                persist()
            }
        } else {
            self.groups = [
                ExtensionCustomGroup(
                    id: Self.builtInPresetGroupID,
                    name: String(localized: "Built-in"),
                    cardIDs: [Self.builtInComputerUseCardID]
                )
            ]
            persist()
        }
    }

    private func seedBuiltInGroupIfNeeded() {
        let localizedBuiltIn = String(localized: "Built-in")
        let hasComputerUseAnywhere = groups.contains { $0.cardIDs.contains(Self.builtInComputerUseCardID) }
        if let matchIndex = groups.firstIndex(where: { group in
            if group.id == Self.builtInPresetGroupID { return true }
            let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "内置"
                || trimmed.caseInsensitiveCompare("Built-in") == .orderedSame
                || trimmed.caseInsensitiveCompare(localizedBuiltIn) == .orderedSame
        }) {
            if !hasComputerUseAnywhere {
                groups[matchIndex].cardIDs.append(Self.builtInComputerUseCardID)
            }
        } else {
            let initialCards = hasComputerUseAnywhere ? [] : [Self.builtInComputerUseCardID]
            groups.insert(
                ExtensionCustomGroup(
                    id: Self.builtInPresetGroupID,
                    name: localizedBuiltIn,
                    cardIDs: initialCards
                ),
                at: 0
            )
        }
    }

    @discardableResult
    func createGroup(name: String, cardIDs: [String] = []) -> ExtensionCustomGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let uniqueCardIDs = deduplicated(cardIDs)
        removeCardIDsFromAllGroups(Set(uniqueCardIDs))

        let group = ExtensionCustomGroup(name: trimmed, cardIDs: uniqueCardIDs)
        groups.append(group)
        persist()
        return group
    }

    func renameGroup(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = trimmed
        persist()
    }

    func deleteGroup(id: UUID) {
        let originalCount = groups.count
        groups.removeAll { $0.id == id }
        guard groups.count != originalCount else { return }
        persist()
    }

    func setCollapsed(_ isCollapsed: Bool, for id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              groups[index].isCollapsed != isCollapsed else { return }
        groups[index].isCollapsed = isCollapsed
        persist()
    }

    func toggleCollapsed(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].isCollapsed.toggle()
        persist()
    }

    func moveGroup(id: UUID, direction: Int) {
        guard direction != 0,
              let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = index + direction
        guard groups.indices.contains(targetIndex) else { return }
        let item = groups.remove(at: index)
        groups.insert(item, at: targetIndex)
        persist()
    }

    func assignCards(_ cardIDs: [String], toGroup groupID: UUID?) {
        let uniqueCardIDs = deduplicated(cardIDs)
        guard !uniqueCardIDs.isEmpty else { return }

        removeCardIDsFromAllGroups(Set(uniqueCardIDs))
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) {
            let existing = Set(groups[index].cardIDs)
            for id in uniqueCardIDs where !existing.contains(id) {
                groups[index].cardIDs.append(id)
            }
        }
        persist()
    }

    func currentGroupID(for cardID: String) -> UUID? {
        groups.first(where: { $0.cardIDs.contains(cardID) })?.id
    }

    func buildSections(from filteredCards: [ExtensionCardItem], isFiltering: Bool) -> [ExtensionGroupSection] {
        guard !groups.isEmpty else {
            return filteredCards.isEmpty
                ? []
                : [ExtensionGroupSection(kind: .flat, title: nil, group: nil, cards: filteredCards)]
        }

        var sections: [ExtensionGroupSection] = []
        var claimedIDs = Set<String>()

        for group in groups {
            let memberSet = Set(group.cardIDs)
            let groupCards = filteredCards.filter { memberSet.contains($0.id) }
            for card in groupCards {
                claimedIDs.insert(card.id)
            }
            if !groupCards.isEmpty || !isFiltering {
                sections.append(ExtensionGroupSection(
                    kind: .custom(group.id),
                    title: group.name,
                    group: group,
                    cards: groupCards
                ))
            }
        }

        let ungroupedCards = filteredCards.filter { !claimedIDs.contains($0.id) }
        if !ungroupedCards.isEmpty {
            sections.append(ExtensionGroupSection(
                kind: .ungrouped,
                title: String(localized: "Ungrouped"),
                group: nil,
                cards: ungroupedCards
            ))
        }

        return sections
    }

    private func removeCardIDsFromAllGroups(_ idSet: Set<String>) {
        guard !idSet.isEmpty else { return }
        for index in groups.indices {
            groups[index].cardIDs.removeAll { idSet.contains($0) }
        }
    }

    private func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private func persist() {
        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dirURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ExtensionGroupsPayload(groups: groups, hasSeededBuiltInGroup: true)) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
