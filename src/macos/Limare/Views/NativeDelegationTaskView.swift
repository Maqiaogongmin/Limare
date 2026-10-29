import SwiftUI

/// The subagent tasks of a conversation (or, inside a child conversation, its own task).
struct NativeDelegationTaskView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var collapsedConversations: Set<UUID> = []
    @State private var expandedFinished: Set<UUID> = []
    @State private var continuing: SubagentTask?
    @State private var deleting: SubagentTask?
    @State private var instruction = ""
    @State private var errorMessage: String?
    let conversationID: UUID

    var body: some View {
        let subagents = appState.subagents
        let childTask = subagents.store.task(childConversationID: conversationID)
        let tasks = childTask.map { [$0] } ?? subagents.store.tasks(for: conversationID)
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        if !collapsedConversations.insert(conversationID).inserted { collapsedConversations.remove(conversationID) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsedConversations.contains(conversationID) ? "chevron.right" : "chevron.down")
                            Label(childTask == nil ? "Subagents (\(tasks.count))" : "Subagent", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("native.delegation.toggle")
                    Spacer()
                    if let task = childTask {
                        Button("Back to Parent Conversation") {
                            appState.focus(window)
                            appState.conversations.selectConversation(id: task.parentConversationID)
                        }
                    }
                }
                if !collapsedConversations.contains(conversationID) {
                    // Finished tasks need nothing more; they stay reachable under a collapsed group.
                    let finished = childTask == nil ? tasks.filter { $0.status.isFinished } : []
                    ForEach(tasks.filter { task in !finished.contains { $0.id == task.id } }) { task in
                        row(task, isChild: childTask != nil)
                    }
                    if !finished.isEmpty {
                        Button {
                            if !expandedFinished.insert(conversationID).inserted { expandedFinished.remove(conversationID) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: expandedFinished.contains(conversationID) ? "chevron.down" : "chevron.right")
                                Text("Finished (\(finished.count))")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("native.delegation.finishedToggle")
                        if expandedFinished.contains(conversationID) {
                            ForEach(finished) { task in row(task, isChild: false) }
                        }
                    }
                    if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
                }
            }
            .controlSize(.small)
            .padding(12)
            .background(.quaternary.opacity(0.35))
            .accessibilityIdentifier("native.delegation.tasks")
            .alert("Continue Subtask", isPresented: Binding(get: { continuing != nil }, set: { if !$0 { continuing = nil } })) {
                TextField("Instruction for the subtask", text: $instruction)
                Button("Cancel", role: .cancel) { continuing = nil }
                Button("Continue") {
                    if let task = continuing {
                        do { _ = try subagents.continueTask(taskID: task.id, instruction: instruction); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                    continuing = nil
                }
            }
            .confirmationDialog("Delete finished subtask?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Subtask", role: .destructive) {
                    if let task = deleting {
                        do { try subagents.deleteFinishedTask(task.id); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its conversation and task history will be deleted.")
            }
        }
    }

    @ViewBuilder
    private func row(_ task: SubagentTask, isChild: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.caption.weight(.medium)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(status(task)).font(.caption).foregroundStyle(.secondary)
                        .help(usage(task))
                        .accessibilityIdentifier("native.task.status.\(task.id)")
                }
            }
            Spacer()
            if !isChild {
                Button("View") {
                    appState.focus(window)
                    appState.conversations.selectConversation(id: task.childConversationID)
                }
            }
            if task.status.isFinished {
                Button("Continue") { instruction = ""; continuing = task }
                if !isChild { Button("Delete Task…") { deleting = task } }
            } else {
                Button("Cancel", role: .destructive) { appState.subagents.cancel(taskID: task.id) }
            }
        }.accessibilityIdentifier("native.task.\(task.id)")
    }

    private func status(_ task: SubagentTask) -> String {
        switch task.status {
        case .queued: return String(localized: "Queued")
        case .running:
            return String(localized: "Running · \(elapsedSeconds(task)) s · \(activity(task))")
        case .completed:
            return task.result?.partial == true ? String(localized: "Partial result (reached a limit or didn't finish)") : String(localized: "Completed")
        case .failed: return String(localized: "Failed: \(task.failure ?? String(localized: "unknown reason"))")
        case .cancelled: return String(localized: "Cancelled")
        case .interrupted: return task.failure ?? String(localized: "Interrupted; can continue")
        }
    }

    /// The budget and totals behind the short status line, shown on hover.
    private func usage(_ task: SubagentTask) -> String {
        guard task.status == .running else { return totalUsage(task) }
        let round = String(localized: "This round: requests \(task.spent.modelRequests)/\(task.allowance.modelRequests) · tools \(task.spent.toolCalls)/\(task.allowance.toolCalls) · \(elapsedSeconds(task))/\(Int(task.allowance.seconds)) s")
        return "\(round)\n\(totalUsage(task))"
    }

    private func elapsedSeconds(_ task: SubagentTask) -> Int {
        task.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
    }

    private func totalUsage(_ task: SubagentTask) -> String {
        let total = task.cumulativeSpent
        return String(localized: "Total: requests \(total.modelRequests) · tools \(total.toolCalls) · \(Int(total.seconds)) s")
    }

    private func activity(_ task: SubagentTask) -> String {
        guard let runID = task.runID,
              let child = appState.conversations.conversations.first(where: { $0.id == task.childConversationID }),
              let tool = child.messages.flatMap(\.toolCalls).last(where: { $0.owningRunID == runID }) else { return String(localized: "Thinking") }
        guard let state = ToolCallPresentationResolver.statusLabel(for: tool.state) else { return tool.name }
        return "\(tool.name) · \(state)"
    }
}

struct NativeChildInteractionView: View {
    let conversationID: UUID
    var body: some View {
        HStack {
            Text("This is a subtask's conversation, maintained by its own run. To add an instruction, click Continue above, or go back to the parent conversation.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }
}
