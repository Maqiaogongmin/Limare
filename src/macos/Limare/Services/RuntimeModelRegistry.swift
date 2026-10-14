import Foundation

struct RuntimeModelEntry: Sendable, Equatable {
    let entryID: String
    let provider: ProviderConfiguration
    let model: ProviderModel

    var availableActions: [String] {
        var actions: [String] = []
        if RuntimeModelRegistry.isTextCallable(model) {
            actions.append("run")
        }
        if RuntimeModelRegistry.isImageGeneratable(model) {
            actions.append("generate_image")
        }
        return actions
    }

    var runtime: String {
        if RuntimeModelRegistry.isTextCallable(model) {
            return "text"
        } else if RuntimeModelRegistry.isImageGeneratable(model) {
            return "image_generation"
        } else {
            return "unsupported_in_current_runtime"
        }
    }

    var modalityNames: [String] {
        guard let modality = model.modality else { return [] }
        let values: [(ModelModality, String)] = [
            (.textInput, "text_input"), (.textOutput, "text_output"),
            (.imageInput, "image_input"), (.pdfInput, "pdf_input"),
            (.audioInput, "audio_input"), (.videoInput, "video_input"),
            (.imageOutput, "image_output"), (.audioOutput, "audio_output"),
            (.videoOutput, "video_output"),
        ]
        return values.compactMap { modality.contains($0.0) ? $0.1 : nil }
    }

    var publicObject: [String: Any] {
        var result: [String: Any] = [
            "entry_id": entryID,
            "provider": provider.name,
            "model_id": model.id,
            "display_name": model.displayName,
            "modalities": modalityNames,
            "runtime": runtime,
            "available_actions": availableActions,
        ]
        result["availability"] = model.discovery.availability
        if let contextWindow = model.contextWindow { result["context_window"] = contextWindow }
        if let maxOutputTokens = model.maxOutputTokens { result["max_output_tokens"] = maxOutputTokens }
        return result
    }
}

@MainActor
final class RuntimeModelRegistry {
    private let modelGroups: ModelGroupStore
    private let providers: ProviderStore

    init(modelGroups: ModelGroupStore, providers: ProviderStore) {
        self.modelGroups = modelGroups
        self.providers = providers
    }

    var hasConfiguredEntries: Bool {
        !modelGroups.agentLoopModelEntryIds.isEmpty || !modelGroups.agentLoopGroupIds.isEmpty
    }

    var configuredEntryIDs: [String] {
        var orderedIDs = modelGroups.agentLoopModelEntryIds
        for groupID in modelGroups.agentLoopGroupIds {
            guard let group = modelGroups.group(for: groupID) else { continue }
            orderedIDs.append(contentsOf: group.memberEntryIds)
        }
        return orderedIDs
    }

    public func isConfigured(entryID: String) -> Bool {
        configuredEntryIDs.contains(entryID)
    }

    var entries: [RuntimeModelEntry] {
        var seen = Set<String>()
        return configuredEntryIDs.compactMap { entryID in
            guard seen.insert(entryID).inserted,
                  let parsed = ModelGroup.parseEntryId(entryID),
                  let provider = providers.providers.first(where: { $0.id == parsed.providerID }),
                  let model = provider.models.first(where: { $0.id == parsed.modelID }) else { return nil }
            // Hidden affects new pickers, never an existing explicit binding.
            return RuntimeModelEntry(entryID: entryID, provider: provider, model: model)
        }
    }

    /// Derived runtime-exposure projection. Provider/model truth remains owned
    /// by their stores; this only combines an executable action with existing
    /// credential metadata required by the real `model_use` execution path.
    var executableEntries: [RuntimeModelEntry] {
        entries.filter { entry in
            guard !entry.model.discovery.isRemoved, !entry.availableActions.isEmpty else { return false }
            switch entry.provider.authenticationMode {
            case .none:
                return true
            case .bearer, .azureAPIKey, .oauth:
                return providers.hasStoredAPIKey(providerID: entry.provider.id)
            }
        }
    }

    var hasExecutableEntry: Bool { !executableEntries.isEmpty }

    func search(_ query: String) -> [RuntimeModelEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return entries.filter {
            $0.model.displayName.localizedCaseInsensitiveContains(needle)
                || $0.model.id.localizedCaseInsensitiveContains(needle)
                || $0.provider.name.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Runtime tool projection only. Settings and validation continue to use
    /// `entries` / `search`, which intentionally retain approved bindings
    /// even while their provider credential is unavailable.
    func searchExecutable(_ query: String) -> [RuntimeModelEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return executableEntries.filter {
            $0.model.displayName.localizedCaseInsensitiveContains(needle)
                || $0.model.id.localizedCaseInsensitiveContains(needle)
                || $0.provider.name.localizedCaseInsensitiveContains(needle)
        }
    }

    func resolveAllowed(entryID: String) -> RuntimeModelEntry? {
        entries.first { $0.entryID == entryID }
    }

    nonisolated static func isTextCallable(_ model: ProviderModel) -> Bool {
        guard let modality = model.modality else { return true }
        return modality.contains(.textInput) && modality.contains(.textOutput)
    }

    nonisolated static func isImageGeneratable(_ model: ProviderModel) -> Bool {
        guard let modality = model.modality else { return false }
        return modality.contains(.textInput) && modality.contains(.imageOutput)
    }

    public enum EntryReadiness: Equatable, Sendable {
        case executable
        case notExecutable(reason: String)

        public var isExecutable: Bool {
            if case .executable = self { return true }
            return false
        }

        public var unexecutableReason: String? {
            if case .notExecutable(let reason) = self {
                return reason
            }
            return nil
        }
    }

    public func executionStatus(for entryID: String) -> EntryReadiness {
        guard isConfigured(entryID: entryID) else {
            return .notExecutable(reason: "Not configured for Agent runtime")
        }
        guard let parsed = ModelGroup.parseEntryId(entryID),
              !parsed.modelID.isEmpty else {
            return .notExecutable(reason: "Invalid entry ID")
        }
        guard let provider = providers.providers.first(where: { $0.id == parsed.providerID }) else {
            return .notExecutable(reason: "Provider missing")
        }
        guard let model = provider.models.first(where: { $0.id == parsed.modelID }) else {
            return .notExecutable(reason: "Model missing")
        }
        let needsKey = provider.authenticationMode != .none && !providers.hasStoredAPIKey(providerID: provider.id)
        if needsKey {
            return .notExecutable(reason: "Missing credential")
        }
        let entry = RuntimeModelEntry(entryID: entryID, provider: provider, model: model)
        if entry.availableActions.isEmpty {
            return .notExecutable(reason: "No supported runtime action")
        }
        return .executable
    }
}
