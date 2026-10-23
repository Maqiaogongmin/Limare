import SwiftUI

struct ConversationSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage("limare.sidebar.conversations.expanded") private var isExpanded: Bool = true
    @State private var isShowingAll: Bool = false
    @State private var isAddHovered = false
    @FocusState private var isAddFocused: Bool

    private let maxInitialConversations = 8

    private var unpinnedConversations: [ConversationRecord] {
        appState.conversations.unpinnedStandaloneConversations
    }

    private var visibleConversations: [ConversationRecord] {
        if isShowingAll || unpinnedConversations.count <= maxInitialConversations {
            return unpinnedConversations
        }
        return Array(unpinnedConversations.prefix(maxInitialConversations))
    }

    var body: some View {
        Section {
            if isExpanded {
                if unpinnedConversations.isEmpty {
                    if appState.conversations.pinnedStandaloneConversations.isEmpty {
                        SidebarEmptyState(message: "No conversations")
                    }
                } else {
                    ForEach(visibleConversations) { conv in
                        ConversationRow(conversation: conv)
                    }

                    if unpinnedConversations.count > maxInitialConversations {
                        Button {
                            withAnimation(AppMotion.resolved(AppMotion.standard)) {
                                isShowingAll.toggle()
                            }
                        } label: {
                            HStack(spacing: AppSpacing.xxSmall) {
                                Image(systemName: isShowingAll ? "chevron.up" : "chevron.down")
                                    .font(AppTypography.interfaceCaption2)
                                Text(isShowingAll ? "Show Less" : "Show More (\(unpinnedConversations.count - maxInitialConversations))")
                                    .font(AppTypography.interfaceCaption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.secondary)
                            .padding(.vertical, AppSpacing.xxSmall)
                            .padding(.horizontal, AppSpacing.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            HStack(spacing: AppSpacing.xxSmall) {
                Button {
                    withAnimation(AppMotion.resolved(AppMotion.standard)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppTypography.interfaceCaption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 10)

                        Text("Conversations")
                            .font(AppTypography.interfaceCaption.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    appState.showChat(in: window)
                    appState.conversations.newConversation()
                } label: {
                    Image(systemName: "plus")
                        .font(AppTypography.interfaceCaption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: AppControlHeight.small, height: AppControlHeight.small)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.small)
                                .fill((isAddHovered || isAddFocused) ? Color.secondary.opacity(0.18) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isAddFocused)
                .onHover { isAddHovered = $0 }
                // The card above follows the current project; this one is always outside one.
                .help("New Conversation outside projects")
                .accessibilityLabel("New Conversation outside projects")
                .accessibilityIdentifier("chat.sidebar.newConversationPlus")
            }
            .padding(.top, AppSpacing.sidebarSectionGap - AppSpacing.small)
        }
    }
}
