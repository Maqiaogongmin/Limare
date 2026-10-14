import Foundation
import Observation

@MainActor
@Observable
final class HookSessionCoordinator {
    private struct RunState {
        var runID: UUID
        var turnID = UUID()
        var sessionContext: String?
        var turnContext: String?
        var pendingContext: String?
        var sessionExecutions: [HookExecutionSummary] = []
        var turnExecutions: [HookExecutionSummary] = []
        var pendingExecutions: [HookExecutionSummary] = []
        var workspaceURL: URL?
        var stopSent = false
    }
    private var runStates: [UUID: RunState] = [:]
    /// Claimed Stop Hooks that have not finished, per conversation. A Stop Hook runs after its
    /// run reached a terminal state and may still change files, so callers that need the
    /// conversation to be fully settled (retraction, delivery) wait for this to reach zero.
    private(set) var pendingStopHookCounts: [UUID: Int] = [:]
    private(set) var currentSessionID: UUID = UUID()
    private(set) var currentTurnID: UUID = UUID()

    private(set) var sessionHookContext: String?
    private(set) var turnHookContext: String?
    private(set) var pendingToolHookContext: String?

    private let hookStore: HookStore
    private let workspace: WorkspaceStore
    private let logs: DebugLogStore

    private(set) var activeGeneration: Int = 0
    private var transitionTask: Task<String?, Never>?

    init(
        hookStore: HookStore,
        workspace: WorkspaceStore,
        logs: DebugLogStore
    ) {
        self.hookStore = hookStore
        self.workspace = workspace
        self.logs = logs
    }

    func setSessionID(_ id: UUID) {
        self.currentSessionID = id
    }

    private func commonPayload(eventName: String, model: String?, sessionID: UUID? = nil, workspaceURL: URL? = nil) -> [String: Any] {
        let wsURL = workspaceURL ?? workspace.url
        let cwd = wsURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        var roots: [String] = []
        if let ws = wsURL {
            roots.append(ws.path)
        }

        let sid = (sessionID ?? currentSessionID).uuidString
        return [
            "session_id": sid,
            "conversation_id": sid,
            "transcript_path": NSNull(),
            "cwd": cwd,
            "hook_event_name": eventName,
            "model": model ?? "",
            "permission_mode": "default",
            "workspace_roots": roots
        ]
    }

    func transition(
        from oldID: UUID?,
        to newID: UUID,
        source: String = "resume",
        model: String? = nil,
        workspaceURL: URL? = nil
    ) async -> String? {
        activeGeneration += 1
        let generation = activeGeneration
        self.currentSessionID = newID

        let task = Task<String?, Never> { @MainActor in
            let effectiveURL = workspaceURL ?? self.workspace.url ?? FileManager.default.homeDirectoryForCurrentUser
            if let old = oldID, old != newID {
                await self.onSessionEnd(conversationID: old, reason: "switch", model: model, workspaceURL: effectiveURL)
            }
            guard self.activeGeneration == generation else {
                return nil
            }
            return await self.onSessionStart(conversationID: newID, source: source, model: model, workspaceURL: effectiveURL)
        }
        self.transitionTask = task
        return await task.value
    }

    func ensureSessionReady(conversationID: UUID) async {
        if let task = transitionTask {
            _ = await task.value
        }
    }

    func beginRun(conversationID: UUID, runID: UUID, workspaceURL: URL?, model: String? = nil) async -> HookAggregatedResult? {
        runStates[conversationID] = RunState(runID: runID, workspaceURL: workspaceURL)
        var payload = scopedPayload(event: .sessionStart, conversationID: conversationID, state: runStates[conversationID]!, model: model)
        payload["source"] = "run"
        let result = await hookStore.runtime.executeEvent(eventName: .sessionStart, sources: hookStore.sources, workspaceURL: workspaceURL, sessionID: conversationID.uuidString, stdinPayload: payload)
        hookStore.recordExecutions(result.executions)
        guard runStates[conversationID]?.runID == runID else { return nil }
        runStates[conversationID]?.sessionContext = result.additionalContext
        runStates[conversationID]?.sessionExecutions = result.executions
        return result
    }

    func onUserPromptSubmit(conversationID: UUID, runID: UUID, prompt: String, model: String? = nil) async -> HookAggregatedResult {
        guard var state = runStates[conversationID], state.runID == runID else { return .init() }
        state.turnID = UUID()
        state.turnContext = nil
        state.pendingContext = nil
        state.turnExecutions = []
        state.pendingExecutions = []
        runStates[conversationID] = state
        var payload = scopedPayload(event: .userPromptSubmit, conversationID: conversationID, state: state, model: model)
        payload["turn_id"] = state.turnID.uuidString
        payload["prompt"] = prompt
        payload["userPrompt"] = prompt
        let result = await hookStore.runtime.executeEvent(eventName: .userPromptSubmit, sources: hookStore.sources, workspaceURL: state.workspaceURL, sessionID: conversationID.uuidString, stdinPayload: payload)
        hookStore.recordExecutions(result.executions)
        guard var current = runStates[conversationID], current.runID == runID else {
            return .init()
        }
        current.turnContext = result.additionalContext
        current.turnExecutions = result.executions
        runStates[conversationID] = current
        return result
    }

    func ephemeralHookContext(
        conversationID: UUID,
        runID: UUID,
        toolHookContext: String? = nil
    ) -> String? {
        guard let state = runStates[conversationID], state.runID == runID else {
            return nil
        }
        var fragments: [String] = []
        if let s = state.sessionContext, !s.isEmpty {
            fragments.append(s)
        }
        if let t = state.turnContext, !t.isEmpty {
            fragments.append(t)
        }
        if let p = toolHookContext, !p.isEmpty {
            fragments.append(p)
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    func ephemeralHookContributions(
        conversationID: UUID,
        runID: UUID,
        toolHookContributions: [ExtensionContribution]? = nil
    ) -> [ExtensionContribution] {
        guard let state = runStates[conversationID], state.runID == runID else {
            return toolHookContributions ?? []
        }
        var contribs: [ExtensionContribution] = []
        for exec in state.sessionExecutions {
            if let c = exec.asExtensionContribution() {
                contribs.append(c)
            }
        }
        for exec in state.turnExecutions {
            if let c = exec.asExtensionContribution() {
                contribs.append(c)
            }
        }
        if let toolHookContributions {
            contribs.append(contentsOf: toolHookContributions)
        } else {
            for exec in state.pendingExecutions {
                if let c = exec.asExtensionContribution() {
                    contribs.append(c)
                }
            }
        }
        return contribs
    }

    func consumePendingToolHookContext(conversationID: UUID, runID: UUID) -> String? {
        guard var state = runStates[conversationID], state.runID == runID else { return nil }
        let value = state.pendingContext
        state.pendingContext = nil
        state.pendingExecutions = []
        runStates[conversationID] = state
        return value
    }

    func consumePendingToolHookContributions(conversationID: UUID, runID: UUID) -> [ExtensionContribution] {
        guard var state = runStates[conversationID], state.runID == runID else { return [] }
        let execs = state.pendingExecutions
        state.pendingExecutions = []
        state.pendingContext = nil
        runStates[conversationID] = state
        return execs.compactMap { $0.asExtensionContribution() }
    }

    func simulateToolHookExecutionForTesting(conversationID: UUID, runID: UUID, summary: HookExecutionSummary) {
        guard var state = runStates[conversationID], state.runID == runID else { return }
        state.pendingExecutions.append(summary)
        if let ctx = summary.additionalContext, !ctx.isEmpty {
            if let existing = state.pendingContext, !existing.isEmpty {
                state.pendingContext = existing + "\n\n" + ctx
            } else {
                state.pendingContext = ctx
            }
        }
        runStates[conversationID] = state
    }

    func simulateSessionHookExecutionForTesting(conversationID: UUID, runID: UUID, summary: HookExecutionSummary) {
        guard var state = runStates[conversationID], state.runID == runID else { return }
        state.sessionExecutions.append(summary)
        runStates[conversationID] = state
    }

    private func scopedPayload(event: HookEventName, conversationID: UUID, state: RunState, model: String?) -> [String: Any] {
        let cwd = state.workspaceURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        return ["session_id": conversationID.uuidString, "conversation_id": conversationID.uuidString, "cwd": cwd, "hook_event_name": event.rawValue, "model": model ?? "", "workspace_roots": state.workspaceURL.map { [$0.path] } ?? []]
    }

    private func toolPayload(
        event: HookEventName,
        conversationID: UUID,
        state: RunState,
        call: ProviderToolCall,
        outcome: ToolExecutionOutcome? = nil,
        model: String?
    ) -> [String: Any] {
        let nativeName = call.function.name
        let codexName = HookToolCompatibility.codexToolName(for: nativeName)
        let parsedInput: Any
        if let data = call.function.arguments.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            parsedInput = object
        } else {
            parsedInput = call.function.arguments
        }
        var payload = scopedPayload(event: event, conversationID: conversationID, state: state, model: model)
        payload["turn_id"] = state.turnID.uuidString
        payload["tool_name"] = codexName
        payload["native_tool_name"] = nativeName
        payload["tool_use_id"] = call.id
        payload["tool_input"] = parsedInput
        payload["toolName"] = codexName
        payload["toolArgs"] = parsedInput
        if let outcome {
            payload["tool_response"] = outcome.content
        }
        return payload
    }

    private func appendPendingContext(_ context: String?, executions: [HookExecutionSummary] = [], to state: inout RunState) {
        state.pendingExecutions.append(contentsOf: executions.filter { ($0.additionalContext?.isEmpty == false) })
        guard let context, !context.isEmpty else { return }
        if let existing = state.pendingContext, !existing.isEmpty {
            state.pendingContext = existing + "\n\n" + context
        } else {
            state.pendingContext = context
        }
    }

    /// Executes PreToolUse for the exact run which owns the ToolExecutor.
    /// A missing/replaced run is stale work, never a reason to fall back to a
    /// foreground or another conversation state.
    func onPreToolUse(
        conversationID: UUID,
        runID: UUID,
        call: ProviderToolCall,
        model: String? = nil
    ) async -> HookAggregatedResult {
        guard let state = runStates[conversationID], state.runID == runID else { return .init() }
        let payload = toolPayload(event: .preToolUse, conversationID: conversationID, state: state, call: call, model: model)
        let result = await hookStore.runtime.executeEvent(
            eventName: .preToolUse,
            sources: hookStore.sources,
            workspaceURL: state.workspaceURL,
            sessionID: conversationID.uuidString,
            nativeToolName: call.function.name,
            stdinPayload: payload
        )
        hookStore.recordExecutions(result.executions)
        guard var current = runStates[conversationID], current.runID == runID else { return .init() }
        appendPendingContext(result.additionalContext, executions: result.executions, to: &current)
        runStates[conversationID] = current
        return result
    }

    /// Executes PostToolUse for the same immutable executor scope as PreToolUse.
    /// Late completions are discarded if a replacement run has taken over.
    func onPostToolUse(
        conversationID: UUID,
        runID: UUID,
        call: ProviderToolCall,
        outcome: ToolExecutionOutcome,
        model: String? = nil
    ) async -> HookAggregatedResult {
        guard let state = runStates[conversationID], state.runID == runID else { return .init() }
        let event: HookEventName = outcome.isError ? .postToolUseFailure : .postToolUse
        let payload = toolPayload(event: event, conversationID: conversationID, state: state, call: call, outcome: outcome, model: model)
        let result = await hookStore.runtime.executeEvent(
            eventName: event,
            sources: hookStore.sources,
            workspaceURL: state.workspaceURL,
            sessionID: conversationID.uuidString,
            nativeToolName: call.function.name,
            stdinPayload: payload
        )
        hookStore.recordExecutions(result.executions)
        guard var current = runStates[conversationID], current.runID == runID else { return .init() }
        appendPendingContext(result.additionalContext, executions: result.executions, to: &current)
        runStates[conversationID] = current
        return result
    }

    struct StopClaim: Sendable {
        let conversationID: UUID
        let runID: UUID
        let turnID: UUID
        let workspaceURL: URL?
        let lastAssistantMessage: String
        let model: String?
        let sources: [HookSource]
    }

    func claimStop(
        conversationID: UUID,
        runID: UUID,
        lastAssistantMessage: String,
        model: String? = nil
    ) -> StopClaim? {
        guard let state = runStates[conversationID], state.runID == runID, !state.stopSent else {
            return nil
        }
        runStates.removeValue(forKey: conversationID)
        pendingStopHookCounts[conversationID, default: 0] += 1
        return StopClaim(
            conversationID: conversationID,
            runID: runID,
            turnID: state.turnID,
            workspaceURL: state.workspaceURL,
            lastAssistantMessage: lastAssistantMessage,
            model: model,
            sources: hookStore.sources
        )
    }

    func hasPendingStopHooks(conversationID: UUID) -> Bool {
        (pendingStopHookCounts[conversationID] ?? 0) > 0
    }

    func executeClaimedStop(_ claim: StopClaim) async -> HookAggregatedResult {
        defer {
            let remaining = (pendingStopHookCounts[claim.conversationID] ?? 1) - 1
            pendingStopHookCounts[claim.conversationID] = remaining > 0 ? remaining : nil
        }
        let cwd = claim.workspaceURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let roots = claim.workspaceURL.map { [$0.path] } ?? []
        let payload: [String: Any] = [
            "session_id": claim.conversationID.uuidString,
            "conversation_id": claim.conversationID.uuidString,
            "cwd": cwd,
            "hook_event_name": HookEventName.stop.rawValue,
            "model": claim.model ?? "",
            "workspace_roots": roots,
            "turn_id": claim.turnID.uuidString,
            "stop_hook_active": false,
            "last_assistant_message": claim.lastAssistantMessage
        ]
        let result = await hookStore.runtime.executeEvent(
            eventName: .stop,
            sources: claim.sources,
            workspaceURL: claim.workspaceURL,
            sessionID: claim.conversationID.uuidString,
            stdinPayload: payload
        )
        hookStore.recordExecutions(result.executions)
        return result
    }

    func scheduleStop(
        conversationID: UUID,
        runID: UUID,
        lastAssistantMessage: String,
        model: String? = nil
    ) {
        guard let claim = claimStop(
            conversationID: conversationID,
            runID: runID,
            lastAssistantMessage: lastAssistantMessage,
            model: model
        ) else { return }
        Task { @MainActor in
            _ = await self.executeClaimedStop(claim)
        }
    }

    func onStop(
        conversationID: UUID,
        runID: UUID,
        lastAssistantMessage: String,
        model: String? = nil
    ) async -> HookAggregatedResult {
        guard let claim = claimStop(
            conversationID: conversationID,
            runID: runID,
            lastAssistantMessage: lastAssistantMessage,
            model: model
        ) else { return .init() }
        return await executeClaimedStop(claim)
    }

    func onSessionStart(
        conversationID: UUID,
        source: String = "startup",
        model: String? = nil,
        workspaceURL: URL
    ) async -> String? {
        self.currentSessionID = conversationID
        self.sessionHookContext = nil
        self.turnHookContext = nil
        self.pendingToolHookContext = nil

        var payload = commonPayload(eventName: HookEventName.sessionStart.rawValue, model: model, sessionID: conversationID, workspaceURL: workspaceURL)
        payload["source"] = source

        let result = await hookStore.runtime.executeEvent(
            eventName: .sessionStart,
            sources: hookStore.sources,
            workspaceURL: workspaceURL,
            sessionID: conversationID.uuidString,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        if let ctx = result.additionalContext {
            if self.currentSessionID == conversationID {
                self.sessionHookContext = ctx
            }
        }
        return self.sessionHookContext
    }

    func onSessionEnd(
        conversationID: UUID,
        reason: String = "other",
        model: String? = nil,
        workspaceURL: URL
    ) async {
        var payload = commonPayload(eventName: HookEventName.sessionEnd.rawValue, model: model, sessionID: conversationID, workspaceURL: workspaceURL)
        payload["reason"] = reason

        let result = await hookStore.runtime.executeEvent(
            eventName: .sessionEnd,
            sources: hookStore.sources,
            workspaceURL: workspaceURL,
            sessionID: conversationID.uuidString,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        if self.currentSessionID == conversationID {
            self.sessionHookContext = nil
            self.turnHookContext = nil
            self.pendingToolHookContext = nil
        }
    }

    func onUserPromptSubmit(
        prompt: String,
        model: String? = nil
    ) async -> HookAggregatedResult {
        self.currentTurnID = UUID()
        self.turnHookContext = nil
        self.pendingToolHookContext = nil

        var payload = commonPayload(eventName: HookEventName.userPromptSubmit.rawValue, model: model)
        payload["turn_id"] = currentTurnID.uuidString
        payload["prompt"] = prompt
        payload["userPrompt"] = prompt

        let result = await hookStore.runtime.executeEvent(
            eventName: .userPromptSubmit,
            sources: hookStore.sources,
            workspaceURL: workspace.url,
            sessionID: currentSessionID.uuidString,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        if let ctx = result.additionalContext {
            self.turnHookContext = ctx
        }
        return result
    }

    func onPreToolUse(
        call: ProviderToolCall,
        model: String? = nil
    ) async -> HookAggregatedResult {
        let nativeName = call.function.name
        let codexName = HookToolCompatibility.codexToolName(for: nativeName)

        var parsedInput: Any = [:]
        if let data = call.function.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            parsedInput = obj
        } else {
            parsedInput = call.function.arguments
        }

        var payload = commonPayload(eventName: HookEventName.preToolUse.rawValue, model: model)
        payload["turn_id"] = currentTurnID.uuidString
        payload["tool_name"] = codexName
        payload["native_tool_name"] = nativeName
        payload["tool_use_id"] = call.id
        payload["tool_input"] = parsedInput
        payload["toolName"] = codexName
        payload["toolArgs"] = parsedInput

        let result = await hookStore.runtime.executeEvent(
            eventName: .preToolUse,
            sources: hookStore.sources,
            workspaceURL: workspace.url,
            sessionID: currentSessionID.uuidString,
            nativeToolName: nativeName,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        if let ctx = result.additionalContext {
            if let existing = self.pendingToolHookContext {
                self.pendingToolHookContext = existing + "\n\n" + ctx
            } else {
                self.pendingToolHookContext = ctx
            }
        }
        return result
    }

    func onPostToolUse(
        call: ProviderToolCall,
        outcome: ToolExecutionOutcome,
        model: String? = nil
    ) async -> HookAggregatedResult {
        let nativeName = call.function.name
        let codexName = HookToolCompatibility.codexToolName(for: nativeName)
        let eventName: HookEventName = outcome.isError ? .postToolUseFailure : .postToolUse

        var parsedInput: Any = [:]
        if let data = call.function.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            parsedInput = obj
        } else {
            parsedInput = call.function.arguments
        }

        var payload = commonPayload(eventName: eventName.rawValue, model: model)
        payload["turn_id"] = currentTurnID.uuidString
        payload["tool_name"] = codexName
        payload["native_tool_name"] = nativeName
        payload["tool_use_id"] = call.id
        payload["tool_input"] = parsedInput
        payload["tool_response"] = outcome.content
        payload["toolName"] = codexName
        payload["toolArgs"] = parsedInput

        let result = await hookStore.runtime.executeEvent(
            eventName: eventName,
            sources: hookStore.sources,
            workspaceURL: workspace.url,
            sessionID: currentSessionID.uuidString,
            nativeToolName: nativeName,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        if let ctx = result.additionalContext {
            if let existing = self.pendingToolHookContext {
                self.pendingToolHookContext = existing + "\n\n" + ctx
            } else {
                self.pendingToolHookContext = ctx
            }
        }
        return result
    }

    func onStop(
        lastAssistantMessage: String,
        model: String? = nil
    ) async -> HookAggregatedResult {
        var payload = commonPayload(eventName: HookEventName.stop.rawValue, model: model)
        payload["turn_id"] = currentTurnID.uuidString
        payload["stop_hook_active"] = false
        payload["last_assistant_message"] = lastAssistantMessage

        let result = await hookStore.runtime.executeEvent(
            eventName: .stop,
            sources: hookStore.sources,
            workspaceURL: workspace.url,
            sessionID: currentSessionID.uuidString,
            stdinPayload: payload
        )

        hookStore.recordExecutions(result.executions)
        self.turnHookContext = nil
        self.pendingToolHookContext = nil
        return result
    }

    func ephemeralHookContext(toolHookContext: String? = nil) -> String? {
        var fragments: [String] = []
        if let s = sessionHookContext, !s.isEmpty {
            fragments.append(s)
        }
        if let t = turnHookContext, !t.isEmpty {
            fragments.append(t)
        }
        if let p = toolHookContext, !p.isEmpty {
            fragments.append(p)
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    func combinedEphemeralHookContext() -> String? {
        ephemeralHookContext(toolHookContext: pendingToolHookContext)
    }

    func consumePendingToolHookContext() -> String? {
        let ctx = pendingToolHookContext
        pendingToolHookContext = nil
        return ctx
    }
}
