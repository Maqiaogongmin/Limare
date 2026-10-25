import Foundation
import Observation

/// What the run engine needs to know about a subagent run.
struct SubagentRunBinding: Sendable, Equatable {
    let taskID: UUID
    let runID: UUID
    let parentConversationID: UUID
    let childConversationID: UUID
    let role: SubagentRole
    let allowWeb: Bool
}

/// What delegate_task asks for, one per task.
struct SubagentSpec: Sendable {
    let id: UUID
    let title: String
    let goal: String
    let role: SubagentRole
    let allowWeb: Bool
    let allowance: SubagentAllowance
}

/// Subagents as mature coding agents run them (Claude Code, Codex, opencode, Gemini CLI): a
/// child conversation driven by the ordinary run engine, with the parent's tools for its role
/// and the parent's permission mode, its own allowance, one final turn without tools at the
/// limit, and its result handed back to the parent.
///
/// The parent stays in charge (Codex `wait_agent`): a wait always ends within its timeout and
/// shows what each running child is doing, so a slow or stray child can be redirected,
/// cancelled or taken over. Results the parent did not wait for arrive on their own: steered
/// into its running turn, or as a new turn when it is idle.
@MainActor
@Observable
final class SubagentCoordinator {
    let store: SubagentStore
    @ObservationIgnored private let conversations: ConversationStore
    @ObservationIgnored private let runs: ConversationRunCoordinator
    @ObservationIgnored private let logs: DebugLogStore
    /// Subagent runs at the same time; more wait in the queue.
    static let capacity = 3

    @ObservationIgnored private var finalTurnRuns: Set<UUID> = []
    @ObservationIgnored private var finalTurnDispatched: Set<UUID> = []
    @ObservationIgnored private var limitStoppedRuns: Set<UUID> = []
    @ObservationIgnored private var lastText: [UUID: String] = [:]
    /// What each run did, newest last, for progress and for a report the child never wrote.
    @ObservationIgnored private var actions: [UUID: [String]] = [:]
    /// When the run's model request still waiting for an answer went out.
    @ObservationIgnored private var requestStartedAt: [UUID: Date] = [:]
    /// When the final turn's request went out; the run gets its grace from then.
    @ObservationIgnored private var finalTurnSentAt: [UUID: Date] = [:]
    @ObservationIgnored private var stagedResults: [UUID: SubagentResult] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    /// Tasks whose results a waiting delegate_task call will return.
    @ObservationIgnored private var awaited: Set<UUID> = []
    /// Finished tasks whose results the parent has not received yet.
    @ObservationIgnored private(set) var undelivered: Set<UUID> = []
    @ObservationIgnored private var quietParents: Set<UUID> = []
    @ObservationIgnored private var cancelRequested: Set<UUID> = []

    init(store: SubagentStore, conversations: ConversationStore, runs: ConversationRunCoordinator, logs: DebugLogStore) {
        self.store = store
        self.conversations = conversations
        self.runs = runs
        self.logs = logs
    }

    // MARK: - Tools by role

    /// Claude Code's Explore and Codex's explorer investigate with the shell (git log, grep, builds)
    /// as well as file reads; the shell runs under the parent's permission rules.
    static let researchTools: Set<String> = ["file_read", "file_list", "file_search", "read_image", "tool_result_read", "shell_execute"]
    static let excludedFromChildren: Set<String> = ["delegate_task", "delegation_control", "computer_use", "ask_user_question"]

    /// Research investigates (and browses when the task allows the web) without the file
    /// editing tools; coding gets the parent's tools. No child delegates further or drives the desktop.
    static func allows(_ name: String, role: SubagentRole, allowWeb: Bool) -> Bool {
        if name == "delegation_result" { return true }
        if excludedFromChildren.contains(name) { return false }
        switch role {
        case .research: return researchTools.contains(name) || (allowWeb && name == "browser_use")
        case .coding: return true
        }
    }

    // MARK: - Starting

    func start(_ specs: [SubagentSpec], parentConversationID: UUID, modelSource: ConversationModelSource,
               background: Bool) throws -> [SubagentTask] {
        guard let parent = conversations.conversations.first(where: { $0.id == parentConversationID }),
              !parent.isNativeDelegationChild else { throw DelegationFailure.permissionDenied }
        let workspace = conversations.effectiveWorkingDirectory(for: parent.id)
        var started: [SubagentTask] = []
        for spec in specs {
            // The same tool call replayed (for example by recovery) finds its tasks again.
            if let existing = store.tasks[spec.id] { started.append(existing); continue }
            let child = ConversationRecord(title: spec.title, projectID: parent.projectID, workspace: .from(url: workspace),
                modelSource: modelSource, subModelSource: nil, thinkingLevelOverride: parent.thinkingLevelOverride,
                messages: [ChatMessage(role: .user, content: spec.goal)],
                nativeDelegationTaskID: spec.id, nativeDelegationParentID: parent.id)
            let created = try conversations.createNativeChild(child)
            let task = SubagentTask(id: spec.id, parentConversationID: parent.id, childConversationID: created.id,
                title: spec.title, goal: spec.goal, role: spec.role, allowWeb: spec.allowWeb, allowance: spec.allowance,
                background: background, status: .queued, createdAt: Date())
            store.insert(task)
            started.append(task)
        }
        pump()
        return started.map { store.tasks[$0.id] ?? $0 }
    }

    private func pump() {
        var running = store.tasks.values.filter { $0.status == .running }.count
        for task in store.tasks.values.filter({ $0.status == .queued }).sorted(by: { $0.createdAt < $1.createdAt }) {
            guard running < Self.capacity else { return }
            launch(task)
            running += 1
        }
    }

    private func launch(_ task: SubagentTask) {
        guard let child = conversations.conversations.first(where: { $0.id == task.childConversationID }),
              let source = child.effectiveModelSource else {
            finish(task.id, status: .failed, result: nil, failure: "Its child conversation or model is gone.")
            return
        }
        let runID = UUID()
        let instruction = task.pendingInstruction
        store.update(task.id) {
            $0.status = .running; $0.runID = runID; $0.beginRun(); $0.startedAt = Date()
            $0.pendingInstruction = nil; $0.result = nil; $0.failure = nil; $0.finishedAt = nil
        }
        let binding = SubagentRunBinding(taskID: task.id, runID: runID, parentConversationID: task.parentConversationID,
            childConversationID: task.childConversationID, role: task.role, allowWeb: task.allowWeb)
        do {
            try runs.startSubagentRun(binding, modelSource: source,
                workspace: child.workspace?.url ?? conversations.effectiveWorkingDirectory(for: child.id), instruction: instruction)
        } catch {
            finish(task.id, status: .failed, result: nil, failure: "Could not start: \(error.localizedDescription)")
            return
        }
        watchers[runID] = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let current = self.store.tasks[task.id], current.runID == runID, current.status == .running else { return }
                let started = current.startedAt ?? Date()
                self.store.update(task.id) { $0.recordRunSeconds(Date().timeIntervalSince(started)) }
                if Date() >= self.hardStop(runID: runID, started: started, allowance: current.allowance.seconds) {
                    // Hard limit: the final turn overran its grace, or a request was still
                    // running a grace past the allowance. What the child did becomes its result.
                    self.limitStoppedRuns.insert(runID)
                    self.runs.stop(conversationID: current.childConversationID, reason: "This task reached its time limit.")
                    return
                }
                self.prepareNextTurn(runID: runID)
            }
        }
    }

    // MARK: - Allowance and the final turn

    /// Time kept for the final turn: a quarter of the allowance, at most two minutes.
    static func finalTurnSeconds(_ allowance: TimeInterval) -> TimeInterval { min(120, allowance / 4) }

    /// The final turn's own time once its request is out (Gemini CLI's grace period). A request
    /// still running at the end of the allowance gets the same grace to finish.
    static func finalTurnGrace(_ allowance: TimeInterval) -> TimeInterval { min(90, max(1, allowance / 4)) }

    private func hardStop(runID: UUID, started: Date, allowance: TimeInterval) -> Date {
        if let sent = finalTurnSentAt[runID] { return sent.addingTimeInterval(Self.finalTurnGrace(allowance)) }
        return started.addingTimeInterval(allowance + Self.finalTurnGrace(allowance))
    }

    /// The next request has to be the last: one request is left, the tool calls are used up, or
    /// only the final turn's time remains.
    static func needsFinalTurn(_ left: SubagentAllowance, allowanceSeconds: TimeInterval) -> Bool {
        left.modelRequests <= 1 || left.toolCalls <= 0 || left.seconds <= finalTurnSeconds(allowanceSeconds)
    }

    static let finalTurnInstruction = """
        Final turn: this task has reached its limit (model requests, tool calls or time), so tools are now disabled. \
        Reply with text only. This reply is your final report to the parent: what you found or changed (with file \
        paths and evidence), what is still unverified or unfinished, and what should be done next.
        """

    private func left(_ task: SubagentTask) -> SubagentAllowance {
        let elapsed = task.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return .init(modelRequests: task.allowance.modelRequests - task.spent.modelRequests,
                     toolCalls: task.allowance.toolCalls - task.spent.toolCalls, seconds: task.allowance.seconds - elapsed)
    }

    /// Called at each safe boundary of a subagent run and by its watcher (Gemini CLI's grace turn,
    /// opencode's last step): when the next request has to be the last, the child is told so
    /// through its steering inbox and that request goes out without tools. The notice is the
    /// system's, not the user's: tool calls the child already asked for still run (or are refused
    /// over the limit) before it arrives.
    func prepareNextTurn(runID: UUID) {
        guard !finalTurnRuns.contains(runID), let task = store.task(runID: runID), task.status == .running,
              Self.needsFinalTurn(left(task), allowanceSeconds: task.allowance.seconds),
              runs.steer(conversationID: task.childConversationID, runID: runID,
                         message: .systemNotice(Self.finalTurnInstruction)) else { return }
        finalTurnRuns.insert(runID)
        logs.info("Subagent", "Task '\(task.title)' reached its limit; its next request is a final turn without tools.")
    }

    func isFinalTurn(runID: UUID) -> Bool { finalTurnRuns.contains(runID) }

    /// Counts a model request; only the final turn may go past the allowance's last request.
    func willSendModelRequest(runID: UUID) throws {
        guard let task = store.task(runID: runID), task.status == .running else { throw DelegationFailure.executorLost }
        if finalTurnDispatched.contains(runID) { throw DelegationFailure.budgetExhausted }
        if finalTurnRuns.contains(runID) { finalTurnDispatched.insert(runID); finalTurnSentAt[runID] = Date() }
        else if task.spent.modelRequests >= task.allowance.modelRequests { throw DelegationFailure.budgetExhausted }
        requestStartedAt[runID] = Date()
        store.update(task.id) { $0.countModelRequest() }
    }

    /// Counts a tool call. Returns why it may not run, or nil. Over the limit a call is refused
    /// and the child goes on to its final turn; it is never stopped for it.
    func refusalForTool(runID: UUID, call: ProviderToolCall) -> String? {
        let name = call.function.name
        requestStartedAt[runID] = nil
        guard let task = store.task(runID: runID), task.status == .running else { return "This subagent task is no longer running." }
        if finalTurnDispatched.contains(runID) { return "Tools are off in the final turn; reply with your report." }
        guard Self.allows(name, role: task.role, allowWeb: task.allowWeb) else { return "\(name) is not available to a \(task.role.rawValue) subagent." }
        if name == "delegation_result" { return nil }
        guard task.spent.toolCalls < task.allowance.toolCalls else {
            prepareNextTurn(runID: runID)
            return "This task has used its tool calls. Reply with your report."
        }
        store.update(task.id) { $0.countToolCall() }
        actions[runID, default: []].append(Self.describe(call))
        return nil
    }

    func assistantTextCompleted(runID: UUID, text: String) {
        requestStartedAt[runID] = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.task(runID: runID)?.status == .running else { return }
        lastText[runID] = trimmed
    }

    /// One line for a tool call: its name and the argument that says what it touched.
    static func describe(_ call: ProviderToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
        let key = ["command", "path", "query", "pattern", "url", "action"].first { args[$0] is String }
        guard let key, var value = args[key] as? String else { return call.function.name }
        value = value.replacingOccurrences(of: "\n", with: " ")
        if value.count > 160 { value = String(value.prefix(160)) + "…" }
        return "\(call.function.name) \(value)"
    }

    /// `delegation_result`: the child's own structured report.
    func stageResult(runID: UUID, result: SubagentResult) throws {
        guard store.task(runID: runID)?.status == .running else { throw DelegationFailure.executorLost }
        stagedResults[runID] = result
    }

    // MARK: - Finishing

    /// The run engine reports a subagent run's end once its loop has unwound.
    func runEnded(runID: UUID, status: ConversationRunStatus, error: String?) {
        defer {
            watchers.removeValue(forKey: runID)?.cancel()
            finalTurnRuns.remove(runID); finalTurnDispatched.remove(runID); limitStoppedRuns.remove(runID)
            lastText.removeValue(forKey: runID); stagedResults.removeValue(forKey: runID)
            actions.removeValue(forKey: runID); requestStartedAt.removeValue(forKey: runID); finalTurnSentAt.removeValue(forKey: runID)
        }
        guard let current = store.task(runID: runID), current.status == .running else { return }
        if let startedAt = current.startedAt {
            store.update(current.id) { $0.recordRunSeconds(Date().timeIntervalSince(startedAt)) }
        }
        guard let task = store.task(runID: runID), task.status == .running else { return }
        let wroteFinalTurn = finalTurnRuns.contains(runID) && status == .completed
        // Only a run that ended on its own wrote a report: its delegation_result or last text.
        // Text from a run that was stopped is an interim remark, never presented as a report.
        var report = stagedResults[runID] ?? (status == .completed ? lastText[runID].map { SubagentResult(summary: $0, partial: false) } : nil)
        if wroteFinalTurn { report?.partial = true; report?.openItems.append("Written at its limit; it may be incomplete.") }
        if status != .completed { report?.partial = true }
        let cancelled = cancelRequested.remove(task.id) != nil
        let evidence = report ?? self.evidence(runID: runID)
        switch status {
        case .completed:
            finish(task.id, status: .completed, result: evidence, failure: report == nil ? "Ended without a report." : nil)
        case .interrupted:
            finish(task.id, status: .interrupted, result: evidence, failure: "Interrupted; continue it to resume.")
        case .cancelled where cancelled:
            finish(task.id, status: .cancelled, result: evidence, failure: "Cancelled.")
        default:
            let reason = limitStoppedRuns.contains(runID) ? "Stopped at its time limit before it wrote a report."
                : (error ?? "The run stopped (\(status.rawValue)).")
            finish(task.id, status: .failed, result: evidence, failure: reason)
        }
        if !cancelled { deliver(task.id) }
        pump()
    }

    /// What a child that wrote no report leaves the parent: what it did and its last words.
    private func evidence(runID: UUID) -> SubagentResult? {
        let done = actions[runID] ?? []
        let last = lastText[runID]
        guard !done.isEmpty || last != nil else { return nil }
        var text = "No report. What it did (\(done.count) tool call\(done.count == 1 ? "" : "s")):"
        text += done.suffix(30).map { "\n- " + $0 }.joined()
        if done.count > 30 { text += "\n(\(done.count - 30) earlier calls not shown)" }
        if let last { text += "\nIts last message, written before it finished: " + String(last.prefix(2_000)) }
        return SubagentResult(summary: text, partial: true)
    }

    private func finish(_ id: UUID, status: SubagentStatus, result: SubagentResult?, failure: String?) {
        store.update(id) { $0.status = status; $0.result = result; $0.failure = failure; $0.finishedAt = Date() }
    }

    // MARK: - Results to the parent

    /// Codex's wait timeout: 30 seconds by default, at least 10, at most an hour.
    static let defaultWaitSeconds: TimeInterval = 30
    static func clampedWait(_ seconds: TimeInterval?) -> TimeInterval { min(3600, max(10, seconds ?? defaultWaitSeconds)) }

    /// Waits until one of the tasks finishes or the timeout passes (Codex `wait_agent`), then
    /// returns the finished tasks' results and the running ones' progress. The tasks it returns
    /// finished are not delivered again. Stopping the parent while it waits cancels the tasks it
    /// was waiting for (Claude Code stops foreground subagents with the main agent); tasks it is
    /// not waiting for carry on.
    func wait(taskIDs: [UUID], timeout: TimeInterval, onProgress: (String) -> Void = { _ in }) async throws -> String {
        awaited.formUnion(taskIDs)
        defer { awaited.subtract(taskIDs) }
        let deadline = Date().addingTimeInterval(timeout)
        var lastProgress = ""
        do {
            while true {
                try Task.checkCancellation()
                let current = taskIDs.compactMap { store.tasks[$0] }
                if current.contains(where: { $0.status.isFinished }) || Date() >= deadline { break }
                let progress = current.map { "\($0.title): \(progressLine($0))" }.joined(separator: "\n")
                if progress != lastProgress { lastProgress = progress; onProgress(progress) }
                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            for id in taskIDs where store.tasks[id]?.status.isFinished == false { cancel(taskID: id) }
            throw error
        }
        let current = taskIDs.compactMap { store.tasks[$0] }
        undelivered.subtract(current.filter { $0.status.isFinished }.map(\.id))
        let finished = current.filter { $0.status.isFinished }.count
        var header = finished == current.count ? "\(finished) subagent task(s) finished."
            : "\(finished) of \(current.count) subagent task(s) finished; the others are still running."
        if finished < current.count {
            header += " Wait again with delegation_control (action wait), redirect one with continue, or cancel it."
                + " If a task is slow or going the wrong way, cancel it and do that work yourself."
                + " Results you do not wait for are delivered to you when they finish."
        }
        return resultsText(current, header: header)
    }

    /// One line on a running task, the signal a parent needs to judge it: time, requests, tool
    /// calls, how long the current model request has been out, and what it did last.
    func progressLine(_ task: SubagentTask) -> String {
        guard task.status == .running, let runID = task.runID else { return task.status.rawValue }
        let elapsed = Int(Date().timeIntervalSince(task.startedAt ?? Date()))
        var line = "running for \(elapsed)s of \(Int(task.allowance.seconds))s, \(task.spent.modelRequests) model request(s), \(task.spent.toolCalls) tool call(s)"
        if let sent = requestStartedAt[runID] { line += "; its current model request has been waiting \(Int(Date().timeIntervalSince(sent)))s" }
        if let recent = actions[runID]?.suffix(3), !recent.isEmpty { line += "; recent: " + recent.joined(separator: " | ") }
        if let last = lastText[runID] { line += "; last said: " + String(last.prefix(300)) }
        return line
    }

    /// Results nobody waited for reach the parent without polling (Claude Code, opencode, Codex):
    /// a running parent sees them at its next step, an idle one gets them as a new turn.
    private func deliver(_ id: UUID) {
        guard !awaited.contains(id), let task = store.tasks[id],
              !quietParents.contains(task.parentConversationID) else { return }
        undelivered.insert(id)
        if runs.isActive(conversationID: task.parentConversationID) {
            let text = resultsText([task], header: Self.deliveryHeader(count: 1))
            if runs.steer(conversationID: task.parentConversationID, message: .systemNotice(text)) {
                undelivered.remove(id)
                logs.info("Subagent", "Steered the result of '\(task.title)' into its parent's running turn.")
            }
        } else {
            deliverResults(to: task.parentConversationID)
        }
    }

    static func deliveryHeader(count: Int) -> String {
        "\(ChatMessage.systemNoticePrefix) \(count) subagent task(s) finished. This is a delivery from the system, not a new request from the user. Use these results to continue the user's request."
    }

    /// A parent run that completed takes the waiting results; one that was stopped or failed does
    /// not wake up for them (they stay in the task bar).
    func parentRunFinished(conversationID: UUID, completed: Bool) {
        if completed { deliverResults(to: conversationID) }
        else {
            quietParents.insert(conversationID)
            undelivered = undelivered.filter { store.tasks[$0]?.parentConversationID != conversationID }
        }
    }

    func userRunStarted(conversationID: UUID) { quietParents.remove(conversationID) }

    func conversationCleared(_ conversationID: UUID) {
        quietParents.remove(conversationID)
        undelivered = undelivered.filter { store.tasks[$0]?.parentConversationID != conversationID }
    }

    private func deliverResults(to parentID: UUID) {
        guard !quietParents.contains(parentID) else { return }
        let ready = undelivered.compactMap { store.tasks[$0] }.filter { $0.parentConversationID == parentID }
            .sorted { $0.createdAt < $1.createdAt }
        guard !ready.isEmpty else { return }
        guard let parent = conversations.conversations.first(where: { $0.id == parentID }) else {
            undelivered.subtract(ready.map(\.id))
            return
        }
        guard let source = parent.effectiveModelSource else { return }
        let text = resultsText(ready, header: Self.deliveryHeader(count: ready.count))
        guard runs.deliverNotice(conversationID: parentID, message: .systemNotice(text), modelSource: source) else { return }
        undelivered.subtract(ready.map(\.id))
        logs.info("Subagent", "Delivered \(ready.count) result(s) to parent '\(parentID)'.")
    }

    func resultsText(_ tasks: [SubagentTask], header: String) -> String {
        var text = header
        for task in tasks {
            text += "\n\n## \(task.title) (\(statusWord(task)), task_id \(task.id))\n"
            if !task.status.isFinished {
                text += "Progress: " + progressLine(task)
                continue
            }
            if let failure = task.failure { text += failure + "\n" }
            if let result = task.result {
                text += result.summary.count > 12_000
                    ? String(result.summary.prefix(12_000)) + "\n[Truncated; delegation_control status returns the full result.]"
                    : result.summary
                if !result.changedFiles.isEmpty { text += "\nChanged files: " + result.changedFiles.joined(separator: ", ") }
                if !result.openItems.isEmpty { text += "\nOpen: " + result.openItems.joined(separator: "; ") }
            } else if task.failure == nil {
                text += "No report."
            }
        }
        return text
    }

    private func statusWord(_ task: SubagentTask) -> String {
        if task.status == .completed { return task.result?.partial == true ? "partial" : "completed" }
        return task.status.rawValue
    }

    // MARK: - Control

    func cancel(taskID: UUID) {
        guard let task = store.tasks[taskID] else { return }
        switch task.status {
        case .queued: finish(taskID, status: .cancelled, result: nil, failure: "Cancelled before it started.")
        case .running:
            cancelRequested.insert(taskID)
            runs.stop(conversationID: task.childConversationID, reason: "Cancelled.")
        default: break
        }
    }

    /// A running task reads the instruction at its next step; a finished one runs again with it
    /// and a fresh allowance.
    func continueTask(taskID: UUID, instruction: String) throws -> SubagentTask {
        guard let task = store.tasks[taskID], !instruction.isEmpty else { throw DelegationFailure.invalidRequest }
        switch task.status {
        case .running:
            guard let runID = task.runID,
                  runs.steer(conversationID: task.childConversationID, runID: runID, message: ChatMessage(role: .user, content: instruction))
            else { throw DelegationFailure.executorLost }
        case .queued:
            store.update(taskID) { $0.pendingInstruction = [$0.pendingInstruction, instruction].compactMap { $0 }.joined(separator: "\n\n") }
        default:
            store.update(taskID) { $0.status = .queued; $0.pendingInstruction = instruction; $0.result = nil; $0.failure = nil }
            pump()
        }
        return store.tasks[taskID]!
    }

    func hasUnfinishedTasks(parentConversationID: UUID) -> Bool {
        store.tasks.values.contains { $0.parentConversationID == parentConversationID && !$0.status.isFinished }
    }

    /// After a restart nothing resumes by itself: running and queued tasks show as interrupted
    /// and can be continued.
    func reconcileRestart() {
        for task in store.tasks.values where !task.status.isFinished {
            finish(task.id, status: .interrupted, result: nil, failure: "Limare quit while this task was running; continue it to resume.")
        }
    }

    /// A deleted parent stops its children; a deleted child stops its task.
    func conversationDeleted(_ conversationID: UUID) {
        conversationCleared(conversationID)
        for task in store.tasks.values where task.parentConversationID == conversationID || task.childConversationID == conversationID {
            cancel(taskID: task.id)
        }
    }

    /// What delegation_control status shows the parent model.
    func projection(_ task: SubagentTask) -> [String: Any] {
        let total = task.cumulativeSpent
        var item: [String: Any] = ["task_id": task.id.uuidString, "title": task.title, "role": task.role.rawValue,
            "status": statusWord(task), "child_conversation_id": task.childConversationID.uuidString,
            "used": ["model_requests": task.spent.modelRequests, "tool_calls": task.spent.toolCalls, "seconds": Int(task.spent.seconds)],
            "total_used": ["model_requests": total.modelRequests, "tool_calls": total.toolCalls, "seconds": Int(total.seconds)],
            "allowance": ["model_requests": task.allowance.modelRequests, "tool_calls": task.allowance.toolCalls, "seconds": Int(task.allowance.seconds)]]
        if let result = task.result {
            item["result"] = result.summary
            if !result.changedFiles.isEmpty { item["changed_files"] = result.changedFiles }
            if !result.openItems.isEmpty { item["open_items"] = result.openItems }
        }
        if let failure = task.failure { item["reason"] = failure }
        if task.status == .running { item["progress"] = progressLine(task) }
        return item
    }
}
