import XCTest
@testable import Limare

final class HookExitDecisionTests: XCTestCase {
    func testExitTwoOverridesConflictingAllowForBothEvents() {
        let output = HookProcessOutput(exitCode: 2, stdout: #"{"permissionDecision":"allow","continue":true}"#,
            stderr: "Denied by policy", stdoutDataSize: 46, stderrDataSize: 16,
            isStdoutTruncated: false, isStderrTruncated: false, durationMilliseconds: 1,
            isTimeout: false, isCancelled: false)
        let source = HookSource(name: "fixture", configURL: URL(fileURLWithPath: "/tmp/hooks.json"),
            packageRootURL: URL(fileURLWithPath: "/tmp"), sourceKind: .manualImport,
            isEnabled: true, definitionHash: "fixture", lastLoadedAt: Date(), loadError: nil)
        for event in ["PreToolUse", "UserPromptSubmit"] {
            let result = HookCommandRunner.parseExecutionResult(eventName: event, output: output,
                handler: HookHandlerConfig(type: .command, command: "exit 2"), source: source)
            XCTAssertEqual(result.permissionDecision, "deny")
            XCTAssertEqual(result.permissionDecisionReason, "Denied by policy")
            XCTAssertEqual(result.continueTurn, false)
            XCTAssertEqual(result.stopReason, "Denied by policy")
            XCTAssertNil(result.additionalContext)
        }
    }
}
