import Foundation
import Observation

/// The list of subagent tasks, saved as one JSON file. Child conversations themselves live in
/// ConversationStore like any other conversation.
@MainActor
@Observable
final class SubagentStore {
    let fileURL: URL
    private(set) var tasks: [UUID: SubagentTask] = [:]
    @ObservationIgnored private let logs: DebugLogStore

    init(storageRootURL: URL? = nil, logs: DebugLogStore) {
        let root = storageRootURL ?? LimareStorage.applicationSupport
            .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        fileURL = root.appendingPathComponent("subagent_tasks_v1.json")
        self.logs = logs
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let list = try decoder.decode([SubagentTask].self, from: Data(contentsOf: fileURL))
                tasks = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch {
                logs.error("Subagent", "Could not read \(fileURL.lastPathComponent): \(error). Starting with an empty task list; the file is left as it is.")
            }
        } else {
            importEarlierTasks(from: root.appendingPathComponent("delegation_control_v1.json"))
        }
    }

    func tasks(for parentConversationID: UUID) -> [SubagentTask] {
        tasks.values.filter { $0.parentConversationID == parentConversationID }.sorted { $0.createdAt < $1.createdAt }
    }

    func task(childConversationID: UUID) -> SubagentTask? {
        tasks.values.first { $0.childConversationID == childConversationID }
    }

    func task(runID: UUID) -> SubagentTask? {
        tasks.values.first { $0.runID == runID }
    }

    func insert(_ task: SubagentTask) {
        tasks[task.id] = task
        save()
    }

    func update(_ id: UUID, _ change: (inout SubagentTask) -> Void) {
        guard var task = tasks[id] else { return }
        change(&task)
        guard task != tasks[id] else { return }
        tasks[id] = task
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(tasks.values.sorted { $0.createdAt < $1.createdAt }).write(to: fileURL, options: .atomic)
        } catch {
            logs.error("Subagent", "Could not save subagent tasks: \(error)")
        }
    }

    /// Tasks recorded by the earlier delegation control layer keep their place in the task bar,
    /// so their child conversations stay reachable. That file itself is left untouched.
    private func importEarlierTasks(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Swift encodes UUID-keyed dictionaries as [key, value, key, value, ...].
        let records: [[String: Any]]
        if let list = object["tasks"] as? [Any] {
            records = list.enumerated().filter { $0.offset % 2 == 1 }.compactMap { $0.element as? [String: Any] }
        } else {
            records = (object["tasks"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        for (index, record) in records.enumerated() {
            guard let id = (record["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let parent = (record["parentConversationID"] as? String).flatMap(UUID.init(uuidString:)),
                  let child = (record["childConversationID"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            let goal = record["goal"] as? String ?? ""
            let tools = record["requestedToolNames"] as? [String] ?? []
            let settled = record["phase"] as? String == "settled"
            tasks[id] = SubagentTask(id: id, parentConversationID: parent, childConversationID: child,
                title: String(goal.split(separator: "\n").first ?? "Subagent task").prefix(80).description, goal: goal,
                role: tools.contains("file_write") ? .coding : .research, allowWeb: false,
                allowance: .init(effort: .standard), background: true, status: settled ? .completed : .interrupted,
                failure: settled ? nil : String(localized: "Recorded before the subagent update; open the child conversation to see what it did."),
                createdAt: modified.addingTimeInterval(Double(index) - Double(records.count)), finishedAt: modified)
        }
        if !tasks.isEmpty {
            logs.info("Subagent", "Imported \(tasks.count) earlier subagent task(s) into the task list.")
            save()
        }
    }
}
