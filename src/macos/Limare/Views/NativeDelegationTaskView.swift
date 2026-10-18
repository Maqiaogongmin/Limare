import SwiftUI

/// The subagent tasks of a conversation (or, inside a child conversation, its own task).
struct NativeDelegationTaskView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var collapsedConversations: Set<UUID> = []
    @State private var expandedFinished: Set<UUID> = []
    @State private var continuing: SubagentTask?
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
                        Button("返回父会话") {
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
                                Text("已结束 (\(finished.count))")
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
            .alert("继续子任务", isPresented: Binding(get: { continuing != nil }, set: { if !$0 { continuing = nil } })) {
                TextField("给子任务的指令", text: $instruction)
                Button("取消", role: .cancel) { continuing = nil }
                Button("继续") {
                    if let task = continuing {
                        do { _ = try subagents.continueTask(taskID: task.id, instruction: instruction); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }
                    continuing = nil
                }
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
                        .accessibilityIdentifier("native.task.status.\(task.id)")
                }
            }
            Spacer()
            if !isChild {
                Button("查看") {
                    appState.focus(window)
                    appState.conversations.selectConversation(id: task.childConversationID)
                }
            }
            if task.status.isFinished {
                Button("继续") { instruction = ""; continuing = task }
            } else {
                Button("取消", role: .destructive) { appState.subagents.cancel(taskID: task.id) }
            }
        }.accessibilityIdentifier("native.task.\(task.id)")
    }

    private func status(_ task: SubagentTask) -> String {
        switch task.status {
        case .queued: return "排队中"
        case .running:
            let seconds = task.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return "运行中 · 本轮请求 \(task.spent.modelRequests)/\(task.allowance.modelRequests) · 工具 \(task.spent.toolCalls)/\(task.allowance.toolCalls) · \(seconds)/\(Int(task.allowance.seconds)) 秒 · \(totalUsage(task)) · \(activity(task))"
        case .completed:
            let state = task.result?.partial == true ? "部分结果（到达上限或未完成）" : "已完成"
            return "\(state) · \(totalUsage(task))"
        case .failed: return "失败：\(task.failure ?? "原因未知")"
        case .cancelled: return "已取消"
        case .interrupted: return task.failure ?? "已中断，可继续"
        }
    }

    private func totalUsage(_ task: SubagentTask) -> String {
        let total = task.cumulativeSpent
        return "累计请求 \(total.modelRequests) · 工具 \(total.toolCalls) · \(Int(total.seconds)) 秒"
    }

    private func activity(_ task: SubagentTask) -> String {
        guard let runID = task.runID,
              let child = appState.conversations.conversations.first(where: { $0.id == task.childConversationID }),
              let tool = child.messages.flatMap(\.toolCalls).last(where: { $0.owningRunID == runID }) else { return "思考中" }
        return "\(tool.name) · \(tool.state.rawValue)"
    }
}

struct NativeChildInteractionView: View {
    let conversationID: UUID
    var body: some View {
        HStack {
            Text("这是一个子任务的会话，由它自己的运行维护。要追加指令，请在上方点“继续”，或回到父会话。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(12)
    }
}
