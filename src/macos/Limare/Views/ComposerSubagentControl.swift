import SwiftUI

/// Conversation-scoped Subagent policy. The Model Group decides which helper model a Child uses;
/// this control decides whether the current conversation may admit new delegated Children.
/// Turning it off never cancels Children that already exist.
struct ComposerSubagentControl: View {
    @Environment(AppState.self) private var appState

    private var conversation: ConversationRecord? {
        appState.conversations.activeConversation
    }

    var body: some View {
        if let conversation, !conversation.isNativeDelegationChild {
            let enabled = conversation.subagentEnabled
            Button {
                appState.conversations.setSubagentEnabled(id: conversation.id, enabled: !enabled)
            } label: {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: enabled ? .semibold : .regular))
                    .foregroundStyle(enabled ? Color.accentColor : AppColors.textMuted)
                    .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                    .background(enabled ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.composer.subagent")
            .accessibilityLabel("Subagent")
            .accessibilityValue(enabled ? "enabled" : "disabled")
            .help(enabled
                ? "Subagent is enabled for this conversation. Limare may delegate work to the configured helper model, which can use additional tokens."
                : "Subagent is disabled for this conversation. Limare will handle tasks without creating delegated child agents.")
        }
    }
}
