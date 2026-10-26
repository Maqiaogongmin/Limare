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

struct EditArguments: Decodable {
    let path: String
    let oldText: String
    let newText: String

    enum CodingKeys: String, CodingKey {
        case path
        case oldText = "old_text"
        case newText = "new_text"
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
