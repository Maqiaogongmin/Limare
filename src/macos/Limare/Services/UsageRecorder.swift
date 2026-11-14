import Foundation
import Observation
import SQLite3

extension Notification.Name { static let usageRecorded = Notification.Name("LimareUsageRecorded") }

@MainActor @Observable
final class UsageRecordingStatus {
    var failure: String?
    var startedAt: Date?
}

struct UsageTotals: Sendable {
    var requests = 0
    var input: Int?
    var output: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    var toolUsePrompt: Int?
    var incomplete = false

    mutating func add(_ usage: NormalizedUsage) {
        requests += 1
        func sum(_ a: Int?, _ b: Int?) -> Int? {
            guard let b else { return a }
            return (a ?? 0) + b
        }
        input = sum(input, usage.input); output = sum(output, usage.output)
        cacheRead = sum(cacheRead, usage.cacheRead); cacheWrite = sum(cacheWrite, usage.cacheWrite)
        reasoning = sum(reasoning, usage.reasoning); toolUsePrompt = sum(toolUsePrompt, usage.toolUsePrompt)
        incomplete = incomplete || usage.status != .complete
    }
}

struct UsageGroup: Identifiable, Sendable {
    var id: String
    var provider: String
    var model: String
    var totals: UsageTotals
}

struct UsageDay: Identifiable, Sendable {
    var id: Date { date }
    var date: Date
    var totals: UsageTotals
}

struct UsageReport: Sendable {
    var totals = UsageTotals()
    var groups: [UsageGroup] = []
    var days: [UsageDay] = []
}

struct UsageDatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class UsageDatabaseConnection: @unchecked Sendable {
    let raw: OpaquePointer
    init(_ raw: OpaquePointer) { self.raw = raw }
    deinit { sqlite3_close(raw) }
}

actor UsageRecorder {
    private let connection: UsageDatabaseConnection
    private var db: OpaquePointer { connection.raw }
    private let status: UsageRecordingStatus
    let startedAt: Date
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(storageRootURL: URL?, status: UsageRecordingStatus) throws {
        let root = storageRootURL ?? LimareStorage.defaultRoot
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let path = root.appendingPathComponent("usage.sqlite3").path
        if !fm.fileExists(atPath: path) {
            guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw UsageDatabaseError(message: "Could not create usage database.")
            }
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open usage database."
            if let connection { sqlite3_close(connection) }
            throw UsageDatabaseError(message: message)
        }
        do {
            try Self.execute(connection, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;")
            try Self.execute(connection, """
                CREATE TABLE IF NOT EXISTS usage_request (
                    id TEXT PRIMARY KEY, provider_id TEXT NOT NULL, provider_name_snapshot TEXT NOT NULL,
                    model_id TEXT NOT NULL, model_name_snapshot TEXT NOT NULL, protocol TEXT NOT NULL,
                    usage_kind TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL NOT NULL,
                    outcome TEXT NOT NULL, attempt_count INTEGER NOT NULL, attempts_without_usage INTEGER NOT NULL,
                    input_total INTEGER, output_total INTEGER, cache_read INTEGER, cache_write INTEGER,
                    reasoning INTEGER, tool_use_prompt INTEGER, provider_total INTEGER, usage_status TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS usage_request_started ON usage_request(started_at);
                CREATE INDEX IF NOT EXISTS usage_request_provider_model ON usage_request(provider_id, model_id);
                """)
        } catch {
            sqlite3_close(connection)
            throw error
        }
        self.connection = UsageDatabaseConnection(connection)
        self.status = status
        let created = (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? Date()
        if storageRootURL == nil && LimareStorage.isLimareApp {
            let key = "limare.usage.recordingStartedAt"
            let saved = UserDefaults.standard.object(forKey: key) as? Date
            self.startedAt = saved ?? Date()
            if saved == nil { UserDefaults.standard.set(self.startedAt, forKey: key) }
        } else {
            self.startedAt = created
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageDatabaseError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    func append(_ record: UsageRequestRecord) async {
        do {
            try insert(record)
            await MainActor.run {
                status.failure = nil
                NotificationCenter.default.post(name: .usageRecorded, object: nil)
            }
        }
        catch {
            let message = error.localizedDescription
            await MainActor.run { status.failure = message }
        }
    }

    private func insert(_ record: UsageRequestRecord) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO usage_request VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageDatabaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        func text(_ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, Self.transient) }
        func integer(_ index: Int32, _ value: Int?) {
            if let value { sqlite3_bind_int64(statement, index, sqlite3_int64(value)) }
            else { sqlite3_bind_null(statement, index) }
        }
        text(1, record.id.uuidString); text(2, record.providerID.uuidString); text(3, record.providerName)
        text(4, record.modelID); text(5, record.modelName); text(6, record.format.rawValue)
        text(7, record.kind.rawValue); sqlite3_bind_double(statement, 8, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, record.endedAt.timeIntervalSince1970); text(10, record.outcome.rawValue)
        integer(11, record.attemptCount); integer(12, record.attemptsWithoutUsage)
        integer(13, record.usage.input); integer(14, record.usage.output); integer(15, record.usage.cacheRead)
        integer(16, record.usage.cacheWrite); integer(17, record.usage.reasoning); integer(18, record.usage.toolUsePrompt)
        integer(19, record.usage.providerTotal); text(20, record.usage.status.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageDatabaseError(message: String(cString: sqlite3_errmsg(db))) }
    }

    func report(since: Date?, kind: UsageKind?, providerID: UUID? = nil, timeZone: TimeZone = .current) throws -> UsageReport {
        var statement: OpaquePointer?
        let sql = """
            SELECT provider_id, provider_name_snapshot, model_id, model_name_snapshot, started_at,
                   input_total, output_total, cache_read, cache_write, reasoning, tool_use_prompt, provider_total, usage_status
            FROM usage_request WHERE (?1 IS NULL OR started_at >= ?1)
              AND (?2 IS NULL OR usage_kind = ?2) AND (?3 IS NULL OR provider_id = ?3)
            ORDER BY started_at
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageDatabaseError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let since { sqlite3_bind_double(statement, 1, since.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 1) }
        if let kind { sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient) } else { sqlite3_bind_null(statement, 2) }
        if let providerID { sqlite3_bind_text(statement, 3, providerID.uuidString, -1, Self.transient) } else { sqlite3_bind_null(statement, 3) }
        var report = UsageReport()
        var groups: [String: UsageGroup] = [:]
        var days: [Date: UsageTotals] = [:]
        var calendar = Calendar.current; calendar.timeZone = timeZone
        func string(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func number(_ i: Int32) -> Int? { sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, i)) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw UsageDatabaseError(message: String(cString: sqlite3_errmsg(db))) }
            let usage = NormalizedUsage(input: number(5), output: number(6), cacheRead: number(7), cacheWrite: number(8),
                reasoning: number(9), toolUsePrompt: number(10), providerTotal: number(11),
                status: UsageStatus(rawValue: string(12)) ?? .unknown)
            report.totals.add(usage)
            let key = [string(0), string(1), string(2), string(3)].joined(separator: "\u{1f}")
            var group = groups[key] ?? UsageGroup(id: key, provider: string(1), model: string(3), totals: UsageTotals())
            group.totals.add(usage); groups[key] = group
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
            var dayTotals = days[day] ?? UsageTotals(); dayTotals.add(usage); days[day] = dayTotals
        }
        report.groups = groups.values.sorted { $0.totals.requests > $1.totals.requests }
        report.days = days.map { UsageDay(date: $0.key, totals: $0.value) }.sorted { $0.date < $1.date }
        return report
    }
}
