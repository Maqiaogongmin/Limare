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
}
