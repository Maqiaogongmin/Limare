import XCTest
@testable import Limare

@MainActor
final class ConversationPresentationTests: XCTestCase {
    func testForkOnlyOffersCompletedConversationMessagesWhenRunIsIdle() {
        let user = ChatMessage(role: .user, content: "开始")
        let call = ToolCallRecord(providerCallID: "call", name: "shell_execute", input: "{}", state: .completed)
        let step = ChatMessage(role: .assistant, content: "处理中", toolCalls: [call])
        let answer = ChatMessage(role: .assistant, content: "完成")
        let messages = [user, step, answer]
        let userRow = TranscriptRow(message: user, in: messages)
        let stepRow = TranscriptRow(message: step, in: messages)
        let answerRow = TranscriptRow(message: answer, in: messages)
        XCTAssertFalse(userRow.canFork(allowsFork: false, isDelegationChild: false))
        XCTAssertFalse(answerRow.canFork(allowsFork: false, isDelegationChild: false))
        XCTAssertFalse(stepRow.canFork(allowsFork: true, isDelegationChild: false))
        XCTAssertTrue(userRow.canFork(allowsFork: true, isDelegationChild: false))
        XCTAssertTrue(answerRow.canFork(allowsFork: true, isDelegationChild: false))
        XCTAssertFalse(answerRow.canFork(allowsFork: true, isDelegationChild: true))
    }

    func testCurrentPlanFollowsUpdatesAndSurvivesSteer() {
        func call(_ status: String) -> ToolCallRecord {
            ToolCallRecord(providerCallID: UUID().uuidString, name: "update_plan",
                           input: "{\"plan\":[{\"step\":\"检查\",\"status\":\"\(status)\"}]}", state: .completed)
        }
        let first = ChatMessage(role: .assistant, content: "", toolCalls: [call("in_progress")])
        var steer = ChatMessage(role: .user, content: "继续")
        steer.sentWhileWorking = true
        let final = ChatMessage(role: .assistant, content: "", toolCalls: [call("completed")])
        let messages = [ChatMessage(role: .user, content: "开始"), first, steer, final]
        XCTAssertEqual(TranscriptTurnGrouping.currentPlan(in: messages).first?.status, .completed)
        XCTAssertEqual(TranscriptTurnGrouping.currentPlan(in: Array(messages.dropLast())).first?.status, .inProgress)
        XCTAssertTrue(TranscriptTurnGrouping.currentPlan(in: messages + [ChatMessage(role: .user, content: "新任务")]).isEmpty)
    }

    func testFinalPlanIsFoldedWhenRunStopsOrCompletes() {
        let plan = ToolCallRecord(providerCallID: "plan", name: "update_plan", input: "{}", state: .interrupted)
        let other = ToolCallRecord(providerCallID: "shell", name: "shell_execute", input: "{}", state: .interrupted)
        let message = ChatMessage(role: .assistant, content: "", state: .interrupted, toolCalls: [plan, other])
        XCTAssertEqual(TranscriptTurnGrouping.finishedPlanCalls(in: message, isCurrentRun: false).map(\.id), [plan.id])
        XCTAssertTrue(TranscriptTurnGrouping.finishedPlanCalls(in: message, isCurrentRun: true).isEmpty)
        let remote = ToolCallRecord(providerCallID: "mcp", name: "mcp__example__update_plan", input: "{}", state: .completed)
        XCTAssertFalse(TranscriptTurnGrouping.isPlanTool(remote))
    }
}
