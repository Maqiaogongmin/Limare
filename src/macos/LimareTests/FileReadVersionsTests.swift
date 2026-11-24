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

    func testFileReadDefaultWindowIs24KiBAndAttachmentSupportsPaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DebugLogStore(storageRootURL: directory, osLogProjection: { _, _, _ in })
        let attachments = AttachmentStore(storageRootURL: directory)
        let workspace = WorkspaceStore(persistence: .runScoped, logs: logs)
        try workspace.setWorkspace(directory)
        let permissions = PermissionStore(logs: logs, initialMode: .fullAccess)
        let executor = ToolExecutor(workspace: workspace, permissions: permissions, logs: logs, attachmentStore: attachments)

        let lines = (1...800).map { String(format: "line-%04d: %@", $0, String(repeating: "x", count: 50)) }
        let largeContent = lines.joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(largeContent.utf8.count, 40_000)
        let targetFile = directory.appendingPathComponent("numbered.txt")
        try largeContent.write(to: targetFile, atomically: true, encoding: .utf8)

        let defaultRead = await executor.execute(
            ProviderToolCall(id: "r1", function: .init(name: "file_read", arguments: #"{"path":"numbered.txt"}"#)),
            onUpdate: { _ in }
        )
        XCTAssertFalse(defaultRead.isError)
        XCTAssertLessThanOrEqual(defaultRead.content.utf8.count, 24_800)
        XCTAssertGreaterThan(defaultRead.content.utf8.count, 16_384)
        XCTAssertTrue(defaultRead.content.contains("continue with offset"))
        XCTAssertFalse(defaultRead.content.contains("line-0800:"))

        // offset alone keeps the 24 KiB window; passing limit allows up to 64 KiB.
        let offsetOnlyRead = await executor.execute(
            ProviderToolCall(id: "r1b", function: .init(name: "file_read", arguments: #"{"path":"numbered.txt","offset":100}"#)),
            onUpdate: { _ in }
        )
        XCTAssertFalse(offsetOnlyRead.isError)
        XCTAssertLessThanOrEqual(offsetOnlyRead.content.utf8.count, 24_800)
        XCTAssertTrue(offsetOnlyRead.content.contains("line-0100:"))
        XCTAssertTrue(offsetOnlyRead.content.contains("continue with offset"))

        let explicitRangeRead = await executor.execute(
            ProviderToolCall(id: "r2", function: .init(name: "file_read", arguments: #"{"path":"numbered.txt","offset":100,"limit":750}"#)),
            onUpdate: { _ in }
        )
        XCTAssertFalse(explicitRangeRead.isError)
        XCTAssertGreaterThan(explicitRangeRead.content.utf8.count, 25_000)
        XCTAssertTrue(explicitRangeRead.content.contains("line-0800:"))

        // Attachment URI supports offset/limit paging with matching byte caps.
        let storedAttachment = try attachments.saveFile(url: targetFile)
        let attachmentURI = AttachmentReferenceFormatter.uri(for: storedAttachment)
        let attPage1 = await executor.execute(
            ProviderToolCall(id: "a1", function: .init(name: "file_read", arguments: #"{"path":"\#(attachmentURI)"}"#)),
            onUpdate: { _ in }
        )
        XCTAssertFalse(attPage1.isError)
        XCTAssertLessThanOrEqual(attPage1.content.utf8.count, 24_800)
        XCTAssertTrue(attPage1.content.contains("continue with offset"))

        let attPage2 = await executor.execute(
            ProviderToolCall(id: "a2", function: .init(name: "file_read", arguments: #"{"path":"\#(attachmentURI)","offset":750,"limit":60}"#)),
            onUpdate: { _ in }
        )
        XCTAssertFalse(attPage2.isError)
        XCTAssertTrue(attPage2.content.contains("line-0750:"))
        XCTAssertTrue(attPage2.content.contains("line-0800:"))

        // Version hash recorded full file despite truncated default read, so external change is still caught.
        try (largeContent + "tampered\n").write(to: targetFile, atomically: true, encoding: .utf8)
        let staleEdit = await executor.execute(
            ProviderToolCall(id: "e1", function: .init(name: "file_edit", arguments: #"{"path":"numbered.txt","old_text":"line-0001:","new_text":"LINE-0001:"}"#)),
            onUpdate: { _ in }
        )
        XCTAssertTrue(staleEdit.isError)
        XCTAssertTrue(staleEdit.content.contains("changed since"))
    }

    func testFileEditBatchHunksAndReplaceAllAreAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logs = DebugLogStore(storageRootURL: directory, osLogProjection: { _, _, _ in })
        let workspace = WorkspaceStore(persistence: .runScoped, logs: logs)
        try workspace.setWorkspace(directory)
        let permissions = PermissionStore(logs: logs, initialMode: .fullAccess)
        let executor = ToolExecutor(workspace: workspace, permissions: permissions, logs: logs)

        let file = directory.appendingPathComponent("batch.swift")
        let initial = "let alpha = 1\nlet tag = \"old\"\nlet tag2 = \"old\"\nlet beta = 2\n"
        _ = await executor.execute(
            ProviderToolCall(id: "w1", function: .init(name: "file_write", arguments: #"{"path":"batch.swift","content":"let alpha = 1\nlet tag = \"old\"\nlet tag2 = \"old\"\nlet beta = 2\n"}"#)),
            onUpdate: { _ in }
        )

        // Failed second hunk must leave disk untouched.
        let failedBatch = await executor.execute(
            ProviderToolCall(
                id: "e-fail",
                function: .init(
                    name: "file_edit",
                    arguments: #"{"path":"batch.swift","edits":[{"old_text":"let alpha = 1","new_text":"let alpha = 10"},{"old_text":"MISSING","new_text":"X"}]}"#
                )
            ),
            onUpdate: { _ in }
        )
        XCTAssertTrue(failedBatch.isError)
        XCTAssertTrue(failedBatch.content.contains("hunk #2"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), initial)

        // Partial top-level old_text without new_text reports clear diagnostic.
        let partialCall = await executor.execute(
            ProviderToolCall(
                id: "e-partial",
                function: .init(name: "file_edit", arguments: #"{"path":"batch.swift","old_text":"let alpha = 1"}"#)
            ),
            onUpdate: { _ in }
        )
        XCTAssertTrue(partialCall.isError)
        XCTAssertTrue(partialCall.content.contains("only one of old_text or new_text"))

        // Non-unique match hints replace_all: true.
        let nonUnique = await executor.execute(
            ProviderToolCall(
                id: "e-nonunique",
                function: .init(name: "file_edit", arguments: #"{"path":"batch.swift","old_text":"\"old\"","new_text":"\"new\""}"#)
            ),
            onUpdate: { _ in }
        )
        XCTAssertTrue(nonUnique.isError)
        XCTAssertTrue(nonUnique.content.contains("replace_all: true"))

        // Top-level replace_all propagates to edits hunks that omit per-hunk replace_all.
        let okBatch = await executor.execute(
            ProviderToolCall(
                id: "e-ok",
                function: .init(
                    name: "file_edit",
                    arguments: #"{"path":"batch.swift","replace_all":true,"edits":[{"old_text":"let alpha = 1","new_text":"let alpha = 10"},{"old_text":"\"old\"","new_text":"\"new\""},{"old_text":"let beta = 2","new_text":"let beta = 20"}]}"#
                )
            ),
            onUpdate: { _ in }
        )
        XCTAssertFalse(okBatch.isError)
        XCTAssertTrue(okBatch.content.contains("4 replacements"))
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "let alpha = 10\nlet tag = \"new\"\nlet tag2 = \"new\"\nlet beta = 20\n"
        )
    }

    func testResearchFileServicePerFileCapAndTruncationMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let noisyLines = (1...35).map { "match line \($0)" }.joined(separator: "\n")
        try noisyLines.write(to: directory.appendingPathComponent("a_noisy.txt"), atomically: true, encoding: .utf8)
        try "match line in second file\n".write(to: directory.appendingPathComponent("b_second.txt"), atomically: true, encoding: .utf8)

        let service = ResearchFileService()
        let dirResult = try service.searchFilesWithMetadata(in: directory, query: "match", maxResults: 30)
        XCTAssertEqual(dirResult.perFileTruncatedFiles, 1)
        XCTAssertFalse(dirResult.truncated)
        let paths = Set(dirResult.results.compactMap { $0["path"] as? String })
        XCTAssertTrue(paths.contains("a_noisy.txt"))
        XCTAssertTrue(paths.contains("b_second.txt"))

        let singleFileResult = try service.searchFilesWithMetadata(in: directory, query: "match", subpath: "a_noisy.txt", maxResults: 30)
        XCTAssertEqual(singleFileResult.results.count, 30)
        XCTAssertTrue(singleFileResult.truncated)
        XCTAssertEqual(singleFileResult.perFileTruncatedFiles, 0)

        let listTruncated = try service.listFilesWithMetadata(in: directory, maxEntries: 1)
        XCTAssertEqual(listTruncated.entries.count, 1)
        XCTAssertTrue(listTruncated.truncated)

        let listExact = try service.listFilesWithMetadata(in: directory, maxEntries: 2)
        XCTAssertEqual(listExact.entries.count, 2)
        XCTAssertFalse(listExact.truncated)

        // Multi-file maxResults stops cleanly at outer boundary and flags truncated when more files exist.
        try "match line 1\nmatch line 2\nmatch line 3\n".write(to: directory.appendingPathComponent("a_exact2.txt"), atomically: true, encoding: .utf8)
        let exactLimitDir = try service.searchFilesWithMetadata(in: directory, query: "match", maxResults: 2)
        XCTAssertEqual(exactLimitDir.results.count, 2)
        XCTAssertTrue(exactLimitDir.truncated)

        // Output byte cap protects multi-byte CJK matches cleanly.
        let cjkDir = directory.appendingPathComponent("cjk")
        try FileManager.default.createDirectory(at: cjkDir, withIntermediateDirectories: true)
        for i in 1...8 {
            let content = (1...20).map { "中文命中行_\(i)_\($0)_" + String(repeating: "测", count: 80) }.joined(separator: "\n")
            try content.write(to: cjkDir.appendingPathComponent("doc_\(i).txt"), atomically: true, encoding: .utf8)
        }
        let cjkSearch = try service.searchFilesWithMetadata(in: directory, query: "中文命中", subpath: "cjk", maxResults: 100)
        XCTAssertTrue(cjkSearch.truncated)
        XCTAssertLessThan(cjkSearch.results.count, 100)

        // Cancelled task propagates CancellationError.
        let cancelledTask = Task { () throws -> Int in
            withUnsafeCurrentTask { _ in }
            return try service.searchFilesWithMetadata(in: directory, query: "match", maxResults: 100).results.count
        }
        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected CancellationError when parent task is cancelled")
        } catch is CancellationError {
            // Expected
        }
    }
}
