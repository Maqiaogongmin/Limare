import XCTest
@testable import Limare

final class ShellObservabilityTests: XCTestCase {
    func testTimingUsesOutputEventsAndStopsAtTerminalState() {
        let start = Date(timeIntervalSince1970: 1_000)
        var call = ToolCallRecord(providerCallID: "1", name: "shell_execute", input: "{}")
        XCTAssertTrue(call.applyExecutionUpdate(.init(state: .running, approvalState: .notRequired, output: "", shellStartedAt: start)))
        XCTAssertEqual(ShellRunPresentation.silenceSeconds(call, now: start.addingTimeInterval(65)), 65)
        XCTAssertTrue(call.applyExecutionUpdate(.init(state: .running, approvalState: .notRequired, output: "output", shellOutputAt: start.addingTimeInterval(62))))
        XCTAssertEqual(ShellRunPresentation.silenceSeconds(call, now: start.addingTimeInterval(65)), 3)
        XCTAssertTrue(call.applyExecutionUpdate(.init(state: .completed, approvalState: .notRequired, output: "output")))
        XCTAssertNil(ShellRunPresentation.silenceSeconds(call, now: start.addingTimeInterval(200)))
        XCTAssertFalse(call.applyExecutionUpdate(.init(state: .running, approvalState: .notRequired, output: "late", shellOutputAt: start.addingTimeInterval(100))))
        XCTAssertEqual(call.shellLastOutputAt, start.addingTimeInterval(62))
    }

    func testRealShellTimeoutMeasuresTotalAndSilenceSeparately() async throws {
        let request = ShellExecutionRequest(command: "printf ready; sleep 3", cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeoutSeconds: 0.5, unconfined: true)
        var final: ShellExecutionResult?
        for try await event in ShellRunner().stream(request) {
            if case .finished(let result) = event { final = result }
        }
        let result = try XCTUnwrap(final)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.stdout.contains("ready"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.elapsedMillisecondsAtTimeout), 400)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.silentMillisecondsAtTimeout), 300)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.silentMillisecondsAtTimeout), try XCTUnwrap(result.elapsedMillisecondsAtTimeout))
    }

    @MainActor
    func testCompletedShellOutputCapsTerminalDisplayAndSurfacesOverflowPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DebugLogStore(storageRootURL: directory, osLogProjection: { _, _, _ in })
        let workspace = WorkspaceStore(persistence: .runScoped, logs: logs)
        try workspace.setWorkspace(directory)
        let permissions = PermissionStore(logs: logs, initialMode: .fullAccess)
        let executor = ToolExecutor(workspace: workspace, permissions: permissions, logs: logs)

        var updates: [ToolExecutionUpdate] = []
        let outcome = await executor.execute(
            ProviderToolCall(
                id: "shell-cap-\(UUID().uuidString.prefix(8))",
                function: .init(
                    name: "shell_execute",
                    arguments: #"{"command":"python3 -c 'print(\"A\" * 40000)'"}"#
                )
            ),
            onUpdate: { updates.append($0) }
        )
        XCTAssertFalse(outcome.isError)
        let terminalUpdate = try XCTUnwrap(updates.last(where: { $0.state == .completed }))
        XCTAssertLessThanOrEqual(terminalUpdate.output.utf8.count, 16_384)
        XCTAssertTrue(terminalUpdate.output.contains("limare-shell-overflow"))
        XCTAssertTrue(terminalUpdate.output.contains("inspect with file_read(offset, limit)"))

        let data = try XCTUnwrap(outcome.content.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if let overflowPath = payload["full_output_path"] as? String {
            try? FileManager.default.removeItem(atPath: overflowPath)
        }
    }

    @MainActor
    func testBuildChatRequestHistoryDeduplicatesFailedShellAndPreservesHookContext() throws {
        let errorJSON = #"{"exit_code":1,"full_output_path":null,"stderr":"compile error here","stdout":""}"#
        let hookSuffix = "\n\n<system-reminder>\nHook diagnostic note\n</system-reminder>"

        var plainFailedShell = ToolCallRecord(
            providerCallID: "call-plain-fail",
            name: "shell_execute",
            input: #"{"command":"false"}"#,
            state: .failed,
            output: "[stderr] compile error here",
            errorMessage: errorJSON
        )
        plainFailedShell.mechanicalTerminalFact = .shell(exitCode: 1, timedOut: false, cancelled: false)

        // Realistic runtime shape: ToolExecutor.withHookContext appends hookSuffix into outcome.content
        // (stored in errorMessage via applyFinalOutcome) AND ConversationRunCoordinator appends it to output.
        var hookedFailedShell = ToolCallRecord(
            providerCallID: "call-hook-fail",
            name: "shell_execute",
            input: #"{"command":"false"}"#,
            state: .failed,
            output: "[stderr] compile error here" + hookSuffix,
            errorMessage: errorJSON + hookSuffix
        )
        hookedFailedShell.mechanicalTerminalFact = .shell(exitCode: 1, timedOut: false, cancelled: false)

        // Legacy/partial shape: hookSuffix present only in output, absent from errorMessage.
        var hookedTimedOutShell = ToolCallRecord(
            providerCallID: "call-hook-timeout",
            name: "shell_execute",
            input: #"{"command":"sleep 5"}"#,
            state: .timedOut,
            output: "[stderr] compile error here" + hookSuffix,
            errorMessage: errorJSON
        )
        hookedTimedOutShell.mechanicalTerminalFact = .shell(exitCode: nil, timedOut: true, cancelled: false)

        var hookedCancelledShell = ToolCallRecord(
            providerCallID: "call-hook-cancel",
            name: "shell_execute",
            input: #"{"command":"sleep 99"}"#,
            state: .cancelled,
            output: "[stderr] compile error here" + hookSuffix,
            errorMessage: errorJSON + hookSuffix
        )
        hookedCancelledShell.mechanicalTerminalFact = .shell(exitCode: nil, timedOut: false, cancelled: true)

        let planCall = ToolCallRecord(
            providerCallID: "call-plan",
            name: "update_plan",
            input: #"{"plan":[{"step":"Fix bug","status":"completed"}]}"#,
            state: .completed,
            output: "- [x] Fix bug\n- [ ] Verify fix\n- [ ] Clean up temporary files and write summary"
        )
        let hookedPlanCall = ToolCallRecord(
            providerCallID: "call-hook-plan",
            name: "update_plan",
            input: #"{"plan":[{"step":"Fix bug","status":"completed"}]}"#,
            state: .completed,
            output: "- [x] Fix bug" + hookSuffix
        )

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            toolCalls: [plainFailedShell, hookedFailedShell, hookedTimedOutShell, hookedCancelledShell, planCall, hookedPlanCall]
        )
        let history = ConversationRunCoordinator.buildChatRequestHistory(
            messages: [ChatMessage(role: .user, content: "run"), assistant],
            systemPrompt: "sys"
        )
        let toolContents = history.compactMap { msg -> String? in
            guard msg.role == "tool" else { return nil }
            return msg.content?.textValue
        }
        XCTAssertEqual(toolContents.count, 6)
        XCTAssertTrue(toolContents[0].contains(errorJSON))
        XCTAssertFalse(toolContents[0].contains("[stderr] compile error here"))

        XCTAssertTrue(toolContents[1].contains(errorJSON))
        XCTAssertFalse(toolContents[1].contains("[stderr] compile error here"))
        XCTAssertEqual(toolContents[1].components(separatedBy: "<system-reminder>").count - 1, 1)

        XCTAssertTrue(toolContents[2].contains(errorJSON))
        XCTAssertFalse(toolContents[2].contains("[stderr] compile error here"))
        XCTAssertEqual(toolContents[2].components(separatedBy: "<system-reminder>").count - 1, 1)

        XCTAssertTrue(toolContents[3].contains("[Tool Execution Cancelled]"))
        XCTAssertFalse(toolContents[3].contains("[stderr] compile error here"))
        XCTAssertEqual(toolContents[3].components(separatedBy: "<system-reminder>").count - 1, 1)

        XCTAssertEqual(toolContents[4], "Plan updated")
        XCTAssertEqual(toolContents[5], "Plan updated" + hookSuffix)

        // Token estimation aligns with projected "Plan updated" instead of raw multi-step checklist,
        // and ContextWorkingSetManager never offloads update_plan into a ~210B stub.
        let longPlanChecklist = (1...12).map { "- [ ] Step \($0): detailed task item for planning" }.joined(separator: "\n")
        let heavyPlanCall = ToolCallRecord(
            providerCallID: "call-heavy-plan",
            name: "update_plan",
            input: #"{"plan":[]}"#,
            state: .completed,
            output: longPlanChecklist
        )
        let heavyReadCall = ToolCallRecord(
            providerCallID: "call-heavy-read",
            name: "file_read",
            input: #"{"path":"a.swift"}"#,
            state: .completed,
            output: String(repeating: "code line\n", count: 120)
        )
        let planMsg = ChatMessage(role: .assistant, content: "", state: .complete, toolCalls: [heavyPlanCall, heavyReadCall], resolvedProviderID: UUID())
        let expectedBytes = heavyPlanCall.name.utf8.count + heavyPlanCall.input.utf8.count + "Plan updated".utf8.count
            + heavyReadCall.name.utf8.count + heavyReadCall.input.utf8.count + heavyReadCall.output.utf8.count
        XCTAssertEqual(
            ContextTokenEstimator.rawMessageContentTokens(planMsg),
            ContextTokenEstimator.rawEstimatedTokens(bytes: expectedBytes) + 12
        )

        let laterUser = ChatMessage(role: .user, content: "next")
        let laterAssistant = ChatMessage(role: .assistant, content: "ok", state: .complete, resolvedProviderID: UUID())
        let reduction = ContextWorkingSetManager.reduceWorkingSet(
            messages: [planMsg, laterUser, laterAssistant],
            systemPrompt: "sys",
            effectiveInputBudget: 250
        )
        let reducedTools = try XCTUnwrap(reduction.workingMessages.first?.toolCalls)
        XCTAssertFalse(reducedTools[0].output.hasPrefix("[TOOL RESULT OFFLOADED]"))
        XCTAssertTrue(reducedTools[1].output.hasPrefix("[TOOL RESULT OFFLOADED]"))
    }
}
