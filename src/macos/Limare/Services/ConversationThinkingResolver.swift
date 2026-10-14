import Foundation

struct ComposerThinkingPresentationState: Equatable, Sendable {
    let isVisible: Bool
    let isEnabled: Bool
    let requestedOverride: ThinkingLevel?
    let effectiveLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let groupDefaultLevel: ThinkingLevel?
    let displayLabel: String
    let menuGroupDefaultLabel: String?
    let isGroupSource: Bool

    init(
        isVisible: Bool,
        isEnabled: Bool,
        requestedOverride: ThinkingLevel?,
        effectiveLevel: ThinkingLevel,
        availableLevels: [ThinkingLevel],
        groupDefaultLevel: ThinkingLevel?,
        displayLabel: String,
        menuGroupDefaultLabel: String?,
        isGroupSource: Bool
    ) {
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.requestedOverride = requestedOverride
        self.effectiveLevel = effectiveLevel
        self.availableLevels = availableLevels
        self.groupDefaultLevel = groupDefaultLevel
        self.displayLabel = displayLabel
        self.menuGroupDefaultLabel = menuGroupDefaultLabel
        self.isGroupSource = isGroupSource
    }
}

enum ConversationThinkingResolver {

    // MARK: - Canonical Level Mapping

    static func canonicalLevels(for effortValues: [String]?) -> [ThinkingLevel] {
        guard let effortValues, !effortValues.isEmpty else {
            return [.off]
        }
        var levels: Set<ThinkingLevel> = [.off]
        for tier in effortValues {
            let lower = tier.lowercased()
            switch lower {
            case "none", "off", "disabled":
                levels.insert(.off)
            case "minimal":
                levels.insert(.minimal)
            case "low":
                levels.insert(.low)
            case "medium":
                levels.insert(.medium)
            case "high":
                levels.insert(.high)
            case "xhigh":
                levels.insert(.xhigh)
            case "max":
                levels.insert(.max)
            default:
                break
            }
        }
        return ThinkingLevel.selectableCases.filter { levels.contains($0) }
    }

    static func clampToAvailable(_ level: ThinkingLevel, available: [ThinkingLevel]) -> ThinkingLevel {
        guard !available.isEmpty else { return .off }
        if available.contains(level) { return level }
        let sorted = available.filter { $0 != .off && $0 != .ultra }.sorted()
        guard level != .off else { return .off }
        if let lower = sorted.last(where: { $0 <= level }) {
            return lower
        }
        return sorted.first ?? .off
    }

    // MARK: - Effective Level Resolution (Runtime & UI)

    @MainActor
    static func resolveEffectiveLevel(
        override: ThinkingLevel?,
        modelSource: ConversationModelSource?,
        providers: [ProviderConfiguration],
        modelGroups: ModelGroupStore?
    ) -> ThinkingLevel {
        guard let modelSource else {
            return override ?? .off
        }

        switch modelSource {
        case .direct:
            // Preserve canonical intent; candidate-specific projection resolves the actual control.
            return override ?? .off

        case .group(let groupID):
            guard let group = modelGroups?.group(for: groupID) else {
                return override ?? .off
            }

            if let requested = override {
                return requested
            }

            return group.defaultThinkingLevel ?? .off
        }
    }

    /// A direct model without executable tiers hides the menu, unless the conversation still requests a
    /// positive level: then the composer states it runs at the model default and offers that choice.
    private static func revealingUnexecutableOverride(_ state: ComposerThinkingPresentationState,
                                                      offLabel: String) -> ComposerThinkingPresentationState {
        guard !state.isVisible, let requested = state.requestedOverride, requested != .off else { return state }
        return ComposerThinkingPresentationState(isVisible: true, isEnabled: true, requestedOverride: requested,
            effectiveLevel: .off, availableLevels: [.off], groupDefaultLevel: nil,
            displayLabel: "\(requested.displayName) → \(offLabel)", menuGroupDefaultLabel: nil, isGroupSource: false)
    }

    // MARK: - Presentation State Resolution (Composer UI)

    @MainActor
    static func resolvePresentationState(
        conversation: ConversationRecord?,
        modelSource: ConversationModelSource?,
        providers: [ProviderConfiguration],
        modelGroups: ModelGroupStore?
    ) -> ComposerThinkingPresentationState {
        let requestedOverride = conversation?.thinkingLevelOverride

        guard let source = modelSource ?? conversation?.effectiveModelSource else {
            let effective = requestedOverride ?? .off
            return ComposerThinkingPresentationState(
                isVisible: false,
                isEnabled: false,
                requestedOverride: requestedOverride,
                effectiveLevel: effective,
                availableLevels: [],
                groupDefaultLevel: nil,
                displayLabel: effective.displayName,
                menuGroupDefaultLabel: nil,
                isGroupSource: false
            )
        }

        switch source {
        case .direct(let providerID, let modelID):
            guard let provider = providers.first(where: { $0.id == providerID }),
                  let model = provider.models.first(where: { $0.id == modelID }) else {
                let effective = requestedOverride ?? .off
                return ComposerThinkingPresentationState(
                    isVisible: false,
                    isEnabled: false,
                    requestedOverride: requestedOverride,
                    effectiveLevel: effective,
                    availableLevels: [],
                    groupDefaultLevel: nil,
                    displayLabel: effective.displayName,
                    menuGroupDefaultLabel: nil,
                    isGroupSource: false
                )
            }

            // Confirmed non-reasoning model
            if model.supportsReasoning == false {
                return revealingUnexecutableOverride(ComposerThinkingPresentationState(
                    isVisible: false,
                    isEnabled: false,
                    requestedOverride: requestedOverride,
                    effectiveLevel: .off,
                    availableLevels: [],
                    groupDefaultLevel: nil,
                    displayLabel: ThinkingLevel.off.displayName,
                    menuGroupDefaultLabel: nil,
                    isGroupSource: false
                ), offLabel: ProviderThinkingResolution.offLabel(model: model, provider: provider))
            }

            // Unknown capability (supportsReasoning == nil): safe policy per Section 21
            // Do not claim "not supported", but do not expose manual tiers unless proved
            if model.supportsReasoning == nil {
                let effective = requestedOverride ?? .off
                return revealingUnexecutableOverride(ComposerThinkingPresentationState(
                    isVisible: false,
                    isEnabled: false,
                    requestedOverride: requestedOverride,
                    effectiveLevel: effective,
                    availableLevels: [],
                    groupDefaultLevel: nil,
                    displayLabel: effective.displayName,
                    menuGroupDefaultLabel: nil,
                    isGroupSource: false
                ), offLabel: ProviderThinkingResolution.offLabel(model: model, provider: provider))
            }

            // Models with no adjustable tiers expose no fictional strength selector.
            if model.declaresNoEffortTiers == true && (model.reasoningEffortValues?.isEmpty ?? true) {
                return revealingUnexecutableOverride(ComposerThinkingPresentationState(isVisible: false, isEnabled: false,
                    requestedOverride: requestedOverride, effectiveLevel: .off, availableLevels: [],
                    groupDefaultLevel: nil, displayLabel: "Model Default", menuGroupDefaultLabel: nil, isGroupSource: false), offLabel: ProviderThinkingResolution.offLabel(model: model, provider: provider))
            }
            let available = ProviderThinkingResolution.supportedLevels(for: model, provider: provider)
            let effective = requestedOverride.map { clampToAvailable($0, available: available) } ?? .off

            return revealingUnexecutableOverride(ComposerThinkingPresentationState(
                isVisible: available.contains(where: { $0 != .off }),
                isEnabled: available.contains(where: { $0 != .off }),
                requestedOverride: requestedOverride,
                effectiveLevel: effective,
                availableLevels: available,
                groupDefaultLevel: nil,
                displayLabel: effective == .off ? ProviderThinkingResolution.offLabel(model: model, provider: provider) : (requestedOverride == nil || effective == requestedOverride ? effective.displayName : "\(requestedOverride!.displayName) → \(effective.displayName)"),
                menuGroupDefaultLabel: nil,
                isGroupSource: false
            ), offLabel: ProviderThinkingResolution.offLabel(model: model, provider: provider))

        case .group(let groupID):
            guard let group = modelGroups?.group(for: groupID) else {
                let effective = requestedOverride ?? .off
                return ComposerThinkingPresentationState(
                    isVisible: false,
                    isEnabled: false,
                    requestedOverride: requestedOverride,
                    effectiveLevel: effective,
                    availableLevels: [],
                    groupDefaultLevel: nil,
                    displayLabel: effective.displayName,
                    menuGroupDefaultLabel: nil,
                    isGroupSource: true
                )
            }

            // Check member capabilities
            let members: [ProviderModel] = group.memberEntryIds.compactMap { entryId in
                guard let parsed = ModelGroup.parseEntryId(entryId),
                      let prov = providers.first(where: { $0.id == parsed.providerID }),
                      let m = prov.models.first(where: { $0.id == parsed.modelID }) else {
                    return nil
                }
                return m
            }

            let allExplicitlyNonReasoning = !members.isEmpty && members.allSatisfy { $0.supportsReasoning == false }
            if allExplicitlyNonReasoning {
                return ComposerThinkingPresentationState(
                    isVisible: false,
                    isEnabled: false,
                    requestedOverride: requestedOverride,
                    effectiveLevel: .off,
                    availableLevels: [],
                    groupDefaultLevel: group.defaultThinkingLevel,
                    displayLabel: ThinkingLevel.off.displayName,
                    menuGroupDefaultLabel: nil,
                    isGroupSource: true
                )
            }

            let effective = requestedOverride ?? group.defaultThinkingLevel ?? .off
            let defaultLabel = group.defaultThinkingLevel != nil
                ? "Use Group Default (\(group.defaultThinkingLevel!.displayName))"
                : "Use Group Default (Off)"

            return ComposerThinkingPresentationState(
                isVisible: true,
                isEnabled: true,
                requestedOverride: requestedOverride,
                effectiveLevel: effective,
                availableLevels: Array(Set(group.memberEntryIds.flatMap { entry -> [ThinkingLevel] in
                    guard let parsed = ModelGroup.parseEntryId(entry),
                          let provider = providers.first(where: { $0.id == parsed.providerID }),
                          let model = provider.models.first(where: { $0.id == parsed.modelID }) else { return [] }
                    return ProviderThinkingResolution.supportedLevels(for: model, provider: provider)
                })).sorted(),
                groupDefaultLevel: group.defaultThinkingLevel,
                displayLabel: effective.displayName,
                menuGroupDefaultLabel: defaultLabel,
                isGroupSource: true
            )
        }
    }
}
