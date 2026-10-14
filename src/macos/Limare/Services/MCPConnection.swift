import Foundation
#if canImport(MCP)
import System
import MCP

/// One live session with a configured MCP server (blueprint §10–§12). The SDK owns framing,
/// JSON-RPC, the initialize handshake, request correlation, Streamable HTTP/SSE and cancellation
/// notifications. This adapter only lends it a supervised child process or a Host-owned URLSession,
/// applies Host deadlines and projects tool results into Limare's model.
actor MCPConnection {
    enum Event: Sendable {
        /// The stdio server process ended on its own.
        case exited(code: Int32)
        /// The server sent `notifications/tools/list_changed`.
        case toolListChanged
    }

    private static let initializeTimeoutSeconds = 30
    private static let listTimeoutSeconds = 30

    /// Secrets are already resolved; this value never leaves the Host.
    private let config: MCPServerConfig
    private let workspaceURL: URL
    private let onEvent: @Sendable (Event) async -> Void
    private var client: Client?
    /// The client while its initialize handshake runs.
    private var handshakeClient: Client?
    private var child: MCPChildProcess?
    private var session: URLSession?
    private var connecting: Task<Void, Error>?

    init(config: MCPServerConfig, workspaceURL: URL, onEvent: @escaping @Sendable (Event) async -> Void) {
        self.config = config
        self.workspaceURL = workspaceURL
        self.onEvent = onEvent
    }

    var isConnected: Bool { client != nil }

    func ensureConnected() async throws {
        if client != nil { return }
        if let connecting { return try await connecting.value }
        let attempt = Task { try await connect() }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    /// Ends the SDK session, then closes the borrowed descriptors and terminates the process group.
    func stop() async {
        connecting?.cancel()
        let client = self.client, child = self.child, session = self.session
        self.client = nil
        self.child = nil
        self.session = nil
        await client?.disconnect()
        await child?.terminate()
        session?.invalidateAndCancel()
    }

    /// The complete tool list, following SDK pagination. Only a complete list replaces the catalog.
    func listTools() async throws -> [MCPTool] {
        guard let client else { throw MCPTransportError.connectionClosed }
        do {
            return try await Self.deadline(seconds: Self.listTimeoutSeconds) {
                var tools: [MCPTool] = []
                var cursor: String?
                repeat {
                    let page = try await client.listTools(cursor: cursor)
                    tools += page.tools.map { tool in
                        let schema = (try? JSONEncoder().encode(tool.inputSchema))
                            .flatMap { try? JSONDecoder().decode(AnyCodable.self, from: $0) } ?? AnyCodable.defaultObjectSchema
                        return MCPTool(serverID: self.config.id, name: tool.name, description: tool.description ?? "", inputSchema: schema)
                    }
                    cursor = page.nextCursor
                } while cursor != nil
                return tools
            }
        } catch {
            throw await classify(error)
        }
    }

    /// Calls a tool on the session whose tools were discovered; never starts a new session.
    /// Swift Task cancellation is forwarded explicitly as an MCP cancellation for this request.
    func callTool(name: String, arguments: [String: AnyCodable], conversationID: UUID? = nil,
                  artifactStore: ArtifactStore? = nil) async throws -> MCPToolCallResult {
        guard let client else { throw MCPTransportError.connectionClosed }
        do {
            let values = try JSONDecoder().decode([String: Value].self, from: JSONEncoder().encode(arguments))
            let context: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: values)
            let result = try await Self.deadline(seconds: MCPServerConfig.toolCallTimeoutSeconds) {
                try await withTaskCancellationHandler {
                    try await context.value
                } onCancel: {
                    Task { try? await client.cancelRequest(context.requestID, reason: "Cancelled in Limare") }
                }
            }
            let content = (try? JSONDecoder().decode([AnyCodable].self, from: JSONEncoder().encode(result.content))) ?? []
            let raw = try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(result))
            return MCPToolResultProjector.project(contentItems: content, rawResult: raw, isError: result.isError ?? false,
                                                  conversationID: conversationID, artifactStore: artifactStore)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await classify(error)
        }
    }

    private func connect() async throws {
        let transport: any Transport
        if config.isHTTP {
            guard let urlString = config.url, let endpoint = URL(string: urlString) else {
                throw MCPTransportError.invalidURL("Invalid server URL.")
            }
            let session = URLSession(configuration: Self.sessionConfiguration(), delegate: MCPHTTPSessionPolicy(), delegateQueue: nil)
            let headers = config.headers ?? [:]
            self.session = session
            transport = HTTPClientTransport(endpoint: endpoint, session: session, streaming: true, requestModifier: { request in
                var request = request
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                return request
            })
        } else {
            let child = try spawn(loginPATH: await LoginShellEnvironment.path())
            self.child = child
            transport = StdioTransport(input: FileDescriptor(rawValue: child.stdout), output: FileDescriptor(rawValue: child.stdin))
        }
        let client = Client(name: "Limare", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
        let onEvent = self.onEvent
        await client.onNotification(ToolListChangedNotification.self) { _ in await onEvent(.toolListChanged) }
        handshakeClient = client
        defer { handshakeClient = nil }
        do {
            let timeout = config.isHTTP ? Self.initializeTimeoutSeconds : (config.startupTimeoutSeconds ?? Self.initializeTimeoutSeconds)
            _ = try await Self.deadline(seconds: timeout) { try await client.connect(transport: transport) }
            self.client = client
        } catch {
            let classified = await classify(error)
            await client.disconnect()
            await child?.terminate()
            session?.invalidateAndCancel()
            child = nil
            session = nil
            throw classified
        }
    }

    /// The server program runs under the inherited Seatbelt policy, in its own process group, with
    /// a filtered environment plus its configured (resolved) variables.
    private func spawn(loginPATH: String?) throws -> MCPChildProcess {
        guard let command = config.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            throw MCPTransportError.commandNotFound("Command is empty")
        }
        if command.hasPrefix("/") && !FileManager.default.fileExists(atPath: command) {
            throw MCPTransportError.commandNotFound("Executable not found at path '\(command)'")
        }
        let launch = try MCPExecutionPolicy.launch(executable: "/bin/zsh", arguments: ["-c", "exec \"$@\"", "--", command] + (config.args ?? []),
                                                   workspace: workspaceURL)
        let parent = ProcessInfo.processInfo.environment
        var environment = parent.filter { ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"].contains($0.key) || $0.key.hasPrefix("LC_") }
        let home = environment["HOME"] ?? NSHomeDirectory()
        environment["HOME"] = home
        environment["SHELL"] = environment["SHELL"] ?? "/bin/zsh"
        environment["TMPDIR"] = environment["TMPDIR"] ?? NSTemporaryDirectory()
        // npx, uvx and the like are found where the user's shell finds them.
        if let loginPATH { environment["PATH"] = loginPATH }
        for (name, value) in config.env ?? [:] { environment[name] = value }

        let onEvent = self.onEvent
        return try MCPChildProcess(executable: launch.0.path, arguments: launch.1, environment: environment,
                                   workingDirectory: workspaceURL) { [weak self] code in
            Task {
                await self?.childExited()
                await onEvent(.exited(code: code))
            }
        }
    }

    /// The SDK keeps requests pending when the stream ends; ending the session fails them now, and
    /// `classify` reports the process exit.
    private func childExited() async {
        guard let client = client ?? handshakeClient else { return }
        self.client = nil
        handshakeClient = nil
        await client.disconnect()
    }

    /// A stdio failure caused by the process ending reports how it ended.
    private func classify(_ error: Error) async -> MCPTransportError {
        if let child, !(error is MCPTransportError) {
            // EOF can arrive just before the exit is reaped.
            for _ in 0..<20 where child.exitCode == nil { try? await Task.sleep(for: .milliseconds(50)) }
            if let exit = child.exitCode {
                let stderr = child.recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if exit == 127 || stderr.lowercased().contains("not found") {
                    return .commandNotFound(stderr.isEmpty ? "Command not found (exit code 127)" : stderr)
                }
                return .processExited(exitCode: exit, stderr: stderr)
            }
        }
        return MCPErrorClassifier.classify(error, url: config.url)
    }

    /// Ephemeral: no cookies, cache or shared credential storage; long enough for a tool call's stream.
    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(MCPServerConfig.toolCallTimeoutSeconds)
        return configuration
    }

    /// Returns at the deadline even if the operation ignores cancellation; the operation is then
    /// cancelled (an SDK request sends its MCP cancellation) and the caller tears the session down.
    private static func deadline<T: Sendable>(seconds: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation: continuation, seconds: seconds, operation: operation)
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

}

#else
/// Script test runners that compile the app sources without the SDK get a connection that cannot
/// connect. The app target always links the SDK; there is no protocol fallback.
actor MCPConnection {
    enum Event: Sendable { case exited(code: Int32), toolListChanged }
    init(config: MCPServerConfig, workspaceURL: URL, onEvent: @escaping @Sendable (Event) async -> Void) {}
    var isConnected: Bool { false }
    func ensureConnected() async throws { throw MCPTransportError.spawnFailed("MCP SDK not linked in this test build.") }
    func stop() async {}
    func listTools() async throws -> [MCPTool] { throw MCPTransportError.connectionClosed }
    func callTool(name: String, arguments: [String: AnyCodable], conversationID: UUID? = nil,
                  artifactStore: ArtifactStore? = nil) async throws -> MCPToolCallResult { throw MCPTransportError.connectionClosed }
}
#endif

/// First outcome wins: the operation's result, the deadline, or the caller's cancellation.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    func start(continuation: CheckedContinuation<T, Error>, seconds: Int, operation: @escaping @Sendable () async throws -> T) {
        lock.withLock {
            self.continuation = continuation
            work = Task { [self] in
                do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
            }
            timer = Task { [self] in
                guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
                finish(.failure(MCPTransportError.timeout(seconds: seconds)))
            }
            if finished { work?.cancel(); timer?.cancel() }
        }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, work, timer) = lock.withLock { () -> (CheckedContinuation<T, Error>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !finished else { return (nil, nil, nil) }
            finished = true
            defer { self.continuation = nil }
            return (self.continuation, self.work, self.timer)
        }
        timer?.cancel()
        if case .failure = result { work?.cancel() }
        continuation?.resume(with: result)
    }
}

/// The Host's HTTP policy for MCP sessions: redirects are refused (a configured credential header
/// never follows one), and only server-trust challenges get default TLS evaluation; password,
/// client-certificate and proxy challenges are cancelled rather than answered from stored credentials.
final class MCPHTTPSessionPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
