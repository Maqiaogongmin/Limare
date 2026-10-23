import Foundation
import Observation

/// The single owner of scheduled tasks and their runs: one file, `scheduled_state_v1.json`,
/// written only through `mutate`. Claiming a slot and advancing the plan happen in one atomic
/// replace, so a crash leaves either both or neither.
@MainActor
@Observable
final class ScheduledStateStore {
    struct State: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1
        /// Most recent runs kept per task; `pending` records are never trimmed.
        static let maximumRunsPerTask = 200

        var schemaVersion: Int
        var tasks: [ScheduledTask]
        var runs: [ScheduledRun]

        init(schemaVersion: Int = State.currentSchemaVersion, tasks: [ScheduledTask] = [], runs: [ScheduledRun] = []) {
            self.schemaVersion = schemaVersion
            self.tasks = tasks
            self.runs = runs
        }
    }

    enum StoreError: LocalizedError, Equatable {
        case notReadable
        case taskNotFound
        case runNotFound
        case alreadyBound
        case alreadyFinished

        var errorDescription: String? {
            switch self {
            case .notReadable: "The scheduled task file could not be read; scheduling is paused."
            case .taskNotFound: "The scheduled task no longer exists."
            case .runNotFound: "The scheduled run record no longer exists."
            case .alreadyBound: "The scheduled run is already bound to a different run."
            case .alreadyFinished: "The scheduled run already has a terminal status."
            }
        }
    }

    static let fileName = "scheduled_state_v1.json"

    private(set) var state: State
    /// False when the file exists but cannot be decoded or has an unknown version. The file is then
    /// never overwritten and scheduling stays stopped.
    private(set) var isReadable: Bool
    let fileURL: URL

    @ObservationIgnored
    private let fileManager: FileManager
    @ObservationIgnored
    private let logs: DebugLogStore

    /// Test seam: runs before each write; throwing simulates a failed write.
    @ObservationIgnored
    var onWillWrite: ((State) throws -> Void)?

    init(storageRootURL: URL? = nil, fileManager: FileManager = .default, logs: DebugLogStore) {
        self.fileManager = fileManager
        self.logs = logs
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.fileURL = root.appendingPathComponent(Self.fileName)

        guard let data = try? Data(contentsOf: fileURL) else {
            if fileManager.fileExists(atPath: fileURL.path) {
                logs.error("Scheduled", "Failed to read \(Self.fileName); scheduling is paused.")
                self.state = State()
                self.isReadable = false
            } else {
                self.state = State()
                self.isReadable = true
            }
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(Self.decodeDate)
            let decoded = try decoder.decode(State.self, from: data)
            guard decoded.schemaVersion == State.currentSchemaVersion else {
                logs.error("Scheduled", "Unknown \(Self.fileName) schema version \(decoded.schemaVersion); scheduling is paused.")
                self.state = State()
                self.isReadable = false
                return
            }
            self.state = decoded
            self.isReadable = true
        } catch {
            logs.error("Scheduled", "Failed to decode \(Self.fileName): \(error.localizedDescription); scheduling is paused.")
            self.state = State()
            self.isReadable = false
        }
    }

    var tasks: [ScheduledTask] { state.tasks }
    var runs: [ScheduledRun] { state.runs }
    var pendingCount: Int { state.runs.reduce(0) { $0 + ($1.status == .pending ? 1 : 0) } }

    func task(id: UUID) -> ScheduledTask? { state.tasks.first { $0.id == id } }

    /// Newest first.
    func runs(for taskID: UUID) -> [ScheduledRun] {
        state.runs.filter { $0.taskID == taskID }.sorted { $0.claimedAt > $1.claimedAt }
    }

    /// The pending, bound record for a live run, if this run is a scheduled one.
    func pendingRun(runID: UUID) -> ScheduledRun? {
        state.runs.first { $0.runID == runID && $0.status == .pending }
    }

    /// The only write path: copy, change, encode, replace atomically, then publish in memory.
    /// A failed write leaves both the file and `state` unchanged.
    @discardableResult
    func mutate<T>(_ body: (inout State) throws -> T) throws -> T {
        guard isReadable else { throw StoreError.notReadable }
        var draft = state
        let result = try body(&draft)
        draft.trim()
        state = try write(draft)
        return result
    }

    /// ISO 8601 with fractional seconds, so a reload gives back exactly the dates that were written
    /// (claim order and equality depend on them).
    nonisolated private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    nonisolated private static func encodeDate(_ date: Date, _ encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatter().string(from: date))
    }

    nonisolated private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if let date = formatter().date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date '\(text)'.")
    }

    /// Returns the state as written, so memory holds exactly what a reload would read
    /// (ISO 8601 keeps milliseconds, not the full `Date` precision).
    private func write(_ draft: State) throws -> State {
        try onWillWrite?(draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom(Self.encodeDate)
        let data = try encoder.encode(draft)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        let written = try decoder.decode(State.self, from: data)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return written
    }
}

// MARK: - State operations (only reachable inside `mutate`)

extension ScheduledStateStore.State {
    func task(id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    mutating func upsertTask(_ task: ScheduledTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    /// Removes the task and its finished runs. A pending run keeps its record until it ends, so the
    /// concurrency limit and unattended checks stay true; `trim` drops it once it is terminal.
    mutating func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
        runs.removeAll { $0.taskID == id && $0.status.isTerminal }
    }

    /// Sets the task's next planned slot.
    mutating func advance(taskID: UUID, to next: Date?) throws {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw ScheduledStateStore.StoreError.taskNotFound
        }
        tasks[index].nextNominalAt = next
    }

    /// Inserts a claim (pending) or a skip. A non-manual record whose `(taskID, slotNominalAt)`
    /// already exists is not written twice: the existing record is returned instead.
    @discardableResult
    mutating func insertRun(
        id: UUID = UUID(),
        taskID: UUID,
        slot: Date,
        trigger: ScheduledRun.Trigger,
        status: ScheduledRun.Status,
        skipReason: ScheduledRun.SkipReason? = nil,
        missedCount: Int? = nil,
        at now: Date
    ) -> ScheduledRun {
        if trigger != .manual,
           let existing = runs.first(where: { $0.taskID == taskID && $0.trigger != .manual && $0.slotNominalAt == slot }) {
            return existing
        }
        let run = ScheduledRun(
            id: id,
            taskID: taskID,
            slotNominalAt: trigger == .manual ? now : slot,
            trigger: trigger,
            status: status,
            skipReason: status == .skipped ? skipReason : nil,
            missedCount: status == .skipped && skipReason == .missedSlots ? missedCount : nil,
            claimedAt: now,
            finishedAt: status.isTerminal ? now : nil
        )
        runs.append(run)
        return run
    }

    /// W2: the binding, written once from nothing. A second binding with a different run id throws.
    mutating func bind(_ claimID: UUID, conversationID: UUID, runID: UUID, at now: Date) throws {
        guard let index = runs.firstIndex(where: { $0.id == claimID }) else {
            throw ScheduledStateStore.StoreError.runNotFound
        }
        guard runs[index].status == .pending else { throw ScheduledStateStore.StoreError.alreadyFinished }
        if let bound = runs[index].runID {
            guard bound == runID, runs[index].conversationID == conversationID else {
                throw ScheduledStateStore.StoreError.alreadyBound
            }
            return
        }
        runs[index].conversationID = conversationID
        runs[index].runID = runID
        runs[index].boundAt = now
    }

    /// Writes a terminal status. A terminal record is never changed again.
    mutating func finish(_ claimID: UUID, _ outcome: ScheduledRun.Outcome, at now: Date) throws {
        guard let index = runs.firstIndex(where: { $0.id == claimID }) else {
            throw ScheduledStateStore.StoreError.runNotFound
        }
        guard runs[index].status == .pending else { throw ScheduledStateStore.StoreError.alreadyFinished }
        runs[index].status = outcome.status
        runs[index].finishedAt = now
        switch outcome {
        case .failed(let detail):
            runs[index].failureDetail = detail
        case .skipped(let reason, let missedCount):
            runs[index].skipReason = reason
            runs[index].missedCount = reason == .missedSlots ? missedCount : nil
        case .completed, .cancelled, .interrupted:
            break
        }
    }

    /// Keeps the newest `maximumRunsPerTask` records per task and drops finished records of deleted
    /// tasks. `pending` records are never removed.
    mutating func trim() {
        let taskIDs = Set(tasks.map(\.id))
        var keep = Set<UUID>()
        for (taskID, group) in Dictionary(grouping: runs, by: \.taskID) {
            guard taskIDs.contains(taskID) else { continue }
            let finished = group.filter { $0.status.isTerminal }.sorted { $0.claimedAt > $1.claimedAt }
            let pendingCount = group.count - finished.count
            let room = max(Self.maximumRunsPerTask - pendingCount, 0)
            keep.formUnion(finished.prefix(room).map(\.id))
        }
        runs.removeAll { $0.status.isTerminal && !keep.contains($0.id) }
    }
}
