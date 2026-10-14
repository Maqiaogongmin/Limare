import Foundation
import Observation

@MainActor
@Observable
final class ModelGroupStore {
    private(set) var groups: [ModelGroup] = []
    var defaultPrimaryGroupId: String? {
        didSet { persist() }
    }
    var defaultSubGroupId: String? {
        didSet { persist() }
    }
    var voiceInputGroupId: String? {
        didSet { persist() }
    }
    var voiceOutputGroupId: String? {
        didSet { persist() }
    }
    var visionGroupId: String? {
        didSet { persist() }
    }
    var agentLoopModelEntryIds: [String] = [] {
        didSet { persist() }
    }
    var agentLoopGroupIds: [String] = [] {
        didSet { persist() }
    }

    private let fileURL: URL
    private let logs: DebugLogStore

    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        logs: DebugLogStore
    ) {
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.fileURL = root.appendingPathComponent("model-groups.json")
        self.logs = logs
        load()
    }

    func group(for id: String) -> ModelGroup? {
        groups.first { $0.id == id }
    }

    func addGroup(_ group: ModelGroup) {
        groups.append(group)
        if defaultPrimaryGroupId == nil {
            defaultPrimaryGroupId = group.id
        }
        persist()
        logs.info("ModelGroup", "Created model group '\(group.name)' (ID: \(group.id)).")
    }

    func updateGroup(_ group: ModelGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        persist()
        logs.info("ModelGroup", "Updated model group '\(group.name)'.")
    }

    func removeGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        if defaultPrimaryGroupId == id { defaultPrimaryGroupId = nil }
        if defaultSubGroupId == id { defaultSubGroupId = nil }
        if voiceInputGroupId == id { voiceInputGroupId = nil }
        if voiceOutputGroupId == id { voiceOutputGroupId = nil }
        if visionGroupId == id { visionGroupId = nil }
        agentLoopGroupIds.removeAll { $0 == id }
        persist()
        logs.info("ModelGroup", "Removed model group '\(group.name)' and cleared associated pointers.")
    }

    func reorderGroups(_ ids: [String]) {
        var reordered: [ModelGroup] = []
        for id in ids {
            if let g = groups.first(where: { $0.id == id }) {
                reordered.append(g)
            }
        }
        for g in groups where !ids.contains(g.id) {
            reordered.append(g)
        }
        groups = reordered
        persist()
    }

    func addRuntimeModelEntry(_ entryID: String) {
        guard !agentLoopModelEntryIds.contains(entryID) else { return }
        agentLoopModelEntryIds.append(entryID)
    }

    func removeRuntimeModelEntry(_ entryID: String) {
        agentLoopModelEntryIds.removeAll { $0 == entryID }
    }

    func reorderRuntimeModelEntries(_ ids: [String]) {
        agentLoopModelEntryIds = ids
    }

    func addRuntimeGroup(_ groupID: String) {
        guard group(for: groupID) != nil, !agentLoopGroupIds.contains(groupID) else { return }
        agentLoopGroupIds.append(groupID)
    }

    func removeRuntimeGroup(_ groupID: String) {
        agentLoopGroupIds.removeAll { $0 == groupID }
    }

    func reorderRuntimeGroups(_ ids: [String]) {
        agentLoopGroupIds = ids
    }

    public enum ModelTaskKind: String, Sendable, CaseIterable, Equatable {
        case chat
        case voiceOutputTTS
        case voiceInputASR
        case visionInput
    }

    public enum TaskMemberReadiness: Equatable, Sendable {
        case ready(task: ModelTaskKind)
        case capabilityUnknown(task: ModelTaskKind)
        case protocolUnsupported(task: ModelTaskKind, reason: String)
        case credentialMissing(task: ModelTaskKind)
        case modelRemoved(task: ModelTaskKind)
        case notReady(task: ModelTaskKind, reason: String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        public var label: String {
            switch self {
            case .ready(let task):
                switch task {
                case .chat: return "Ready for Chat"
                case .voiceOutputTTS: return "Ready for Voice Output"
                case .voiceInputASR: return "Ready for Voice In"
                case .visionInput: return "Ready for Images"
                }
            case .capabilityUnknown(let task):
                switch task {
                case .chat: return "Chat capability unverified"
                default: return "Capability Unknown"
                }
            case .protocolUnsupported:
                return "Protocol Unsupported"
            case .credentialMissing(let task):
                switch task {
                case .chat: return "API Key missing"
                default: return "Credential Missing"
                }
            case .modelRemoved(let task):
                switch task {
                case .chat: return "Removed by provider"
                default: return "Model Removed"
                }
            case .notReady(_, let reason):
                return reason
            }
        }

        public var diagnosticReason: String {
            switch self {
            case .ready: return "Ready"
            case .capabilityUnknown: return "Capability unknown"
            case .protocolUnsupported(_, let reason): return reason
            case .credentialMissing: return "Credential missing"
            case .modelRemoved: return "Model removed"
            case .notReady(_, let reason): return reason
            }
        }
    }

    public struct GroupMemberEligibility: Equatable, Sendable {
        public let entryId: String
        public let parsedProviderId: UUID?
        public let parsedModelId: String?
        public let provider: ProviderConfiguration?
        public let model: ProviderModel?
        public let isChatEligible: Bool
        public let unavailableReason: String?

        public var providerName: String {
            if let provider {
                return provider.name
            }
            return parsedProviderId != nil ? "Unknown Provider" : "Unknown"
        }

        public var modelDisplayName: String {
            model?.displayName ?? (parsedModelId ?? entryId)
        }
    }

    public static func evaluateMemberTaskEligibility(
        entryId: String,
        task: ModelTaskKind,
        providers: [ProviderConfiguration]
    ) -> (readiness: TaskMemberReadiness, provider: ProviderConfiguration?, model: ProviderModel?) {
        guard let parsed = ModelGroup.parseEntryId(entryId),
              !parsed.modelID.isEmpty else {
            return (.notReady(task: task, reason: "Invalid entry ID"), nil, nil)
        }

        guard let provider = providers.first(where: { $0.id == parsed.providerID }) else {
            return (.notReady(task: task, reason: "Provider missing"), nil, nil)
        }

        guard let model = provider.models.first(where: { $0.id == parsed.modelID }) else {
            return (.notReady(task: task, reason: "Model missing"), provider, nil)
        }

        if model.discovery.isRemoved {
            return (.modelRemoved(task: task), provider, model)
        }

        if provider.authenticationMode != .none && !provider.hasStoredSecret {
            return (.credentialMissing(task: task), provider, model)
        }

        if provider.authenticationMode == .oauth && task == .voiceOutputTTS {
            return (.notReady(task: .voiceOutputTTS, reason: "OAuth does not authorize speech synthesis (API Key required)"), provider, model)
        }

        switch task {
        case .chat:
            if let modality = model.modality {
                if modality.contains(.textInput) && modality.contains(.textOutput) {
                    return (.ready(task: .chat), provider, model)
                } else {
                    return (.notReady(task: .chat, reason: "Model does not support text input/output"), provider, model)
                }
            } else {
                return (.capabilityUnknown(task: .chat), provider, model)
            }

        case .voiceOutputTTS:
            if model.modality != nil {
                guard isDedicatedTTS(model) else {
                    return (.notReady(task: .voiceOutputTTS, reason: "Model does not have TTS modality (text in + audio out)"), provider, model)
                }
            } else {
                return (.capabilityUnknown(task: .voiceOutputTTS), provider, model)
            }

            let route = VoiceOutputRouting.route(provider: provider, modelID: model.id)
            switch route {
            case .protocolUnsupported(let reason):
                return (.protocolUnsupported(task: .voiceOutputTTS, reason: reason), provider, model)
            case .geminiNativeInteractions, .openAIAudioSpeech:
                return (.ready(task: .voiceOutputTTS), provider, model)
            }

        case .voiceInputASR:
            if model.modality != nil {
                guard isDedicatedASR(model) else {
                    return (.notReady(task: .voiceInputASR, reason: "Model does not have speech recognition modality"), provider, model)
                }
                return (.ready(task: .voiceInputASR), provider, model)
            } else {
                return (.capabilityUnknown(task: .voiceInputASR), provider, model)
            }

        case .visionInput:
            if let modality = model.modality {
                guard modality.contains(.imageInput) else {
                    return (.notReady(task: .visionInput, reason: "Model does not support image input"), provider, model)
                }
                return (.ready(task: .visionInput), provider, model)
            } else {
                return (.capabilityUnknown(task: .visionInput), provider, model)
            }
        }
    }

    public static func evaluateMemberEligibility(
        entryId: String,
        providers: [ProviderConfiguration],
        requireImageInput: Bool = false
    ) -> GroupMemberEligibility {
        guard let parsed = ModelGroup.parseEntryId(entryId),
              !parsed.modelID.isEmpty else {
            return GroupMemberEligibility(
                entryId: entryId,
                parsedProviderId: nil,
                parsedModelId: nil,
                provider: nil,
                model: nil,
                isChatEligible: false,
                unavailableReason: "Invalid entry ID"
            )
        }

        guard let provider = providers.first(where: { $0.id == parsed.providerID }) else {
            return GroupMemberEligibility(
                entryId: entryId,
                parsedProviderId: parsed.providerID,
                parsedModelId: parsed.modelID,
                provider: nil,
                model: nil,
                isChatEligible: false,
                unavailableReason: "Provider missing"
            )
        }

        guard let model = provider.models.first(where: { $0.id == parsed.modelID }) else {
            return GroupMemberEligibility(
                entryId: entryId,
                parsedProviderId: parsed.providerID,
                parsedModelId: parsed.modelID,
                provider: provider,
                model: nil,
                isChatEligible: false,
                unavailableReason: "Model missing"
            )
        }

        if model.discovery.isRemoved {
            return GroupMemberEligibility(entryId: entryId, parsedProviderId: parsed.providerID,
                parsedModelId: parsed.modelID, provider: provider, model: model,
                isChatEligible: false, unavailableReason: "Removed by provider")
        }

        if provider.authenticationMode != .none && !provider.hasStoredSecret {
            return GroupMemberEligibility(
                entryId: entryId,
                parsedProviderId: parsed.providerID,
                parsedModelId: parsed.modelID,
                provider: provider,
                model: model,
                isChatEligible: false,
                unavailableReason: "API Key missing"
            )
        }

        if let modality = model.modality {
            guard modality.contains(.textInput) && modality.contains(.textOutput) else {
                return GroupMemberEligibility(
                    entryId: entryId,
                    parsedProviderId: parsed.providerID,
                    parsedModelId: parsed.modelID,
                    provider: provider,
                    model: model,
                    isChatEligible: false,
                    unavailableReason: "Model does not support text input/output"
                )
            }
        }

        if requireImageInput {
            guard model.modality?.contains(.imageInput) == true else {
                return GroupMemberEligibility(
                    entryId: entryId,
                    parsedProviderId: parsed.providerID,
                    parsedModelId: parsed.modelID,
                    provider: provider,
                    model: model,
                    isChatEligible: false,
                    unavailableReason: "Model does not support image input"
                )
            }
        }

        return GroupMemberEligibility(
            entryId: entryId,
            parsedProviderId: parsed.providerID,
            parsedModelId: parsed.modelID,
            provider: provider,
            model: model,
            isChatEligible: true,
            unavailableReason: nil
        )
    }

    func availableEntries(
        for group: ModelGroup,
        requireImageInput: Bool = false,
        providers: [ProviderConfiguration]
    ) -> [(provider: ProviderConfiguration, modelID: String, entryId: String)] {
        var result: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        for entryId in group.memberEntryIds {
            let eval = Self.evaluateMemberEligibility(entryId: entryId, providers: providers, requireImageInput: requireImageInput)
            if eval.isChatEligible, let prov = eval.provider, let modelID = eval.parsedModelId {
                result.append((prov, modelID, entryId))
            }
        }
        return result
    }

    func visionCandidates(
        for group: ModelGroup,
        providers: [ProviderConfiguration]
    ) -> [(provider: ProviderConfiguration, modelID: String, entryId: String)] {
        var result: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        for entryId in group.memberEntryIds {
            guard let parsed = ModelGroup.parseEntryId(entryId),
                  let prov = providers.first(where: { $0.id == parsed.providerID }),
                  let model = prov.models.first(where: { $0.id == parsed.modelID }),
                  !parsed.modelID.isEmpty else {
                continue
            }
            guard model.modality?.contains(.imageInput) == true else {
                continue
            }
            result.append((prov, parsed.modelID, entryId))
        }
        return result
    }

    func voiceInputCandidates(
        for group: ModelGroup,
        providers: [ProviderConfiguration],
        sessionSeed: Int = 0
    ) -> [(provider: ProviderConfiguration, modelID: String, entryId: String)] {
        var result: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        for entryId in group.memberEntryIds {
            guard let parsed = ModelGroup.parseEntryId(entryId),
                  let prov = providers.first(where: { $0.id == parsed.providerID }),
                  prov.authenticationMode == .none || prov.hasStoredSecret,
                  let model = prov.models.first(where: { $0.id == parsed.modelID }),
                  !parsed.modelID.isEmpty else {
                continue
            }
            guard isDedicatedASR(model) else {
                continue
            }
            result.append((prov, parsed.modelID, entryId))
        }
        guard !result.isEmpty else { return [] }

        switch group.strategy {
        case .fallback:
            return result
        case .loadBalance:
            if result.count <= 1 { return result }
            let startIndex = abs(sessionSeed) % result.count
            return Array(result[startIndex...] + result[..<startIndex])
        }
    }

    func voiceOutputCandidates(
        for group: ModelGroup,
        providers: [ProviderConfiguration],
        sessionSeed: Int = 0
    ) -> [(provider: ProviderConfiguration, modelID: String, entryId: String)] {
        var result: [(provider: ProviderConfiguration, modelID: String, entryId: String)] = []
        for entryId in group.memberEntryIds {
            let taskEval = Self.evaluateMemberTaskEligibility(
                entryId: entryId,
                task: .voiceOutputTTS,
                providers: providers
            )
            guard taskEval.readiness.isReady,
                  let prov = taskEval.provider,
                  let model = taskEval.model else {
                continue
            }
            result.append((prov, model.id, entryId))
        }
        guard !result.isEmpty else { return [] }

        switch group.strategy {
        case .fallback:
            return result
        case .loadBalance:
            if result.count <= 1 { return result }
            let startIndex = abs(sessionSeed) % result.count
            return Array(result[startIndex...] + result[..<startIndex])
        }
    }

    func resolveInitial(
        for group: ModelGroup,
        sessionId: String,
        requireImageInput: Bool = false,
        providers: [ProviderConfiguration]
    ) -> (provider: ProviderConfiguration, modelID: String, entryId: String)? {
        let available = availableEntries(for: group, requireImageInput: requireImageInput, providers: providers)
        guard !available.isEmpty else { return nil }

        switch group.strategy {
        case .fallback:
            return available.first
        case .loadBalance:
            let idx = abs(sessionId.hashValue) % available.count
            return available[idx]
        }
    }

    func nextFallback(
        for group: ModelGroup,
        currentEntryId: String,
        triedEntryIds: Set<String>,
        requireImageInput: Bool = false,
        providers: [ProviderConfiguration]
    ) -> (provider: ProviderConfiguration, modelID: String, entryId: String)? {
        let available = availableEntries(for: group, requireImageInput: requireImageInput, providers: providers)
        guard !available.isEmpty else { return nil }

        if let currentIdx = available.firstIndex(where: { $0.entryId == currentEntryId }) {
            // Check remaining entries after current
            let remaining = available[(currentIdx + 1)...]
            if let next = remaining.first(where: { !triedEntryIds.contains($0.entryId) }) {
                return next
            }
            // Wrap around to entries before current
            let before = available[..<currentIdx]
            if let wrapped = before.first(where: { !triedEntryIds.contains($0.entryId) }) {
                return wrapped
            }
            return nil
        }

        // If current not in available list, return first untried
        return available.first(where: { !triedEntryIds.contains($0.entryId) })
    }

    func unavailableMemberReasons(
        for group: ModelGroup,
        requireImageInput: Bool = false,
        providers: [ProviderConfiguration]
    ) -> [(name: String, reason: String)] {
        var reasons: [(name: String, reason: String)] = []
        for entryId in group.memberEntryIds {
            let eval = Self.evaluateMemberEligibility(entryId: entryId, providers: providers, requireImageInput: requireImageInput)
            if !eval.isChatEligible {
                let name: String
                let reason: String
                if eval.parsedModelId == nil {
                    name = "Unknown (\(entryId))"
                    reason = "Invalid entry identifier"
                } else if eval.provider == nil {
                    name = eval.parsedModelId!
                    reason = "Provider not found"
                } else if eval.model == nil {
                    name = "\(eval.providerName) / \(eval.parsedModelId!)"
                    reason = "Model not supported by provider"
                } else if eval.unavailableReason == "API Key missing" {
                    name = "\(eval.providerName) / \(eval.parsedModelId!)"
                    reason = "Missing API Key"
                } else {
                    name = "\(eval.providerName) / \(eval.parsedModelId!)"
                    reason = eval.unavailableReason ?? "Unavailable"
                }
                reasons.append((name, reason))
            }
        }
        return reasons
    }

    func resolveModel(
        for groupId: String,
        providers: [ProviderConfiguration],
        sessionId: String = UUID().uuidString
    ) -> (provider: ProviderConfiguration, modelID: String)? {
        guard let grp = group(for: groupId) else { return nil }
        guard let resolved = resolveInitial(for: grp, sessionId: sessionId, providers: providers) else { return nil }
        return (resolved.provider, resolved.modelID)
    }

    func primaryModel(providers: [ProviderConfiguration]) -> (provider: ProviderConfiguration, modelID: String)? {
        if let primaryID = defaultPrimaryGroupId {
            return resolveModel(for: primaryID, providers: providers)
        }
        return nil
    }

    func subModel(providers: [ProviderConfiguration]) -> (provider: ProviderConfiguration, modelID: String)? {
        if let subID = defaultSubGroupId {
            return resolveModel(for: subID, providers: providers)
        }
        return nil
    }

    struct MemberDisplayInfo: Equatable, Sendable {
        var providerName: String
        var modelName: String
        var isAvailable: Bool
        var unavailableReason: String?

        var isValid: Bool { isAvailable }
    }

    func resolveMemberDisplay(entryId: String, providers: [ProviderConfiguration]) -> MemberDisplayInfo {
        let eval = Self.evaluateMemberEligibility(entryId: entryId, providers: providers, requireImageInput: false)
        return MemberDisplayInfo(
            providerName: eval.providerName,
            modelName: eval.modelDisplayName,
            isAvailable: eval.isChatEligible,
            unavailableReason: eval.unavailableReason
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let file = try JSONDecoder().decode(ModelGroupConfigFile.self, from: data)
            self.groups = file.groups
            self.defaultPrimaryGroupId = file.defaultPrimaryGroupId
            self.defaultSubGroupId = file.defaultSubGroupId
            self.voiceInputGroupId = file.voiceInputGroupId
            self.voiceOutputGroupId = file.voiceOutputGroupId
            self.visionGroupId = file.visionGroupId
            self.agentLoopModelEntryIds = file.agentLoopModelEntryIds
            self.agentLoopGroupIds = file.agentLoopGroupIds
        } catch {
            logs.error("ModelGroup", "Failed to load model groups configuration: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let file = ModelGroupConfigFile(
            groups: groups,
            defaultPrimaryGroupId: defaultPrimaryGroupId,
            defaultSubGroupId: defaultSubGroupId,
            voiceInputGroupId: voiceInputGroupId,
            voiceOutputGroupId: voiceOutputGroupId,
            visionGroupId: visionGroupId,
            agentLoopModelEntryIds: agentLoopModelEntryIds,
            agentLoopGroupIds: agentLoopGroupIds
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            logs.error("ModelGroup", "Failed to persist model groups: \(error.localizedDescription)")
        }
    }
}
