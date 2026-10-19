import SwiftUI

struct ComposerThinkingControl: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    /// A narrow composer: the icon alone, so the model's name keeps the room. Decided up front;
    /// left to the row, the room reserved for the level went to the spacer instead of the model.
    var isCompact = false

    private var currentModelSource: ConversationModelSource? {
        ModelChoiceCatalog.currentModelSource(conversation: window.conversation,
                                              modelGroups: appState.modelGroups, providers: appState.providers)
    }

    private var thinkingState: ComposerThinkingPresentationState {
        ConversationThinkingResolver.resolvePresentationState(
            conversation: window.conversation,
            modelSource: currentModelSource,
            providers: appState.providers.providers,
            modelGroups: appState.modelGroups
        )
    }

    private var offLabel: String {
        guard case .direct(let providerID, let modelID) = currentModelSource,
              let provider = appState.providers.providers.first(where: { $0.id == providerID }) else { return "Model Default" }
        return ProviderThinkingResolution.offLabel(model: provider.models.first(where: { $0.id == modelID }), provider: provider)
    }

    var body: some View {
        if thinkingState.isVisible {
            // In a narrow composer the level's name gives way first, so the model's name can stay.
            menu(showsLevel: !isCompact)
                .disabled(window.chat.isStreaming)
                .help("Reasoning & Thinking intensity: \(thinkingState.displayLabel)")
        }
    }

    private func menu(showsLevel: Bool) -> some View {
        Menu {
            if thinkingState.isGroupSource {
                if let defaultLabel = thinkingState.menuGroupDefaultLabel {
                    // Toggles draw the menu's own checkmark on the current level.
                    Toggle(defaultLabel, isOn: Binding(
                        get: { thinkingState.requestedOverride == nil },
                        set: { _ in selectLevel(nil) }
                    ))

                    Divider()
                }

                ForEach(thinkingState.availableLevels, id: \.self) { level in
                    Toggle(level.displayName, isOn: Binding(
                        get: { thinkingState.requestedOverride == level },
                        set: { _ in selectLevel(level) }
                    ))
                }
            } else {
                Toggle(offLabel, isOn: Binding(
                    get: { thinkingState.requestedOverride == .off || (thinkingState.requestedOverride == nil && thinkingState.effectiveLevel == .off) },
                    set: { _ in selectLevel(.off) }
                ))

                ForEach(thinkingState.availableLevels.filter { $0 != .off }, id: \.self) { level in
                    Toggle(level.displayName, isOn: Binding(
                        get: { thinkingState.requestedOverride == level },
                        set: { _ in selectLevel(level) }
                    ))
                }
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))

                if showsLevel {
                    Text(thinkingState.displayLabel)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .composerPill()
        }
        // A plain button style keeps the label's own quiet colour, which the borderless
        // menu style overrides.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Thinking: \(thinkingState.displayLabel)")
    }

    private func selectLevel(_ level: ThinkingLevel?) {
        if let activeID = window.conversationID {
            appState.conversations.setConversationThinkingLevelOverride(id: activeID, level: level)
        }
    }
}
