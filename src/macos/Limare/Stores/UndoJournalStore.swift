import Foundation
import Observation

/// Durable record of every project change undo can restore, the backups behind it, and the
/// restore plans in flight. One journal file per conversation under `undo/v1/journals/`,
/// content-addressed backups under `undo/v1/blobs/`, open plans under `undo/v1/plans/`.
///
/// Write protocol for a recorded change: back up the before-state and persist a `pending`
/// record, then write the file, then persist the after-state as `applied`. A crash at any point
/// leaves either no record, a pending record that startup resolves by looking at the file, or
/// a complete record.
@MainActor
@Observable
final class UndoJournalStore {
    nonisolated static let defaultCapacityBytes: Int64 = 2 * 1024 * 1024 * 1024

    private(set) var journals: [UUID: UndoJournalSnapshot] = [:]
    private(set) var plans: [UUID: UndoRestorePlan] = [:]
    private(set) var delegationOwners: [UUID: UndoDelegationOwner] = [:]
    private(set) var backupBytes: Int64 = 0

    @ObservationIgnored let rootURL: URL
    @ObservationIgnored let blobs: UndoBlobStore
    @ObservationIgnored var capacityBytes: Int64
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private var blobSizes: [String: Int64] = [:]
    /// Fault injection for tests: called before each journal or plan write.
    @ObservationIgnored var onWillPersist: ((String) throws -> Void)?
    private var journalsURL: URL { rootURL.appendingPathComponent("journals", isDirectory: true) }
    private var plansURL: URL { rootURL.appendingPathComponent("plans", isDirectory: true) }
    private var ownersURL: URL { rootURL.appendingPathComponent("delegation-owners.json") }

    init(storageRootURL: URL, logs: DebugLogStore, capacityBytes: Int64 = UndoJournalStore.defaultCapacityBytes, maximumBackupFileBytes: Int64 = 512 * 1024 * 1024) {
        self.rootURL = storageRootURL.appendingPathComponent("undo", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
        self.logs = logs
        self.capacityBytes = capacityBytes
        self.blobs = UndoBlobStore(rootURL: rootURL, maximumBackupFileBytes: maximumBackupFileBytes)
        for url in [journalsURL, plansURL] {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        load()
    }

    // MARK: - Queries

    func records(for conversationID: UUID) -> [UndoChangeRecord] {
        journals[conversationID]?.records ?? []
    }

    func record(id: UUID, conversationID: UUID) -> UndoChangeRecord? {
        journals[conversationID]?.records.first(where: { $0.id == id })
    }

    func openPlan(for conversationID: UUID) -> UndoRestorePlan? {
        plans.values.filter { $0.conversationID == conversationID && $0.isOpen }.min(by: { $0.createdAt < $1.createdAt })
    }

    func delegationOwner(taskID: UUID) -> UndoDelegationOwner? { delegationOwners[taskID] }

    // MARK: - Recording

    /// Backs up `path` and persists a pending record. Throws when the backup cannot be made;
    /// the caller must then not write the file.
    func beginChange(
        conversationID: UUID, ownerMessageID: UUID, runID: UUID?, segment: Int? = nil,
        channel: UndoChangeChannel, source: String, toolCallID: String? = nil, path: String, location: AnchoredPath? = nil, workspaceRoot: String?
    ) throws -> UUID {
        let location = location ?? workspaceRoot.flatMap { AnchoredPath(path: path, under: $0) } ?? .atParent(of: path)
        let before = try blobs.captureState(at: location, backup: true)
        let createdDirectories = UndoBlobStore.missingAncestors(of: path, stoppingAt: workspaceRoot)
        // No file content is written until the complete parent identity is durable.
        let preparedLocation = try AnchoredFileSystem.prepareParents(location)
        var journal = journals[conversationID] ?? UndoJournalSnapshot()
        let now = Date()
        let record = UndoChangeRecord(
            id: UUID(), sequence: journal.nextSequence, conversationID: conversationID,
            ownerMessageID: ownerMessageID, runID: runID, segment: segment, channel: channel, source: source,
            toolCallID: toolCallID, path: path, anchor: location.root, recordedLocation: preparedLocation, before: before, after: nil,
            createdDirectories: createdDirectories,
            status: .pending, isUncertain: false, createdAt: now, updatedAt: now)
        journal.nextSequence += 1
        journal.records.append(record)
        do {
            try persist(journal, conversationID: conversationID)
        } catch {
            if let blob = before.blob, !isBlobReferenced(blob, excluding: record.id) { blobs.delete(blob) }
            throw error
        }
        journals[conversationID] = journal
        account(before.blob)
        CrashInjection.point("journal.afterBegin")
        return record.id
    }

    /// The write happened: record what it left behind.
    func completeChange(_ id: UUID, conversationID: UUID) {
        guard var journal = journals[conversationID],
              let index = journal.records.firstIndex(where: { $0.id == id }) else { return }
        let after = (try? blobs.captureState(at: journal.records[index].location, backup: false)) ?? .other(kind: "unreadable")
        journal.records[index].after = after
        journal.records[index].status = .applied
        journal.records[index].updatedAt = Date()
        let unchanged = after.sameState(as: journal.records[index].before)
        if unchanged {
            // A write that changed nothing needs no undo; the record stays as evidence that
            // the tool call was seen, without holding a backup.
            journal.records[index].status = .discarded
        }
        save(journal, conversationID: conversationID)
        if unchanged { collectUnreferencedBlobs() }
        enforceCapacity()
    }

    /// The write failed. If the file is untouched the record goes away; if it changed anyway,
    /// the record stays so the partial change can still be undone.
    func abandonChange(_ id: UUID, conversationID: UUID) {
        guard let journal = journals[conversationID],
              let record = journal.records.first(where: { $0.id == id }) else { return }
        let current = (try? blobs.captureState(at: record.location, backup: false)) ?? .other(kind: "unreadable")
        if current.sameState(as: record.before) {
            removeRecords([id], conversationID: conversationID)
        } else {
            completeChange(id, conversationID: conversationID)
        }
    }

    func setStatus(_ status: UndoChangeRecord.Status, for ids: Set<UUID>, conversationID: UUID) throws {
        guard var journal = journals[conversationID] else { return }
        var changed = false
        for index in journal.records.indices where ids.contains(journal.records[index].id) {
            journal.records[index].status = status
            journal.records[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        try persist(journal, conversationID: conversationID)
        journals[conversationID] = journal
        collectUnreferencedBlobs()
    }

    func registerDelegationOwner(_ owner: UndoDelegationOwner) {
        guard delegationOwners[owner.taskID] != owner else { return }
        delegationOwners[owner.taskID] = owner
        saveOwners()
    }

    /// Drops everything recorded for a deleted conversation.
    func removeAll(conversationID: UUID) {
        journals.removeValue(forKey: conversationID)
        try? fileManager.removeItem(at: journalURL(for: conversationID))
        for plan in plans.values where plan.conversationID == conversationID {
            plans.removeValue(forKey: plan.id)
            try? fileManager.removeItem(at: planURL(for: plan.id))
        }
        let owners = delegationOwners.filter { $0.value.parentConversationID == conversationID }.map(\.key)
        if !owners.isEmpty {
            owners.forEach { delegationOwners.removeValue(forKey: $0) }
            saveOwners()
        }
        collectUnreferencedBlobs()
    }

    // MARK: - Plans

    func savePlan(_ plan: UndoRestorePlan) throws {
        var updated = plan
        updated.updatedAt = Date()
        try onWillPersist?("plan")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: planURL(for: plan.id), options: .atomic)
        plans[plan.id] = updated
        for step in updated.steps { account(step.replaced?.blob) }
    }

    /// Closes a finished plan and releases the backups only it held. The caller saved the plan
    /// in a closed phase first, so a plan file that cannot be removed still reads as closed.
    func closePlan(_ id: UUID) {
        plans.removeValue(forKey: id)
        try? fileManager.removeItem(at: planURL(for: id))
        collectUnreferencedBlobs()
    }

    // MARK: - Startup

    /// Resolves records left pending by a crash, drops staging leftovers and unreferenced
    /// backups. Plans are reconciled by `UndoCoordinator`.
    func reconcileStartup() {
        blobs.removeIncomingLeftovers()
        for (conversationID, journal) in journals {
            for record in journal.records where record.status == .pending {
                abandonChange(record.id, conversationID: conversationID)
            }
        }
        collectUnreferencedBlobs()
        enforceCapacity()
    }

    // MARK: - Capacity

    /// Evicts the backups whose newest use is oldest until the store fits its capacity. Records
    /// that lose their backup can no longer be restored; undo for their message degrades to
    /// retracting the message. Backups held by open plans are never evicted.
    ///
    /// The records' "no backup" state is saved first; a backup is deleted only once every
    /// journal that used it saved that state. A journal that cannot be saved keeps its backups.
    func enforceCapacity() {
        guard backupBytes > capacityBytes else { return }
        var newestUse: [String: Date] = [:]
        for journal in journals.values {
            for record in journal.records where record.status == .applied || record.status == .pending {
                if let blob = record.before.blob { newestUse[blob] = max(newestUse[blob] ?? .distantPast, record.createdAt) }
            }
        }
        let protected = Set(plans.values.filter(\.isOpen).flatMap { plan in
            plan.steps.flatMap { [$0.target.blob, $0.replaced?.blob].compactMap { $0 } }
        })
        var victims = Set<String>()
        var projected = backupBytes
        for (blob, _) in newestUse.sorted(by: { $0.value < $1.value }) where !protected.contains(blob) {
            guard projected > capacityBytes else { break }
            victims.insert(blob)
            projected -= blobSizes[blob] ?? 0
        }
        guard !victims.isEmpty else { return }
        var deletable = victims
        for (conversationID, var journal) in journals {
            var used = Set<String>()
            for index in journal.records.indices {
                if let blob = journal.records[index].before.blob, victims.contains(blob) {
                    journal.records[index].before = journal.records[index].before.withoutBlob
                    used.insert(blob)
                }
            }
            guard !used.isEmpty else { continue }
            do {
                try persist(journal, conversationID: conversationID)
                journals[conversationID] = journal
            } catch {
                logs.error("Undo", "Kept \(used.count) backups: the undo journal of '\(conversationID)' could not record their eviction: \(error.localizedDescription)")
                deletable.subtract(used)
            }
        }
        for blob in deletable {
            blobs.delete(blob)
            backupBytes -= blobSizes.removeValue(forKey: blob) ?? 0
        }
        if !deletable.isEmpty {
            logs.info("Undo", "Evicted \(deletable.count) backups to stay within \(capacityBytes) bytes.")
        }
    }

    /// Deletes every backup that no open plan needs. Records keep their
    /// metadata; undo of their messages degrades to retracting the message. Returns bytes freed.
    @discardableResult
    func purgeBackups() -> Int64 {
        let before = backupBytes
        let saved = capacityBytes
        capacityBytes = 0
        enforceCapacity()
        capacityBytes = saved
        collectUnreferencedBlobs()
        return max(0, before - backupBytes)
    }

    // MARK: - Internals

    private func isBlobReferenced(_ blob: String, excluding recordID: UUID? = nil) -> Bool {
        for journal in journals.values {
            for record in journal.records where record.id != recordID && record.before.blob == blob
                && (record.status == .applied || record.status == .pending) {
                return true
            }
        }
        for plan in plans.values where plan.isOpen {
            for step in plan.steps where step.target.blob == blob || step.replaced?.blob == blob { return true }
        }
        return false
    }

    private func collectUnreferencedBlobs() {
        var referenced: Set<String> = []
        for journal in journals.values {
            for record in journal.records where record.status == .applied || record.status == .pending {
                if let blob = record.before.blob { referenced.insert(blob) }
            }
        }
        for plan in plans.values where plan.isOpen {
            for step in plan.steps {
                if let blob = step.target.blob { referenced.insert(blob) }
                if let blob = step.replaced?.blob { referenced.insert(blob) }
            }
        }
        for (blob, size) in blobs.inventory() where !referenced.contains(blob) {
            blobs.delete(blob)
            backupBytes -= blobSizes.removeValue(forKey: blob) ?? size
        }
        backupBytes = max(0, backupBytes)
    }

    private func account(_ blob: String?) {
        guard let blob, blobSizes[blob] == nil else { return }
        var info = stat()
        if lstat(blobs.url(for: blob).path, &info) == 0 {
            blobSizes[blob] = Int64(info.st_size)
            backupBytes += Int64(info.st_size)
        }
    }

    private func removeRecords(_ ids: Set<UUID>, conversationID: UUID) {
        guard var journal = journals[conversationID] else { return }
        journal.records.removeAll(where: { ids.contains($0.id) })
        save(journal, conversationID: conversationID)
        collectUnreferencedBlobs()
    }

    private func journalURL(for conversationID: UUID) -> URL {
        journalsURL.appendingPathComponent("\(conversationID.uuidString).json")
    }

    private func planURL(for id: UUID) -> URL {
        plansURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ journal: UndoJournalSnapshot, conversationID: UUID) throws {
        try onWillPersist?("journal")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = journalURL(for: conversationID)
        try encoder.encode(journal).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// Persists after a change that already happened on disk; a failure is logged and the
    /// in-memory journal still advances so this session stays truthful.
    private func save(_ journal: UndoJournalSnapshot, conversationID: UUID) {
        journals[conversationID] = journal
        do {
            try persist(journal, conversationID: conversationID)
        } catch {
            logs.error("Undo", "Failed to persist the undo journal of conversation '\(conversationID)': \(error.localizedDescription)")
        }
    }

    private func saveOwners() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(Array(delegationOwners.values)).write(to: ownersURL, options: .atomic)
        } catch {
            logs.error("Undo", "Failed to persist delegation owners: \(error.localizedDescription)")
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let files = try? fileManager.contentsOfDirectory(at: journalsURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    let journal = try decoder.decode(UndoJournalSnapshot.self, from: Data(contentsOf: file))
                    guard journal.schemaVersion == UndoJournalSnapshot.currentSchemaVersion else {
                        logs.error("Undo", "Unsupported undo journal schema in '\(file.lastPathComponent)'.")
                        continue
                    }
                    journals[id] = journal
                } catch {
                    logs.error("Undo", "Unreadable undo journal '\(file.lastPathComponent)': \(error.localizedDescription)")
                }
            }
        }
        if let files = try? fileManager.contentsOfDirectory(at: plansURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                do {
                    let plan = try decoder.decode(UndoRestorePlan.self, from: Data(contentsOf: file))
                    plans[plan.id] = plan
                } catch {
                    logs.error("Undo", "Unreadable restore plan '\(file.lastPathComponent)': \(error.localizedDescription)")
                }
            }
        }
        if let data = try? Data(contentsOf: ownersURL),
           let owners = try? JSONDecoder().decode([UndoDelegationOwner].self, from: data) {
            delegationOwners = Dictionary(owners.map { ($0.taskID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        blobSizes = blobs.inventory()
        backupBytes = blobSizes.values.reduce(0, +)
    }
}
