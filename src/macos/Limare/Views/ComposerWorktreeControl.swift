import SwiftUI

/// Asks before removing worktrees that hold work existing nowhere else.
struct WorktreeRemovalPrompt: Identifiable {
    let id = UUID()
    /// The conversations whose worktrees go; deleted too when `deletesConversations`.
    var conversationIDs: [UUID]
    /// How many of those worktrees hold uncommitted changes or new files.
    var unsavedCount: Int
    var deletesConversations: Bool
}

/// Where the conversation works. An empty conversation in a Git project can be set to start in a
/// new worktree (created when its first message is sent) from a chosen base branch; once it has
/// one, this shows the worktree's branch and opens its details.
struct ComposerWorktreeControl: View {
    @Environment(AppState.self) private var app
    @Environment(WindowSession.self) private var window
    @State private var branches: (current: String?, branches: [String]) = (nil, [])
    @State private var currentBranch: String?

    var body: some View {
        if let conversation = window.conversation, !conversation.isNativeDelegationChild {
            if let worktree = conversation.worktree {
                Button { window.worktreeDetails = conversation.id } label: {
                    label(currentBranch ?? worktree.branch, active: true)
                }
                .buttonStyle(GhostIconButtonStyle())
                .accessibilityLabel("Worktree details")
                .help("Show worktree details")
                .task(id: worktree.workspace.path) { currentBranch = await app.worktrees.currentBranch(conversationID: conversation.id) }
                .onChange(of: app.conversationRuns.activeRuns[conversation.id]?.status) { _, status in
                    if status?.isTerminal == true {
                        Task { currentBranch = await app.worktrees.currentBranch(conversationID: conversation.id) }
                    }
                }
            } else if app.worktrees.canOfferWorktree(for: conversation.id) {
                chooser(conversation.id)
            }
        }
    }

    private func chooser(_ id: UUID) -> some View {
        let pending = app.worktrees.pending[id]
        let creating = app.worktrees.operations[id] == .creating
        return Menu {
            Picker("Work in", selection: Binding(
                get: { pending != nil },
                set: { app.worktrees.setPending($0 ? .init() : nil, for: id) })) {
                Text("Local project folder").tag(false)
                Text("New worktree").tag(true)
            }
            .pickerStyle(.inline)
            if pending != nil {
                Picker("Base branch", selection: Binding(
                    get: { pending?.baseBranch ?? "" },
                    set: { app.worktrees.setPending(.init(baseBranch: $0.isEmpty ? nil : $0), for: id) })) {
                    Text(branches.current.map { String(localized: "Current branch (\($0))") } ?? String(localized: "Current commit")).tag("")
                    ForEach(branches.branches.filter { $0 != branches.current }, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
        } label: {
            if creating {
                HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Creating worktree…").font(.caption) }
            } else {
                label(pending == nil ? String(localized: "Local folder") : pending?.baseBranch.map { String(localized: "Worktree from \($0)") } ?? String(localized: "Worktree"),
                      active: pending != nil)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(creating)
        .accessibilityLabel("Where this conversation works")
        .help("Work in the project folder, or in a new Git worktree created when you send the first message")
        .task(id: id) { branches = await app.worktrees.localBranches(for: id) }
    }

    private func label(_ text: String, active: Bool) -> some View {
        Label(text, systemImage: "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .frame(height: AppControlHeight.composerButton)
    }
}
