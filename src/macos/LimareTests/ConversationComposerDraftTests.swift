import Foundation
import XCTest
@testable import Limare

@MainActor
final class ConversationComposerDraftTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-composer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func conversation(_ app: AppState, _ text: String) throws -> ConversationRecord {
        let record = app.conversations.newConversation()
        try app.conversations.commitDurableMessages(id: record.id, messages: [ChatMessage(role: .user, content: text)])
        return record
    }

    func testSwitchRestoresDraftAndAttachmentsWithoutCreatingHistory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        let source = root.appendingPathComponent("attachment.txt")
        try Data("file".utf8).write(to: source)
        let attachment = try app.attachments.saveFile(url: source)

        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "第一段草稿"
        try app.chat.addAttachment(attachment)
        app.conversations.selectConversation(id: second.id)
        XCTAssertTrue(app.chat.draft.isEmpty)
        app.chat.draft = "第二段草稿"
        app.conversations.selectConversation(id: first.id)
        XCTAssertEqual(app.chat.draft, "第一段草稿")
        XCTAssertEqual(app.chat.pendingAttachments.map(\.id), [attachment.id])
        XCTAssertTrue(app.chat.recoverableHistoricalDrafts.isEmpty)

        app.chat.draft = "编辑后的草稿"
        app.conversations.selectConversation(id: second.id)
        XCTAssertEqual(app.chat.draft, "第二段草稿")
        app.conversations.selectConversation(id: first.id)
        XCTAssertEqual(app.chat.draft, "编辑后的草稿")
        XCTAssertTrue(app.chat.recoverableHistoricalDrafts.isEmpty)
        XCTAssertEqual(app.draftArchive.drafts(for: first.id).count, 1)
    }

    func testDraftSurvivesRelaunchAndClearingDoesNotRestoreOldText() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "保留的草稿"
        app.conversations.selectConversation(id: second.id)

        let relaunched = AppState(storageRootURL: root)
        relaunched.conversations.selectConversation(id: first.id)
        XCTAssertEqual(relaunched.chat.draft, "保留的草稿")
        relaunched.chat.draft = ""
        relaunched.conversations.selectConversation(id: second.id)
        relaunched.conversations.selectConversation(id: first.id)
        XCTAssertTrue(relaunched.chat.draft.isEmpty)
        XCTAssertNil(relaunched.draftArchive.currentDraft(for: first.id))
    }

    func testLegacyLatestDraftIsRestoredAndOlderDraftRemainsAccessible() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        let latest = ArchivedDraft(text: "最近的草稿", attachments: [], origin: .composerDraft)
        let older = ArchivedDraft(text: "更早的草稿", attachments: [], origin: .composerDraft)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([latest, older]).write(to: app.draftArchive.directoryURL.appendingPathComponent("\(first.id.uuidString).json"))

        let upgraded = AppState(storageRootURL: root)
        upgraded.conversations.selectConversation(id: first.id)
        XCTAssertEqual(upgraded.chat.draft, latest.text)
        XCTAssertEqual(upgraded.chat.recoverableHistoricalDrafts.map(\.id), [older.id])
        upgraded.conversations.selectConversation(id: second.id)
        upgraded.conversations.selectConversation(id: first.id)
        XCTAssertEqual(upgraded.chat.draft, latest.text)
        XCTAssertEqual(upgraded.chat.recoverableHistoricalDrafts.map(\.id), [older.id])
    }

    func testDifferentWindowsDoNotOverwriteAnotherWindowsDraft() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftArchiveStore(rootURL: root, logs: DebugLogStore())
        let id = UUID()
        let original = ArchivedDraft(text: "original", attachments: [], origin: .composerDraft)
        try store.saveCurrentDraft(original, previouslyRestoredID: nil, conversationID: id)
        let first = ArchivedDraft(text: "window one", attachments: [], origin: .composerDraft)
        let second = ArchivedDraft(text: "window two", attachments: [], origin: .composerDraft)
        try store.saveCurrentDraft(first, previouslyRestoredID: original.id, conversationID: id)
        try store.saveCurrentDraft(second, previouslyRestoredID: original.id, conversationID: id)
        XCTAssertEqual(store.currentDraft(for: id)?.text, "window two")
        XCTAssertTrue(store.drafts(for: id).contains { $0.text == "window one" })
        try store.saveCurrentDraft(nil, previouslyRestoredID: first.id, conversationID: id)
        XCTAssertEqual(store.currentDraft(for: id)?.text, "window two")
    }

    func testSendingRestoredDraftDoesNotBringItBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "要发送的草稿"
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        app.conversations.setConversationModelSource(id: first.id, source: .direct(providerID: UUID(), modelID: "test"))
        app.conversationRuns.testInjectActiveRun(first.id, run: ConversationRun(conversationID: first.id, status: .running))
        app.chat.queue()
        XCTAssertTrue(app.chat.draft.isEmpty)
        XCTAssertNil(app.draftArchive.currentDraft(for: first.id))
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertTrue(app.chat.draft.isEmpty)
    }

    func testFailedSaveKeepsDraftInMemoryUntilSwitchBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "不能丢失"
        let directory = app.draftArchive.directoryURL
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        app.conversations.selectConversation(id: second.id)
        XCTAssertNotNil(app.chat.errorMessage)
        app.conversations.selectConversation(id: first.id)
        XCTAssertEqual(app.chat.draft, "不能丢失")
    }

    func testAppReplacementPreservesThePreviousRestoredDraft() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "原来的草稿"
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertTrue(app.chat.replaceComposerText("新准备的内容"))
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertEqual(app.chat.draft, "新准备的内容")
        XCTAssertTrue(app.chat.recoverableHistoricalDrafts.contains { $0.text == "原来的草稿" })
    }

    func testSendingReplacementDoesNotReactivateDisplacedDraft() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "原草稿"
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertTrue(app.chat.replaceComposerText("发送这段"))
        app.conversations.setConversationModelSource(id: first.id, source: .direct(providerID: UUID(), modelID: "test"))
        app.conversationRuns.testInjectActiveRun(first.id, run: ConversationRun(conversationID: first.id, status: .running))
        app.chat.queue()
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertTrue(app.chat.draft.isEmpty)
        XCTAssertTrue(app.chat.recoverableHistoricalDrafts.contains { $0.text == "原草稿" })
    }

    func testRestoringHistoryChangesCurrentDraftBeforeSending() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState(storageRootURL: root)
        let first = try conversation(app, "first")
        let second = try conversation(app, "second")
        app.conversations.selectConversation(id: first.id)
        app.chat.draft = "当前草稿"
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        let old = ArchivedDraft(text: "历史草稿", attachments: [], origin: .composerDraft)
        try app.draftArchive.archive(old, conversationID: first.id)
        XCTAssertTrue(app.chat.restoreArchivedDraft(old.id))
        XCTAssertEqual(app.draftArchive.currentDraft(for: first.id)?.id, old.id)
        app.conversations.setConversationModelSource(id: first.id, source: .direct(providerID: UUID(), modelID: "test"))
        app.conversationRuns.testInjectActiveRun(first.id, run: ConversationRun(conversationID: first.id, status: .running))
        app.chat.queue()
        app.conversations.selectConversation(id: second.id)
        app.conversations.selectConversation(id: first.id)
        XCTAssertTrue(app.chat.draft.isEmpty)
        XCTAssertTrue(app.chat.recoverableHistoricalDrafts.contains { $0.text == "当前草稿" })
    }
}
