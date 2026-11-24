import Foundation

// The arguments of the built-in tools, as the executor decodes them from a call. The transcript
// decodes a call's recorded input with the same types, so each schema exists once.

struct PlanArguments: Decodable {
    struct Item: Decodable { let step: String; let status: String }
    let explanation: String?
    let plan: [Item]
}

struct ShellArguments: Decodable {
    let command: String
    let cwd: String?
    let environment: [String: String]?
    let timeoutSeconds: TimeInterval?
    let sandboxPermissions: String?
    let justification: String?

    /// Codex's escalation request: write outside the working folder and temp, once approved.
    var requiresEscalation: Bool { sandboxPermissions == "require_escalated" }

    enum CodingKeys: String, CodingKey {
        case command
        case cwd
        case environment
        case timeoutSeconds = "timeout_seconds"
        case sandboxPermissions = "sandbox_permissions"
        case justification
    }
}

/// Numbers decode as `Double`, so a model's `10.0` reads as 10; `FileReadWindow` checks them.
struct ReadArguments: Decodable { let path: String; let offset: Double?; let limit: Double? }
struct WriteArguments: Decodable { let path: String; let content: String }

struct EditHunk: Decodable, Sendable {
    let oldText: String
    let newText: String
    let replaceAll: Bool?

    enum CodingKeys: String, CodingKey {
        case oldText = "old_text"
        case newText = "new_text"
        case replaceAll = "replace_all"
    }
}

struct EditArguments: Decodable, Sendable {
    let path: String
    let oldText: String?
    let newText: String?
    let replaceAll: Bool?
    let edits: [EditHunk]?

    var hasPartialTopLevelPair: Bool {
        (oldText == nil) != (newText == nil)
    }

    var resolvedHunks: [EditHunk] {
        guard !hasPartialTopLevelPair else { return [] }
        var result: [EditHunk] = []
        if let oldText, let newText {
            result.append(EditHunk(oldText: oldText, newText: newText, replaceAll: replaceAll))
        }
        if let edits {
            result.append(contentsOf: edits.map {
                EditHunk(oldText: $0.oldText, newText: $0.newText, replaceAll: $0.replaceAll ?? replaceAll)
            })
        }
        return result
    }

    enum CodingKeys: String, CodingKey {
        case path
        case oldText = "old_text"
        case newText = "new_text"
        case replaceAll = "replace_all"
        case edits
    }
}

struct FileListArguments: Decodable {
    let path: String?
    let recursive: Bool?
    let max_depth: Int?
    let max_entries: Int?
}

struct FileSearchArguments: Decodable {
    let query: String
    let path: String?
    let mode: String?
    let regex: Bool?
    let max_results: Int?
}
