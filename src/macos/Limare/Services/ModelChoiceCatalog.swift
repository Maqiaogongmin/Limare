import Foundation

/// The models a conversation can use and the one a send would use now, as the composer offers
/// them. The Mac composer and Remote read the same answers from here; the choice itself stays
/// with ConversationStore (`modelSource`) and the catalog with ProviderStore and ModelGroupStore.
@MainActor
enum ModelChoiceCatalog {
    /// The model source a send would use: the conversation's own, then the default primary
    /// Model Group (if it still exists), then the selected provider's model.
    static func currentModelSource(
        conversation: ConversationRecord?,
        modelGroups: ModelGroupStore?,
        providers: ProviderStore
    ) -> ConversationModelSource? {
        if let source = conversation?.effectiveModelSource { return source }
        if let primaryID = modelGroups?.defaultPrimaryGroupId, modelGroups?.group(for: primaryID) != nil {
            return .group(groupID: primaryID)
        }
        if let provider = providers.selectedProvider, !provider.selectedModelID.isEmpty {
            return .direct(providerID: provider.id, modelID: provider.selectedModelID)
        }
        return nil
    }

    /// Model Groups that have at least one usable member.
    static func selectableGroups(modelGroups: ModelGroupStore, providers: [ProviderConfiguration]) -> [ModelGroup] {
        modelGroups.groups.filter { !modelGroups.availableEntries(for: $0, providers: providers).isEmpty }
    }

    /// Chat-eligible models, without hidden or vanished ones unless `current` is one of them.
    static func visibleModelEntries(providers: [ProviderConfiguration], current: ConversationModelSource?) -> [ModelPickerEntry] {
        providers.flatMap { provider in
            provider.models.compactMap { model in
                let entryID = ModelGroup.makeEntryId(providerID: provider.id, modelID: model.id)
                guard ModelGroupStore.evaluateMemberEligibility(entryId: entryID, providers: providers).isChatEligible else { return nil }
                if model.isHidden || model.discovery.isAbsent {
                    guard case .direct(let providerID, let modelID) = current, providerID == provider.id, modelID == model.id else { return nil }
                }
                return ModelPickerEntry(providerID: provider.id, providerName: provider.name, model: model)
            }
        }
    }

    /// The model's full name: the group's name, or "Provider / Model" (with its discovery badge).
    static func label(for source: ConversationModelSource?, modelGroups: ModelGroupStore?, providers: [ProviderConfiguration]) -> String {
        guard let source else { return "Select Model" }
        switch source {
        case .group(let groupID):
            return modelGroups?.group(for: groupID)?.name ?? "Group (\(groupID))"
        case .direct(let providerID, let modelID):
            guard let provider = providers.first(where: { $0.id == providerID }) else { return modelID }
            if let model = provider.models.first(where: { $0.id == modelID }) {
                return "\(provider.name) / \(model.displayName)" + (model.discovery.badge.map { " · \($0)" } ?? "")
            }
            return "\(provider.name) / \(modelID)"
        }
    }

    /// The short name the composer button shows: a direct model without its provider.
    static func shortLabel(for source: ConversationModelSource?, modelGroups: ModelGroupStore?, providers: [ProviderConfiguration]) -> String {
        guard case .direct(let providerID, let modelID) = source else { return label(for: source, modelGroups: modelGroups, providers: providers) }
        return providers.first(where: { $0.id == providerID })?.models.first(where: { $0.id == modelID })?.displayName ?? modelID
    }

    /// Whether `source` is one the composer offers (for choices made somewhere other than its menu).
    static func offers(_ source: ConversationModelSource, modelGroups: ModelGroupStore, providers: [ProviderConfiguration]) -> Bool {
        switch source {
        case .group(let groupID):
            selectableGroups(modelGroups: modelGroups, providers: providers).contains { $0.id == groupID }
        case .direct(let providerID, let modelID):
            visibleModelEntries(providers: providers, current: nil).contains { $0.providerID == providerID && $0.model.id == modelID }
        }
    }
}
