import SwiftUI
import AppKit

/// A conversation's worktree: where it is, what it holds, and getting its work back into Local
/// (merge or patch) or removing it.
struct WorktreeDetailsView: View {
    @Environment(AppState.self) private var app
    @Environment(WindowSession.self) private var window
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    @State private var status: WorktreeStatus?
    @State private var merge: WorktreeMergeSummary?
    @State private var commitMessage = ""
    @State private var error: String?
    @State private var working = false
    @State private var confirmsMerge = false

    private var conversation: ConversationRecord? {
        app.conversations.conversations.first { $0.id == conversationID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Worktree").font(.title2.weight(.semibold))
            if let worktree = conversation?.worktree {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Folder") {
                            Text(worktree.workspace.path).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Branch", value: status?.branch ?? worktree.branch)
                        LabeledContent("Started from") { Text(verbatim: "\(worktree.baseName) · \(worktree.baseCommit.prefix(8))") }
                        if let status {
                            if !status.exists {
                                Text("The worktree folder is missing. Remove the worktree to keep working in the project folder.")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("\(status.changedPaths.count) uncommitted · \(status.untrackedPaths.count) new files · \(status.commitsSinceBase ?? 0) commits since the base")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let merge, status?.exists == true { mergeSection(merge, worktree: worktree) }
                        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions(worktree) }
                    VStack(alignment: .leading, spacing: 8) { actions(worktree) }
                }
            } else {
                Text("This conversation no longer has a worktree.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { dismiss() } }
            }
        }
        .padding(20)
        .frame(minWidth: 320, idealWidth: 520, minHeight: 240, idealHeight: 380)
        .task { await refresh() }
        .onChange(of: app.conversationRuns.activeRuns[conversationID]?.status) { _, status in
            if status?.isTerminal == true { Task { await refresh() } }
        }
        .confirmationDialog("Merge into Local?", isPresented: $confirmsMerge, titleVisibility: .visible) {
            Button("Merge") { performMerge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates a merge commit on Local's current branch. Nothing is pushed; the worktree and its branch stay.")
        }
    }

    @ViewBuilder
    private func mergeSection(_ merge: WorktreeMergeSummary, worktree: ConversationWorktree) -> some View {
        Divider()
        Text("Merge into Local").font(.headline)
        if merge.hasNothingToMerge {
            Text("Local already has everything in this worktree.").foregroundStyle(.secondary)
        } else {
            if let local = merge.localBranch {
                Text("\(merge.commitsToMerge) commits will be merged into \(local).").foregroundStyle(.secondary)
            } else {
                Text("Local isn't on a branch; check out a branch in Local to merge.").foregroundStyle(.orange)
            }
            if merge.uncommittedCount > 0 {
                Text("\(merge.uncommittedCount) uncommitted changes are committed first, with this message:").foregroundStyle(.secondary)
                TextField("Commit message", text: $commitMessage).textFieldStyle(.roundedBorder)
            }
            Button("Merge into Local…") { confirmsMerge = true }
                .disabled(working || merge.localBranch == nil
                          || (merge.uncommittedCount > 0 && commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    @ViewBuilder
    private func actions(_ worktree: ConversationWorktree) -> some View {
        Button("Review Changes") { window.reviewWorktree(); dismiss() }
            .disabled(status?.exists != true || window.conversationID != conversationID)
        Button("Export Patch…") { exportPatch() }.disabled(status?.exists != true || working)
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([worktree.workspace.url]) }
            .disabled(status?.exists != true)
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button("Remove Worktree…", role: .destructive) {
            dismiss()
            app.requestRemoveWorktree(conversationID, in: window)
        }
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
    }

    private func refresh() async {
        do {
            status = try await app.worktrees.status(conversationID: conversationID)
            merge = status?.exists == true ? try await app.worktrees.mergeSummary(conversationID: conversationID) : nil
            if commitMessage.isEmpty { commitMessage = conversation?.displayTitle ?? "" }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performMerge() {
        working = true
        Task {
            do {
                try await app.worktrees.merge(conversationID: conversationID, commitMessage: commitMessage)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
            working = false
        }
    }

    private func exportPatch() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(conversation?.worktree?.branch.split(separator: "/").last ?? "worktree").patch"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                working = true
                do {
                    try await app.worktrees.exportPatch(conversationID: conversationID).write(to: destination, options: .atomic)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                working = false
            }
        }
    }
}
