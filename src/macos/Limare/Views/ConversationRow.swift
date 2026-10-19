import SwiftUI

struct ConversationRow: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @Environment(\.openWindow) private var openWindow
    let conversation: ConversationRecord
    var isIndented: Bool = false

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false

    private var isSelected: Bool {
        window.conversationID == conversation.id
    }

    private var iconForegroundStyle: Color {
        if isSelected {
            return Color.primary.opacity(0.85)
        }
        if conversation.isPinned {
            return Color.accentColor.opacity(0.85)
        }
        return Color.secondary
    }

    var body: some View {
        SidebarRowContainer(
            isSelected: isSelected,
            isIndented: isIndented,
            onSelect: {
                appState.focus(window)
                appState.conversations.selectConversation(id: conversation.id)
            }
        ) {
            Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                .font(AppTypography.interfaceSubheadline)
                .foregroundStyle(iconForegroundStyle)

            Text(conversation.title)
                .font(AppTypography.interfaceSubheadline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))

            if appState.conversationsAwaitingApproval.contains(conversation.id) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Waiting for your approval")
            } else if appState.conversationRuns.hasInterruptedRun(for: conversation.id) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if appState.conversationRuns.isPaused(conversationID: conversation.id) {
                Image(systemName: "pause.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if appState.conversationRuns.isActive(conversationID: conversation.id) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
        } actions: {
            SidebarHoverIconButton(
                systemImage: conversation.isPinned ? "pin.slash" : "pin",
                tooltip: conversation.isPinned ? "Unpin Conversation" : "Pin Conversation"
            ) {
                appState.conversations.toggleConversationPinned(id: conversation.id)
            }

            SidebarHoverIconButton(
                systemImage: "archivebox",
                tooltip: "Archive Conversation"
            ) {
                appState.conversations.archiveConversation(id: conversation.id)
            }

            Menu {
                conversationMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: AppControlHeight.small, height: AppControlHeight.small)
            .help("Conversation Actions")
        }
        .contextMenu {
            conversationMenuItems
        }
        .sheet(isPresented: $isRenaming) {
            SidebarRenameSheet(
                title: "Rename Conversation",
                placeholder: "Conversation Title",
                text: $renameText,
                onSave: { newTitle in
                    appState.conversations.renameConversation(id: conversation.id, title: newTitle)
                    isRenaming = false
                },
                onCancel: {
                    isRenaming = false
                }
            )
        }
        .confirmationDialog(
            "Delete Conversation?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Conversation", role: .destructive) {
                appState.conversations.deleteConversation(id: conversation.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to permanently delete '\(conversation.title)'? This action cannot be undone.")
        }
    }

    @ViewBuilder
    private var conversationMenuItems: some View {
        Button {
            appState.prepareWindow(for: conversation.id)
            openWindow(id: WindowSession.sceneID)
        } label: {
            Label("Open in New Window", systemImage: "macwindow.badge.plus")
        }

        Divider()

        Button {
            renameText = conversation.title
            isRenaming = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            appState.conversations.toggleConversationPinned(id: conversation.id)
        } label: {
            Label(
                conversation.isPinned ? "Unpin Conversation" : "Pin Conversation",
                systemImage: conversation.isPinned ? "pin.slash" : "pin"
            )
        }

        Menu("Move to Project") {
            Button("None (Standalone)") {
                appState.conversations.moveConversation(id: conversation.id, toProjectID: nil)
            }
            if !appState.conversations.projects.isEmpty {
                Divider()
                ForEach(appState.conversations.projects) { proj in
                    Button(proj.name) {
                        appState.conversations.moveConversation(id: conversation.id, toProjectID: proj.id)
                    }
                }
            }
        }

        Button {
            appState.conversations.archiveConversation(id: conversation.id)
        } label: {
            Label("Archive Conversation", systemImage: "archivebox")
        }

        Button {
            appState.focus(window)
            appState.conversations.selectConversation(id: conversation.id)
            window.chat.compactConversation()
        } label: {
            Label("Compact Conversation", systemImage: "arrow.down.right.and.arrow.up.left")
        }
        .disabled(!appState.conversationRuns.canStartRun(conversationID: conversation.id))
        .help("Summarize the earlier conversation so each request sends less (/compact)")

        Divider()

        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("Delete Conversation…", systemImage: "trash")
        }
    }
}
