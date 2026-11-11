import XCTest
@testable import Limare

@MainActor
final class ConversationForkTests: XCTestCase {
    func testForkPreservesOnlySelectedHistoryAndSharedResourcesAfterSourceDeletionAndReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-fork-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = DebugLogStore()
        let persistence = ConversationPersistence(storageRootURL: root, logs: logs)
        let attachments = AttachmentStore(storageRootURL: root)
        let artifacts = try ArtifactStore(storageRootURL: root)
        let store = ConversationStore(persistence: persistence, logs: logs, attachmentStore: attachments, artifactStore: artifacts)
        let source = store.newConversation(modelSource: .direct(providerID: UUID(), modelID: "model"))
        store.renameConversation(id: source.id, title: "Original")
        let file = root.appendingPathComponent("input.txt")
        try Data("attachment".utf8).write(to: file)
        let attachment = try attachments.saveFile(url: file)
        let artifact = try artifacts.save(data: Data("artifact".utf8), conversationID: source.id, filename: "result.txt", mimeType: "text/plain")
        let futureArtifact = try artifacts.save(data: Data("later".utf8), conversationID: source.id, filename: "later.txt", mimeType: "text/plain")
        let user = ChatMessage(role: .user, content: "question", attachments: [attachment])
        let call = ToolCallRecord(providerCallID: "call", name: "artifact_register", input: "{}", state: .completed,
                                  resultParts: [.artifact(id: artifact.artifactID, semanticRole: .deliverable, mimeType: "text/plain")])
        let answer = ChatMessage(role: .assistant, content: "answer", toolCalls: [call])
        let later = ChatMessage(role: .user, content: "later")
        try store.commitDurableMessages(id: source.id, messages: [user, answer, later])
        let originalDirectory = store.effectiveWorkingDirectory(for: source.id)
        try Data("workspace".utf8).write(to: originalDirectory.appendingPathComponent("state.txt"))

        let fork = try store.forkConversation(id: source.id, through: answer.id)
        XCTAssertEqual(fork.messages.map(\.id), [user.id, answer.id])
        XCTAssertEqual(fork.title, "Original (分支)")
        XCTAssertEqual(fork.forkParentConversationID, source.id)
        XCTAssertEqual(fork.forkPointMessageID, answer.id)
        XCTAssertEqual(fork.effectiveModelSource, source.effectiveModelSource)
        XCTAssertTrue(fork.compactionMarkers.isEmpty)
        XCTAssertEqual(store.effectiveWorkingDirectory(for: fork.id), originalDirectory)
        XCTAssertNoThrow(try artifacts.resolveFileURL(artifactID: artifact.artifactID, conversationID: fork.id))
        XCTAssertThrowsError(try artifacts.resolveFileURL(artifactID: futureArtifact.artifactID, conversationID: fork.id))
        XCTAssertThrowsError(try artifacts.resolveFileURL(artifactID: artifact.artifactID, conversationID: UUID()))
        store.deleteConversation(id: source.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try attachments.fileURL(for: attachment).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalDirectory.appendingPathComponent("state.txt").path))
        let reopenedArtifacts = try ArtifactStore(storageRootURL: root)
        let reopened = ConversationStore(persistence: persistence, logs: logs, attachmentStore: attachments, artifactStore: reopenedArtifacts)
        let loaded = try XCTUnwrap(reopened.conversations.first { $0.id == fork.id })
        XCTAssertEqual(loaded.forkParentConversationID, source.id)
        XCTAssertEqual(loaded.messages.map(\.id), [user.id, answer.id])
        XCTAssertNoThrow(try reopenedArtifacts.resolveFileURL(artifactID: artifact.artifactID, conversationID: fork.id))
    }

    func testIncompletePrefixCannotBeForked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-fork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = DebugLogStore()
        let store = ConversationStore(persistence: ConversationPersistence(storageRootURL: root, logs: logs), logs: logs)
        let source = store.newConversation()
        let streaming = ChatMessage(role: .assistant, content: "partial", state: .streaming)
        try store.commitDurableMessages(id: source.id, messages: [streaming])
        XCTAssertThrowsError(try store.forkConversation(id: source.id, through: streaming.id))
    }

    func testOptionalWorktreeStartsFromCommitAndCannotRemoveSharedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-fork-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments)")
        }
        try git(["init"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["config", "user.name", "Test"])
        let file = repo.appendingPathComponent("file.txt")
        try Data("committed".utf8).write(to: file)
        try git(["add", "file.txt"])
        try git(["commit", "-m", "base"])
        try Data("uncommitted".utf8).write(to: file)
        let app = AppState(storageRootURL: root.appendingPathComponent("app"))
        let source = app.conversations.newConversation(workspace: .from(url: repo))
        let message = ChatMessage(role: .user, content: "branch")
        try app.conversations.commitDurableMessages(id: source.id, messages: [message])
        let fork = try app.conversations.forkConversation(id: source.id, through: message.id)
        try await app.worktrees.create(conversationID: fork.id, baseBranch: nil)
        let worktree = try XCTUnwrap(app.conversations.conversations.first { $0.id == fork.id }?.worktree)
        XCTAssertEqual(try String(contentsOf: worktree.workspace.url.appendingPathComponent("file.txt"), encoding: .utf8), "committed")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "uncommitted")
        let child = try app.conversations.forkConversation(id: fork.id, through: message.id)
        XCTAssertEqual(app.conversations.effectiveWorkingDirectory(for: child.id), worktree.workspace.url)
        do {
            try await app.worktrees.remove(conversationID: fork.id, keepFolder: false)
            XCTFail("Removing a worktree still used by a fork must fail")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.workspace.url.path))
    }
}
