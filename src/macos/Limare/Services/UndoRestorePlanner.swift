import Foundation

/// Computes what undoing the last user message would do, from the change journal, the
/// transcript and the files as they are now. Changes nothing.
///
/// For every path the selected records touched, the restore target is the before-state of the
/// earliest selected change, and the restore is safe only when the file still holds exactly
/// what the latest selected change left (and the selected changes form an unbroken chain).
/// Anything else is a conflict, and conflicts block the whole file restore.
enum UndoRestorePlanner {
    /// Tools whose effects stay inside Limare or are recorded by the journal itself.
    static let nonProjectTools: Set<String> = [
        "file_read", "file_list", "file_search", "read_image", "tool_result_read", "model_use",
        "delegation_control", "delegation_result", "verification_handoff", "artifact_acquire",
        "artifact_register", "resource_convert", "update_plan", "tool_search"
    ]
    static let recordedFileTools: Set<String> = ["file_write", "file_edit", "attachment_copy"]

    static func preview(
        conversationID: UUID,
        messageID: UUID,
        transcript: [ChatMessage],
        records: [UndoChangeRecord],
        includeLeftovers: Bool,
        currentState: (AnchoredPath) throws -> UndoFileState
    ) -> UndoPreview {
        let presentUserMessages = Set(transcript.filter { $0.role == .user }.map(\.id))
        let applied = records.filter { $0.status == .applied }
        let retractedOwners = Set(applied.map(\.ownerMessageID)).subtracting(presentUserMessages)
        let turn = turnMessageIDs(of: messageID, in: transcript)
        var owners = turn
        if includeLeftovers { owners.formUnion(retractedOwners) }

        var preview = UndoPreview(
            conversationID: conversationID, messageID: messageID, willRestore: [], optional: [],
            irreversible: [], conflicts: [], missingBackups: [], leftoverMessageIDs: [],
            includesLeftovers: includeLeftovers)

        let byPath = Dictionary(grouping: applied, by: \.path)
        for path in byPath.keys.sorted() {
            let pathRecords = byPath[path]!.sorted { $0.sequence < $1.sequence }
            let selected = pathRecords.filter { owners.contains($0.ownerMessageID) }
            guard let first = selected.first, let last = selected.last else { continue }

            let later = pathRecords.filter { $0.sequence > last.sequence && !owners.contains($0.ownerMessageID) }
            if !later.isEmpty {
                let laterOwners = Set(later.map(\.ownerMessageID))
                if laterOwners.isSubset(of: retractedOwners) {
                    preview.conflicts.append(.init(path: path, reason: .leftoverChanges(messageIDs: Array(laterOwners))))
                    preview.leftoverMessageIDs.append(contentsOf: laterOwners.filter { !preview.leftoverMessageIDs.contains($0) })
                } else {
                    preview.conflicts.append(.init(path: path, reason: .modifiedSinceChange))
                }
                continue
            }
            // Interleaved changes by other, still present messages break the chain too.
            let interleaved = pathRecords.contains { $0.sequence > first.sequence && $0.sequence < last.sequence && !owners.contains($0.ownerMessageID) }
            let unbroken = zip(selected, selected.dropFirst()).allSatisfy { pair in
                pair.0.after.map { $0.sameState(as: pair.1.before) } ?? false
            }
            guard unbroken, !interleaved else {
                preview.conflicts.append(.init(path: path, reason: .modifiedBetweenChanges))
                continue
            }
            let target = first.before
            let expected = last.after ?? .other(kind: "unknown")
            var location = last.location
            let current: UndoFileState
            do {
                let observed = try currentState(location)
                location = try location.allowingRecreationOfMissingParents()
                current = observed
            } catch AnchoredFileError.redirected, AnchoredFileError.rootMoved {
                preview.conflicts.append(.init(path: path, reason: .pathRedirected))
                continue
            } catch {
                current = .other(kind: "unreadable")
            }
            if !current.sameState(as: expected) && !current.sameState(as: target) {
                preview.conflicts.append(.init(path: path, reason: .modifiedSinceChange))
                continue
            }
            guard target.isRestorable else {
                if selected.contains(where: \.isUncertain) {
                    // An uncertain change (Computer Use, MCP) seen without a backup: listed, not blocking.
                    preview.irreversible.append(.init(id: "unbacked:" + path, title: "未能备份，无法恢复", detail: path))
                } else {
                    preview.missingBackups.append(path)
                }
                continue
            }
            let item = UndoRestoreItem(
                path: path, location: location, expected: expected, target: target, recordIDs: selected.map(\.id),
                createdDirectories: Array(Set(selected.flatMap(\.createdDirectories))).sorted(),
                source: Array(Set(selected.map(\.source))).sorted().joined(separator: ", "),
                isOptional: selected.contains(where: \.isUncertain))
            if item.isOptional { preview.optional.append(item) } else { preview.willRestore.append(item) }
        }

        preview.irreversible += irreversibleEffects(
            after: messageID, transcript: transcript,
            recordedCallIDs: Set(records.filter { turn.contains($0.ownerMessageID) }.compactMap(\.toolCallID)))
        return preview
    }

    /// The messages whose changes undoing `messageID` reverses: the request and the system
    /// notices (subagent results) that continued it. Notices own no changes now, but records
    /// saved before 2026-10-07 may still name one.
    static func turnMessageIDs(of messageID: UUID, in transcript: [ChatMessage]) -> Set<UUID> {
        guard let start = transcript.firstIndex(where: { $0.id == messageID }) else { return [messageID] }
        var ids: Set<UUID> = [messageID]
        for message in transcript[(start + 1)...] where message.role == .user {
            guard message.isSystemNotice else { break }
            ids.insert(message.id)
        }
        return ids
    }

    /// Tool calls of the turn whose effects undo cannot reverse.
    static func irreversibleEffects(after messageID: UUID, transcript: [ChatMessage], recordedCallIDs: Set<String>) -> [UndoIrreversibleEffect] {
        guard let start = transcript.firstIndex(where: { $0.id == messageID }) else { return [] }
        var effects: [UndoIrreversibleEffect] = []
        for message in transcript[start...] where message.role == .assistant {
            for call in message.toolCalls where call.state != .denied && call.state != .queued && call.state != .awaitingApproval {
                let name = call.name
                if nonProjectTools.contains(name) { continue }
                if recordedFileTools.contains(name) {
                    guard call.state == .completed || call.state == .interrupted, !recordedCallIDs.contains(call.providerCallID) else { continue }
                    effects.append(.init(id: call.providerCallID, title: "\(name) 未记录", detail: argument("path", of: call) ?? call.input))
                    continue
                }
                switch name {
                case "shell_execute":
                    effects.append(.init(id: call.providerCallID, title: "命令", detail: argument("command", of: call) ?? call.input))
                case "computer_use":
                    effects.append(.init(id: call.providerCallID, title: "Computer Use 操作", detail: argument("action", of: call) ?? ""))
                case "browser_use":
                    effects.append(.init(id: call.providerCallID, title: "浏览器操作", detail: argument("action", of: call) ?? ""))
                case "delegate_task":
                    effects.append(.init(id: call.providerCallID, title: "子任务", detail: "子任务通过文件工具做的改动已计入；它执行的命令无法撤销"))
                default:
                    effects.append(.init(id: call.providerCallID, title: "工具 \(name)", detail: "外部影响无法撤销"))
                }
            }
        }
        return effects
    }

    private static func argument(_ key: String, of call: ToolCallRecord) -> String? {
        guard let data = call.input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = object[key] as? String { return value }
        return nil
    }
}
