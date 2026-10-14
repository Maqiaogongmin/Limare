import SwiftUI

struct ArchivedConversationsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var conversationToDelete: ConversationRecord?
    @State private var isConfirmingDelete = false

    private var archivedList: [ConversationRecord] {
        appState.conversations.archivedConversations
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if archivedList.isEmpty {
                VStack(spacing: AppSpacing.medium) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Archived Conversations")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Conversations archived from the sidebar will appear here.\nYou can restore them to the sidebar at any time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppSpacing.xLarge)
            } else {
                List {
                    ForEach(archivedList) { conv in
                        HStack(spacing: AppSpacing.small) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                                Text(conv.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if let date = conv.archivedAt {
                                    Text("Archived \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer(minLength: AppSpacing.small)

                            Button {
                                appState.conversations.restoreConversation(id: conv.id)
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Restore to Sidebar")

                            Button(role: .destructive) {
                                conversationToDelete = conv
                                isConfirmingDelete = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Delete permanently")
                        }
                        .padding(.vertical, AppSpacing.xxSmall)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 340)
        .confirmationDialog(
            "Delete Conversation permanently?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let conv = conversationToDelete {
                    appState.conversations.deleteConversation(id: conv.id)
                }
                conversationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        } message: {
            Text("This action cannot be undone. All messages in '\(conversationToDelete?.title ?? "this conversation")' will be permanently deleted.")
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Text("Archived Conversations")
                .font(.headline)

            if !archivedList.isEmpty {
                Text("\(archivedList.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(AppSpacing.medium)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(AppSpacing.medium)
    }
}
