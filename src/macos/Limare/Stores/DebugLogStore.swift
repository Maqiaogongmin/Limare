import Foundation
import Observation
import OSLog

struct DebugLogEntry: Identifiable, Codable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let category: String
    let message: String
}

@MainActor
@Observable
final class DebugLogStore {
    private(set) var entries: [DebugLogEntry] = []

    private let logger: Logger
    private let osLogProjection: (DebugLogEntry.Level, String, String) -> Void
    private let logFileURL: URL
    private let archivedLogFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let diskAppender: ((Data, URL) throws -> Void)?
    private let maximumLogSize = 5 * 1_024 * 1_024

    /// The folder holding main.jsonl; chatty helper processes keep their own files beside it.
    var logDirectoryURL: URL { logFileURL.deletingLastPathComponent() }

    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        osLogProjection: ((DebugLogEntry.Level, String, String) -> Void)? = nil,
        diskAppender: ((Data, URL) throws -> Void)? = nil
    ) {
        let applicationRoot = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        let root = applicationRoot.appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        logFileURL = root.appendingPathComponent("main.jsonl")
        archivedLogFileURL = root.appendingPathComponent("main.previous.jsonl")
        self.fileManager = fileManager
        let runtimeLogger = Logger(subsystem: LimareStorage.bundleIdentifier, category: "Runtime")
        logger = runtimeLogger
        self.osLogProjection = osLogProjection ?? { level, category, message in
            switch level {
            case .info: runtimeLogger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
            case .error: runtimeLogger.error("[\(category, privacy: .public)] \(message, privacy: .public)")
            }
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.diskAppender = diskAppender
    }

    func info(_ category: String, _ message: String, masking secrets: [String] = []) {
        record(
            level: .info,
            category: category,
            message: SecretMasker.redactCredentials(message, secrets: secrets)
        )
    }

    func error(_ category: String, _ message: String, masking secrets: [String] = []) {
        record(
            level: .error,
            category: category,
            message: SecretMasker.redactCredentials(message, secrets: secrets)
        )
    }

    /// Empties the list on screen; the log file on disk keeps every record.
    func clearDisplayed() {
        entries.removeAll()
    }

    private func record(level: DebugLogEntry.Level, category: String, message: String) {
        let entry = DebugLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: category,
            message: sanitizeForPublicProjection(message)
        )
        entries.append(entry)
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }

        osLogProjection(level, sanitizeForPublicProjection(category), entry.message)
        appendToDisk(entry)
    }

    private func appendToDisk(_ entry: DebugLogEntry) {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        do {
            if let diskAppender {
                try diskAppender(data, logFileURL)
                return
            }
            try rotateIfNeeded(incomingByteCount: data.count)
            if !fileManager.fileExists(atPath: logFileURL.path) {
                try data.write(to: logFileURL, options: .atomic)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logFileURL.path
                )
                return
            }
            let handle = try FileHandle(forWritingTo: logFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Do not call record here: persistence trouble must not recursively log.
            osLogProjection(.error, "DebugLog", sanitizeForPublicProjection("Failed to persist debug log: \(error.localizedDescription)"))
        }
    }

    private func sanitizeForPublicProjection(_ value: String) -> String {
        SecretMasker.redactCredentials(value)
    }

    private func rotateIfNeeded(incomingByteCount: Int) throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let currentSize = attributes[.size] as? NSNumber,
              currentSize.intValue + incomingByteCount > maximumLogSize else {
            return
        }
        if fileManager.fileExists(atPath: archivedLogFileURL.path) {
            try fileManager.removeItem(at: archivedLogFileURL)
        }
        try fileManager.moveItem(at: logFileURL, to: archivedLogFileURL)
    }
}
