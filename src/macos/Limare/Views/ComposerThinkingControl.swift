import SwiftUI

struct ComposerThinkingControl: View {
    @Environment(AppState.self) private var appState

    private var currentModelSource: ConversationModelSource? {
        ModelChoiceCatalog.currentModelSource(conversation: appState.conversations.activeConversation,
                                              modelGroups: appState.modelGroups, providers: appState.providers)
    }

    private var thinkingState: ComposerThinkingPresentationState {
        ConversationThinkingResolver.resolvePresentationState(
            conversation: appState.conversations.activeConversation,
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
            Menu {
                if thinkingState.isGroupSource {
                    if let defaultLabel = thinkingState.menuGroupDefaultLabel {
                        Button {
                            selectLevel(nil)
                        } label: {
                            if thinkingState.requestedOverride == nil {
                                Label(defaultLabel, systemImage: "checkmark")
                            } else {
                                Text(defaultLabel)
                            }
                        }

                        Divider()
                    }

                    ForEach(thinkingState.availableLevels, id: \.self) { level in
                        Button {
                            selectLevel(level)
                        } label: {
                            let isSelected = thinkingState.requestedOverride == level
                            if isSelected {
                                Label(level.displayName, systemImage: "checkmark")
                            } else {
                                Text(level.displayName)
                            }
                        }
                    }
                } else {
                    Button {
                        selectLevel(.off)
                    } label: {
                        let isSelected = thinkingState.requestedOverride == .off || (thinkingState.requestedOverride == nil && thinkingState.effectiveLevel == .off)
                        if isSelected {
                            Label(offLabel, systemImage: "checkmark")
                        } else {
                            Text(offLabel)
                        }
                    }

                    ForEach(thinkingState.availableLevels.filter { $0 != .off }, id: \.self) { level in
                        Button {
                            selectLevel(level)
                        } label: {
                            let isSelected = thinkingState.requestedOverride == level
                            if isSelected {
                                Label(level.displayName, systemImage: "checkmark")
                            } else {
                                Text(level.displayName)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: AppSpacing.xxSmall) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text(thinkingState.displayLabel)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.vertical, AppSpacing.xxSmall)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(appState.chat.isStreaming)
            .help("Reasoning & Thinking intensity")
        }
    }

    private func selectLevel(_ level: ThinkingLevel?) {
        if let activeID = appState.conversations.activeConversationID {
            appState.conversations.setConversationThinkingLevelOverride(id: activeID, level: level)
        }
    }
}
