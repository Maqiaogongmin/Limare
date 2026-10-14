import Foundation

enum ShellExecutionBoundary: Sendable {
    case primaryInteractive
}

struct ShellExecutionRequest: Sendable {
    let command: String
    let cwd: URL
    let environment: [String: String]
    let timeoutSeconds: TimeInterval
    let boundary: ShellExecutionBoundary
    /// Runs outside the sandbox (Full access, or an approved escalation); Limare's reserved
    /// paths stay closed either way.
    let unconfined: Bool
    /// The folder the sandbox lets the command write (with temp): the workspace, as Codex's
    /// writable root is the session's working directory, not each command's `cwd`.
    let writableRoot: URL

    init(
        command: String,
        cwd: URL,
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval = 120,
        boundary: ShellExecutionBoundary = .primaryInteractive,
        unconfined: Bool = false,
        writableRoot: URL? = nil
    ) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.boundary = boundary
        self.unconfined = unconfined
        self.writableRoot = writableRoot ?? cwd
    }
}

enum ShellOutputStream: String, Codable, Sendable {
    case stdout
    case stderr
}

struct ShellExecutionResult: Sendable {
    let stdout: String
    let stderr: String
    let stdoutOriginalByteCount: Int
    let stderrOriginalByteCount: Int
    let exitCode: Int32?
    let durationMilliseconds: Int
    let timedOut: Bool
    let cancelled: Bool
    let truncated: Bool
    var processID: Int32? = nil
    var processGroupID: Int32? = nil
    var processExitObserved: Bool = false
    /// Only the original process group is observed. Detached descendants and
    /// prior external effects are not represented as stopped/reverted.
    var originalProcessGroupAbsent: Bool? = nil
}

enum ShellStreamEvent: Sendable {
    case output(stream: ShellOutputStream, sequence: Int, elapsedMilliseconds: Int, text: String)
    case finished(ShellExecutionResult)
}

enum ShellRunnerError: LocalizedError {
    case emptyCommand
    case invalidWorkingDirectory(String)
    case spawnFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "shell_execute requires a non-empty command."
        case .invalidWorkingDirectory(let path): "Shell working directory does not exist: \(path)"
        case .spawnFailed(let message): "Could not start shell: \(message)"
        }
    }
}
