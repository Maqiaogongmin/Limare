import Foundation
import Observation

/// Per-conversation archive of composer drafts, newest first. Each conversation's drafts are one
/// JSON file under `draft-history/v1/`, written atomically before the composer content they
/// protect is replaced, so a retracted message survives switching conversations and relaunching.
/// The archive references attachments but never deletes them; whoever discards a draft decides
/// whether its attachments are still referenced elsewhere. There is no size cap: drafts leave
/// only by an explicit user action, never silently.
@MainActor
@Observable
final class DraftArchiveStore {
    private(set) var draftsByConversation: [UUID: [ArchivedDraft]] = [:]
    let directoryURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logs: DebugLogStore

    init(rootURL: URL, fileManager: FileManager = .default, logs: DebugLogStore) {
        self.directoryURL = rootURL
            .appendingPathComponent("draft-history", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        self.fileManager = fileManager
        self.logs = logs
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        load()
    }

    func drafts(for conversationID: UUID) -> [ArchivedDraft] {
        draftsByConversation[conversationID] ?? []
    }

    func hasDrafts(for conversationID: UUID) -> Bool {
        !(draftsByConversation[conversationID] ?? []).isEmpty
    }

    func draft(id: UUID, conversationID: UUID) -> ArchivedDraft? {
        draftsByConversation[conversationID]?.first(where: { $0.id == id })
    }

    /// Every attachment some archived draft still refers to.
    var referencedAttachmentIDs: Set<UUID> {
        Set(draftsByConversation.values.joined().flatMap { $0.attachments.map(\.id) })
    }

    /// Persists `draft` as the newest entry. Drafts are never evicted automatically: the only
    /// ways out of the archive are the user deleting a draft, sending it, or deleting the
    /// conversation. The in-memory list changes only after the write succeeded.
    func archive(_ draft: ArchivedDraft, conversationID: UUID) throws {
        var list = draftsByConversation[conversationID] ?? []
        list.insert(draft, at: 0)
        try save(list, conversationID: conversationID)
        draftsByConversation[conversationID] = list
    }

    @discardableResult
    func remove(draftID: UUID, conversationID: UUID) throws -> ArchivedDraft? {
        var list = draftsByConversation[conversationID] ?? []
        guard let index = list.firstIndex(where: { $0.id == draftID }) else { return nil }
        let removed = list.remove(at: index)
        try save(list, conversationID: conversationID)
        draftsByConversation[conversationID] = list.isEmpty ? nil : list
        return removed
    }

    /// Drops a conversation's archive, for example when the conversation is deleted.
    @discardableResult
    func removeAll(conversationID: UUID) -> [ArchivedDraft] {
        let removed = draftsByConversation.removeValue(forKey: conversationID) ?? []
        try? fileManager.removeItem(at: fileURL(for: conversationID))
        return removed
    }

    private func fileURL(for conversationID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func save(_ list: [ArchivedDraft], conversationID: UUID) throws {
        let url = fileURL(for: conversationID)
        guard !list.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(list).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func load() {
        guard let files = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let list = try decoder.decode([ArchivedDraft].self, from: Data(contentsOf: file))
                if !list.isEmpty { draftsByConversation[id] = list }
            } catch {
                logs.error("DraftArchive", "Unreadable draft archive '\(file.lastPathComponent)': \(error.localizedDescription)")
            }
        }
    }
}
