import Foundation

// MARK: - AnyCodable

public struct AnyCodable: Codable, Sendable, Equatable, Hashable {
    public let value: any Sendable

    public init(_ value: (any Sendable)?) {
        self.value = value ?? ()
    }

    public static func from(json: Any?) -> AnyCodable {
        guard let json else { return AnyCodable(()) }
        if let bool = json as? Bool { return AnyCodable(bool) }
        if let int = json as? Int { return AnyCodable(int) }
        if let double = json as? Double { return AnyCodable(double) }
        if let string = json as? String { return AnyCodable(string) }
        if let array = json as? [Any] {
            return AnyCodable(array.map { AnyCodable.from(json: $0) })
        }
        if let dict = json as? [String: Any] {
            return AnyCodable(dict.mapValues { AnyCodable.from(json: $0) })
        }
        return AnyCodable(String(describing: json))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let date as Date:
            try container.encode(date)
        case let url as URL:
            try container.encode(url)
        case let array as [any Sendable]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: any Sendable]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let encodable as any Encodable:
            try encodable.encode(to: encoder)
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "AnyCodable value cannot be encoded: \(value)"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (Void, Void):
            return true
        case let (l as Bool, r as Bool):
            return l == r
        case let (l as Int, r as Int):
            return l == r
        case let (l as Double, r as Double):
            return l == r
        case let (l as String, r as String):
            return l == r
        case let (l as [any Sendable], r as [any Sendable]):
            return l.map { AnyCodable($0) } == r.map { AnyCodable($0) }
        case let (l as [String: any Sendable], r as [String: any Sendable]):
            return l.mapValues { AnyCodable($0) } == r.mapValues { AnyCodable($0) }
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch value {
        case is Void:
            hasher.combine(0)
        case let bool as Bool:
            hasher.combine(bool)
        case let int as Int:
            hasher.combine(int)
        case let double as Double:
            hasher.combine(double)
        case let string as String:
            hasher.combine(string)
        default:
            hasher.combine(String(describing: value))
        }
    }

    public var stringValue: String? { value as? String }
    public var intValue: Int? {
        if let int = value as? Int { return int }
        if let int64 = value as? Int64 { return Int(int64) }
        if let double = value as? Double { return Int(double) }
        if let str = value as? String { return Int(str) }
        return nil
    }
    public var doubleValue: Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let str = value as? String { return Double(str) }
        return nil
    }
    public var boolValue: Bool? { value as? Bool }
    public var arrayValue: [AnyCodable]? {
        guard let list = value as? [any Sendable] else { return nil }
        return list.map { AnyCodable($0) }
    }
    public var dictionaryValue: [String: AnyCodable]? {
        guard let dict = value as? [String: any Sendable] else { return nil }
        return dict.mapValues { AnyCodable($0) }
    }

    public static let defaultObjectSchema = AnyCodable([
        "type": AnyCodable("object"),
        "properties": AnyCodable([String: AnyCodable]())
    ])
}

// MARK: - MCPTool & Namespace

enum MCPToolNamespace {
    static let prefix = "mcp__"
    static let separator = "__"

    static func exposedName(serverID: String, toolName: String) -> String {
        let safeServerID = serverID.replacingOccurrences(of: separator, with: "_")
        let safeToolName = toolName.replacingOccurrences(of: separator, with: "_")
        return "\(prefix)\(safeServerID)\(separator)\(safeToolName)"
    }

    static func parse(exposedName: String) -> (serverID: String, toolName: String)? {
        guard exposedName.hasPrefix(prefix) else { return nil }
        let stripped = exposedName.dropFirst(prefix.count)
        let parts = stripped.components(separatedBy: separator)
        guard parts.count >= 2 else { return nil }
        let serverID = parts[0]
        let toolName = parts.dropFirst().joined(separator: separator)
        return (serverID, toolName)
    }
}

struct MCPTool: Identifiable, Sendable, Equatable, Hashable {
    var id: String { "\(serverID)/\(name)" }
    let serverID: String
    let name: String
    let description: String
    let inputSchema: AnyCodable

    var exposedName: String {
        MCPToolNamespace.exposedName(serverID: serverID, toolName: name)
    }

    func asChatToolDefinition() -> ChatToolDefinition {
        ChatToolDefinition(
            function: .init(
                name: exposedName,
                description: description.isEmpty ? "Tool provided by MCP server '\(serverID)'." : description,
                rawParameters: inputSchema
            )
        )
    }
}

struct MCPToolCallResult: Sendable, Equatable {
    let content: String
    let isError: Bool
    let resultParts: [ToolResultPart]?
    let attachments: [ChatAttachment]

    init(
        content: String,
        isError: Bool,
        resultParts: [ToolResultPart]? = nil,
        attachments: [ChatAttachment] = []
    ) {
        self.content = content
        self.isError = isError
        self.resultParts = resultParts
        self.attachments = attachments
    }
}

enum MCPTransportError: LocalizedError, Sendable, Equatable {
    case commandNotFound(String)
    case spawnFailed(String)
    case connectionClosed
    case processExited(exitCode: Int32, stderr: String)
    case timeout(seconds: Int)
    case protocolError(code: Int, message: String)
    case parseError(String)
    case invalidResponse(String)
    case unknownServer(String)
    case serverDisabled(String)
    case authenticationRequired(message: String)
    /// OAuth server with no usable token; only an interactive browser sign-in can fix it.
    case signInRequired(serverID: String)
    case accessForbidden(message: String)
    case networkUnreachable(String)
    case serverError(code: Int, message: String)
    case toolUnavailable(serverID: String, toolName: String)
    case executionFailed(String)
    case invalidURL(String)
    case configurationError(String)
    /// The configuration references stored credentials that have no value yet.
    case credentialMissing(serverID: String, names: [String])

    var failureKind: MCPFailureKind {
        switch self {
        case .authenticationRequired, .signInRequired, .credentialMissing: return .authentication
        case .accessForbidden: return .forbidden
        case .networkUnreachable: return .network
        case .timeout: return .timeout
        case .serverError: return .serverError
        case .protocolError, .parseError, .invalidResponse: return .protocolError
        case .processExited, .commandNotFound, .spawnFailed: return .processExited
        default: return .other
        }
    }

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let cmd): return "Command not found: \(cmd)"
        case .spawnFailed(let msg): return "Failed to start MCP server process: \(msg)"
        case .connectionClosed: return "MCP server closed the connection."
        case .processExited(let code, let stderr):
            return stderr.isEmpty ? "MCP server process exited with code \(code)." : "MCP server process exited (\(code)): \(stderr)"
        case .timeout(let sec): return "MCP request timed out after \(sec) seconds."
        case .protocolError(let code, let msg): return "MCP protocol error (\(code)): \(msg)"
        case .parseError(let msg): return "Failed to parse MCP message: \(msg)"
        case .invalidResponse(let msg): return "Invalid MCP response: \(msg)"
        case .unknownServer(let id): return "Unknown MCP server: \(id)"
        case .serverDisabled(let id): return "MCP server is disabled: \(id)"
        case .authenticationRequired(let msg): return msg
        case .signInRequired(let id): return "MCP server '\(id)' requires sign-in. Sign in from Settings → MCP, or ask the agent to run mcp_manage action 'authenticate'."
        case .accessForbidden(let msg): return msg
        case .networkUnreachable(let msg): return msg
        case .serverError(let code, let msg): return "Remote server error (\(code)): \(msg)"
        case .toolUnavailable(let serverID, let toolName):
            return "MCP tool '\(toolName)' is not available from the current connected discovery of server '\(serverID)'."
        case .executionFailed(let msg): return msg
        case .invalidURL(let msg): return "Invalid MCP URL: \(msg)"
        case .configurationError(let msg): return "MCP configuration error: \(msg)"
        case .credentialMissing(let id, let names):
            return "MCP server '\(id)' needs \(names.joined(separator: ", ")). Limare asks for it in its own secure prompt (Settings → MCP → Enter Credentials…, or mcp_manage action 'authenticate')."
        }
    }
}
