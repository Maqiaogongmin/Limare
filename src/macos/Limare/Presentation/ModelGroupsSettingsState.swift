import Foundation
import Observation

enum ModelGroupsSelection: Hashable, Sendable {
    case modelUse
    case group(String)
}

enum GroupMemberChatReadiness: Equatable, Sendable {
    case ready
    case notReady(reason: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .ready:
            return "Ready for Chat"
        case .notReady:
            return "Not Ready for Chat"
        }
    }
}

struct RoleMemberStatusItem: Sendable, Equatable {
    let roleName: String
    let task: ModelGroupStore.ModelTaskKind
    let readiness: ModelGroupStore.TaskMemberReadiness

    init(
        roleName: String,
        task: ModelGroupStore.ModelTaskKind,
        readiness: ModelGroupStore.TaskMemberReadiness
    ) {
        self.roleName = roleName
        self.task = task
        self.readiness = readiness
    }
}

struct GroupMemberDisplayItem: Identifiable, Sendable, Equatable {
    let id: String // entryId
    let index: Int
    let modelName: String
    let providerName: String
    let roleStatuses: [RoleMemberStatusItem]
    let isUnbound: Bool
    let knownCapabilities: [String]
    let chatReadiness: GroupMemberChatReadiness

    var isAvailable: Bool {
        if isUnbound {
            return false
        }
        if roleStatuses.isEmpty {
            return chatReadiness.isReady
        }
        return roleStatuses.contains { $0.readiness.isReady }
    }

    var unavailableReason: String? {
        if isUnbound {
            return "Unassigned Group"
        }
        if let firstNotReady = roleStatuses.first(where: { !$0.readiness.isReady }) {
            return firstNotReady.readiness.label
        }
        if case .notReady(let reason) = chatReadiness {
            return reason
        }
        return nil
    }

    init(
        id: String,
        index: Int,
        modelName: String,
        providerName: String,
        roleStatuses: [RoleMemberStatusItem] = [],
        isUnbound: Bool = false,
        knownCapabilities: [String] = [],
        chatReadiness: GroupMemberChatReadiness
    ) {
        self.id = id
        self.index = index
        self.modelName = modelName
        self.providerName = providerName
        self.roleStatuses = roleStatuses
        self.isUnbound = isUnbound
        self.knownCapabilities = knownCapabilities
        self.chatReadiness = chatReadiness
    }

    init(
        id: String,
        index: Int,
        modelName: String,
        providerName: String,
        isAvailable: Bool,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.index = index
        self.modelName = modelName
        self.providerName = providerName
        self.roleStatuses = []
        self.isUnbound = false
        self.knownCapabilities = []
        if isAvailable {
            self.chatReadiness = .ready
        } else {
            self.chatReadiness = .notReady(reason: unavailableReason ?? "Unavailable")
        }
    }
}

@MainActor
@Observable
final class ModelGroupsSettingsState {
    var selection: ModelGroupsSelection
    var showCreateGroupSheet: Bool = false
    var showSpecialistModelsSheet: Bool = false
    var showAddModelsSheet: Bool = false
    var pendingDeleteGroupID: String? = nil

    init(selection: ModelGroupsSelection = .modelUse) {
        self.selection = selection
    }

    // MARK: - Group Summaries

    func summary(for group: ModelGroup) -> String {
        let count = group.memberEntryIds.count
        let countStr = "\(count) \(count == 1 ? "model" : "models")"
        let stratStr = group.strategy == .fallback ? "Fallback" : "Load Balance"
        return "\(countStr) · \(stratStr)"
    }

    func roleBadges(for group: ModelGroup, store: ModelGroupStore) -> [String] {
        var badges: [String] = []
        if store.defaultPrimaryGroupId == group.id {
            badges.append("Chat")
        }
        if store.defaultSubGroupId == group.id {
            badges.append("Helper")
        }
        if store.visionGroupId == group.id {
            badges.append("Images")
        }
        if store.voiceInputGroupId == group.id {
            badges.append("Voice In")
        }
        if store.voiceOutputGroupId == group.id {
            badges.append("Voice Out")
        }
        return badges
    }

    // MARK: - Member Presentation

    func resolvedMembers(
        for group: ModelGroup,
        providers: [ProviderConfiguration],
        store: ModelGroupStore? = nil
    ) -> [GroupMemberDisplayItem] {
        var roles: [(name: String, task: ModelGroupStore.ModelTaskKind)] = []
        let hasStore = (store != nil)
        if let store {
            if store.defaultPrimaryGroupId == group.id {
                roles.append(("Chat", .chat))
            }
            if store.defaultSubGroupId == group.id {
                roles.append(("Helper", .chat))
            }
            if store.visionGroupId == group.id {
                roles.append(("Images", .visionInput))
            }
            if store.voiceInputGroupId == group.id {
                roles.append(("Voice In", .voiceInputASR))
            }
            if store.voiceOutputGroupId == group.id {
                roles.append(("Voice Out", .voiceOutputTTS))
            }
        } else {
            roles = [("Chat", .chat)]
        }

        let isUnbound = hasStore && roles.isEmpty

        return group.memberEntryIds.enumerated().map { index, entryId in
            let chatEval = ModelGroupStore.evaluateMemberEligibility(entryId: entryId, providers: providers, requireImageInput: false)
            let chatReadiness: GroupMemberChatReadiness = chatEval.isChatEligible ? .ready : .notReady(reason: chatEval.unavailableReason ?? "Unavailable")

            var roleStatuses: [RoleMemberStatusItem] = []
            for role in roles {
                let taskEval = ModelGroupStore.evaluateMemberTaskEligibility(
                    entryId: entryId,
                    task: role.task,
                    providers: providers
                )
                roleStatuses.append(RoleMemberStatusItem(
                    roleName: role.name,
                    task: role.task,
                    readiness: taskEval.readiness
                ))
            }

            var capabilities: [String] = []
            if let model = chatEval.model, let mod = model.modality {
                if mod.contains(.textInput) { capabilities.append("Text In") }
                if mod.contains(.textOutput) { capabilities.append("Text Out") }
                if mod.contains(.audioOutput) { capabilities.append("Audio Out") }
                if mod.contains(.imageInput) { capabilities.append("Vision") }
                if mod.contains(.audioInput) { capabilities.append("Audio In") }
            }

            return GroupMemberDisplayItem(
                id: entryId,
                index: index + 1,
                modelName: chatEval.modelDisplayName + (chatEval.model?.discovery.badge.map { " · \($0)" } ?? ""),
                providerName: chatEval.providerName,
                roleStatuses: roleStatuses,
                isUnbound: isUnbound,
                knownCapabilities: capabilities,
                chatReadiness: chatReadiness
            )
        }
    }

    // MARK: - Reasoning Warning

    func unsupportedReasoningMembers(for group: ModelGroup, providers: [ProviderConfiguration]) -> [String] {
        var names: [String] = []
        for entryId in group.memberEntryIds {
            guard let parsed = ModelGroup.parseEntryId(entryId),
                  let provider = providers.first(where: { $0.id == parsed.providerID }),
                  let model = provider.models.first(where: { $0.id == parsed.modelID }) else {
                continue
            }
            // Only flag explicitly unsupported models (supportsReasoning == false). Unknown (nil) is not unsupported.
            if model.supportsReasoning == false {
                names.append(model.displayName)
            }
        }
        return names
    }

    // MARK: - Voice Fallback Helpers

    func voiceInputStatus(for groupID: String?, store: ModelGroupStore, providers: [ProviderConfiguration]) -> String? {
        guard let groupID, let group = store.group(for: groupID) else {
            return nil
        }
        let candidates = store.voiceInputCandidates(for: group, providers: providers)
        if candidates.isEmpty {
            return "This group currently has no compatible speech recognition models. Limare will use System Speech."
        }
        return nil
    }

    func voiceOutputStatus(for groupID: String?, store: ModelGroupStore, providers: [ProviderConfiguration]) -> String? {
        guard let groupID, let group = store.group(for: groupID) else {
            return nil
        }
        let candidates = store.voiceOutputCandidates(for: group, providers: providers)
        if candidates.isEmpty {
            return "This group currently has no compatible text-to-speech models. Limare will use System Voice."
        }
        return nil
    }

    // MARK: - Images Capability Helper

    func imagesStatus(for groupID: String?, store: ModelGroupStore, providers: [ProviderConfiguration]) -> String? {
        guard let groupID, let group = store.group(for: groupID) else {
            return nil
        }
        let candidates = store.visionCandidates(for: group, providers: providers)
        if candidates.isEmpty {
            return "This group currently has no image-capable models Limare can use. Image understanding will be unavailable."
        }
        return nil
    }

    // MARK: - Specialist Models Summary

    func specialistSummary(store: ModelGroupStore) -> String {
        let groupCount = store.agentLoopGroupIds.count
        let modelCount = store.agentLoopModelEntryIds.count
        let total = groupCount + modelCount
        if total == 0 {
            return "None"
        } else if groupCount > 0 && modelCount > 0 {
            let grpStr = "\(groupCount) \(groupCount == 1 ? "group" : "groups")"
            let mdlStr = "\(modelCount) \(modelCount == 1 ? "model" : "models")"
            return "\(grpStr) · \(mdlStr)"
        } else if groupCount > 0 {
            return "\(groupCount) \(groupCount == 1 ? "group" : "groups")"
        } else {
            return "\(modelCount) \(modelCount == 1 ? "model" : "models")"
        }
    }
}
