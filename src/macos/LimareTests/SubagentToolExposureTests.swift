import XCTest
@testable import Limare

@MainActor
final class SubagentToolExposureTests: XCTestCase {
    func testNativeDefinitionHasRoleAndWaitParameters() throws {
        let definition = HarnessToolDefinitions.nativeDelegateTaskDefinition
        let data = try JSONEncoder().encode(definition)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let function = try XCTUnwrap(root["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let tasks = try XCTUnwrap(properties["tasks"] as? [String: Any])
        let items = try XCTUnwrap(tasks["items"] as? [String: Any])
        let fields = try XCTUnwrap(items["properties"] as? [String: Any])
        XCTAssertNotNil(fields["role"])
        XCTAssertNotNil(properties["wait_seconds"])
        XCTAssertTrue(HarnessToolDefinitions.all.contains { $0.function.name == "delegate_task" })
    }

    func testChildrenNeverReceiveSchedulingTool() {
        for role in [SubagentRole.research, .coding] {
            XCTAssertFalse(SubagentCoordinator.allows("schedule_manage", role: role, allowWeb: true))
            XCTAssertFalse(SubagentCoordinator.allows("schedule_manage", role: role, allowWeb: false))
        }
        XCTAssertTrue(SubagentCoordinator.allows("file_write", role: .coding, allowWeb: false))
    }
}
