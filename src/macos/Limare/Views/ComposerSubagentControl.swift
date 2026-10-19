import SwiftUI

/// Conversation-scoped Subagent policy. The Model Group decides which helper model a Child uses;
/// this control decides whether the current conversation may admit new delegated Children.
/// Turning it off never cancels Children that already exist.
struct ComposerSubagentControl: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    private var conversation: ConversationRecord? {
        window.conversation
    }

    var body: some View {
        if let conversation, !conversation.isNativeDelegationChild {
            let enabled = conversation.subagentEnabled
            Button {
                appState.conversations.setSubagentEnabled(id: conversation.id, enabled: !enabled)
            } label: {
                // On is the one state shown: the accent, on a faint accent fill.
                Image(systemName: "person.2")
                    .fontWeight(enabled ? .semibold : .regular)
                    .foregroundStyle(enabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.foreground))
                    .frame(width: AppControlHeight.composerButton, height: AppControlHeight.composerButton)
                    .background(
                        RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                            .fill(enabled ? Color.accentColor.opacity(0.10) : .clear)
                    )
            }
            .buttonStyle(GhostIconButtonStyle())
            .accessibilityIdentifier("chat.composer.subagent")
            .accessibilityLabel("Subagent")
            .accessibilityValue(enabled ? "enabled" : "disabled")
            .help(enabled
                ? "Subagent is enabled for this conversation. Limare may delegate work to the configured helper model, which can use additional tokens."
                : "Subagent is disabled for this conversation. Limare will handle tasks without creating delegated child agents.")
        }
    }
}
