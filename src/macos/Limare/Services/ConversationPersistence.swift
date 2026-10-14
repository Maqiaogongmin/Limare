import Foundation

enum RuntimePersistenceError: LocalizedError, Sendable, Equatable {
    case conversationNotFound(UUID)
    case writeFailed(String)
    case preToolDispatchFailed(toolName: String, callID: String, underlyingError: String)
    case toolOutcomeCommitFailed(toolName: String, callID: String, underlyingError: String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id):
            return "Conversation '\(id)' not found in persistence store."
        case .writeFailed(let reason):
            return "Failed to persist conversation: \(reason)"
        case .preToolDispatchFailed(let name, let id, let err):
            return "Failed to commit pre-tool dispatch record for tool '\(name)' (\(id)): \(err)"
        case .toolOutcomeCommitFailed(let name, let id, let err):
            return "Failed to commit tool outcome for tool '\(name)' (\(id)): \(err)"
        }
    }
}

@MainActor
final class ConversationPersistence {
    let rootURL: URL
    private let conversationsDirURL: URL
    private let projectsFileURL: URL
    private let fileManager: FileManager
    private let logs: DebugLogStore

    // Deterministic test seam for persistence durability testing
    var onWillSaveConversation: ((ConversationRecord) throws -> Void)?
    private(set) var saveCount: Int = 0

    func resetTestCounters() {
        saveCount = 0
        onWillSaveConversation = nil
    }

    init(
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default,
        logs: DebugLogStore
    ) {
        self.fileManager = fileManager
        self.logs = logs
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        self.rootURL = root
        self.projectsFileURL = root.appendingPathComponent("projects.json")
        self.conversationsDirURL = root.appendingPathComponent("conversations", isDirectory: true)

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: conversationsDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: - Projects

    func loadProjects() -> [ProjectRecord] {
        guard let data = try? Data(contentsOf: projectsFileURL) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let projects = try decoder.decode([ProjectRecord].self, from: data)
            return projects.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            logs.error("Persistence", "Failed to decode projects.json: \(error.localizedDescription)")
            return []
        }
    }

    func saveProjects(_ projects: [ProjectRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(projects)
        try data.write(to: projectsFileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectsFileURL.path)
    }

    // MARK: - Conversations

    func loadConversations() -> [ConversationRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: conversationsDirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var loaded: [ConversationRecord] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let record = try decoder.decode(ConversationRecord.self, from: data)
                loaded.append(record)
            } catch {
                logs.error("Persistence", "Skipping corrupted conversation file '\(url.lastPathComponent)': \(error.localizedDescription)")
            }
        }

        return loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveConversation(_ conversation: ConversationRecord) throws {
        if let onWillSaveConversation {
            try onWillSaveConversation(conversation)
        }
        saveCount += 1
        let fileURL = conversationsDirURL.appendingPathComponent("\(conversation.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(conversation)
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func deleteConversation(id: UUID) throws {
        let fileURL = conversationsDirURL.appendingPathComponent("\(id.uuidString).json")
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        deleteWorkingDirectory(for: id)
    }

    // MARK: - Managed Working Directory

    func workingDirectoryURL(for conversationID: UUID) -> URL {
        rootURL.appendingPathComponent("working", isDirectory: true)
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    @discardableResult
    func ensureWorkingDirectoryExists(for conversationID: UUID) -> URL {
        let dirURL = workingDirectoryURL(for: conversationID)
        if !fileManager.fileExists(atPath: dirURL.path) {
            try? fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return dirURL
    }

    func deleteWorkingDirectory(for conversationID: UUID) {
        let dirURL = workingDirectoryURL(for: conversationID)
        if fileManager.fileExists(atPath: dirURL.path) {
            try? fileManager.removeItem(at: dirURL)
            logs.info("Persistence", "Deleted working directory for conversation '\(conversationID)'.")
        }
    }
}
