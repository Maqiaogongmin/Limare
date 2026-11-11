import XCTest
@testable import Limare

@MainActor
final class FileReadVersionsTests: XCTestCase {
    func testFileToolsRejectStaleEditsAndAllowNewFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DebugLogStore(storageRootURL: directory, osLogProjection: { _, _, _ in })
        let workspace = WorkspaceStore(persistence: .runScoped, logs: logs)
        try workspace.setWorkspace(directory)
        let permissions = PermissionStore(logs: logs, initialMode: .fullAccess)
        let executor = ToolExecutor(workspace: workspace, permissions: permissions, logs: logs)
        func call(_ name: String, _ arguments: String) async -> ToolExecutionOutcome {
            await executor.execute(ProviderToolCall(id: UUID().uuidString, function: .init(name: name, arguments: arguments)), onUpdate: { _ in })
        }
        let created = await call("file_write", #"{"path":"new.txt","content":"initial"}"#)
        XCTAssertFalse(created.isError)
        let normal = await call("file_edit", #"{"path":"new.txt","old_text":"initial","new_text":"edited"}"#)
        XCTAssertFalse(normal.isError)
        try "external".write(to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let staleEdit = await call("file_edit", #"{"path":"new.txt","old_text":"external","new_text":"lost"}"#)
        XCTAssertTrue(staleEdit.isError)
        XCTAssertTrue(staleEdit.content.contains("changed since"))
        let staleWrite = await call("file_write", #"{"path":"new.txt","content":"lost"}"#)
        XCTAssertTrue(staleWrite.isError)
        let read = await call("file_read", #"{"path":"new.txt"}"#)
        XCTAssertFalse(read.isError)
        let fresh = await call("file_write", #"{"path":"new.txt","content":"fresh"}"#)
        XCTAssertFalse(fresh.isError)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8), "fresh")
    }

    func testVersionsAreScopedAndDetectExternalChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.txt")
        let versions = FileReadVersions()
        let first = UUID(), second = UUID()
        XCTAssertNoThrow(try versions.requireCurrent(at: file, conversationID: first))
        try "original".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try versions.requireCurrent(at: file, conversationID: first))
        versions.record("original", at: file, conversationID: first)
        XCTAssertNoThrow(try versions.requireCurrent(at: file, conversationID: first))
        XCTAssertThrowsError(try versions.requireCurrent(at: file, conversationID: second))
        try "external".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try versions.requireCurrent(at: file, conversationID: first))
        versions.record("external", at: file, conversationID: first)
        XCTAssertNoThrow(try versions.requireCurrent(at: file, conversationID: first))
    }
}
