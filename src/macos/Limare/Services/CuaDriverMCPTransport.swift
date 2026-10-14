import Foundation

/// Outcome of attempting to stop a driver child process.
public enum DriverTerminationResult: Equatable, Sendable {
    case confirmedTerminated
    case timeoutStillRunning(pid: Int32)
}

/// Internal dedicated stdio JSON-RPC transport for Computer Use v0.2's `cua-driver mcp --direct` child process.
///
/// Implements Option C2 direct child management over anonymous pipes with line-delimited
/// JSON-RPC 2.0 framing, strictly bounded stdout buffer (1 MiB default), bounded stderr
/// diagnostic capture, monotonic request IDs, generation tagging, and truthful termination verification.
/// Type-safe Sendable wrapper for raw JSON-RPC dictionary response frames.
public struct MCPResponseBox: @unchecked Sendable {
    public let value: [String: Any]
    public init(_ value: [String: Any]) { self.value = value }
    public subscript(key: String) -> Any? { value[key] }
}

actor CuaDriverMCPTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<MCPResponseBox, Error>
        let timeoutTask: Task<Void, Never>?
    }

    public static let defaultMaxFrameSizeBytes: Int = 1_048_576 // 1 MiB

    public let generation: Int
    public let maxFrameSizeBytes: Int

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private var nextRequestID: Int = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var recentStderr: String = ""
    private var isStopping: Bool = false
    private var isDead: Bool = false

    private var stdoutReaderTask: Task<Void, Never>?
    private var stderrReaderTask: Task<Void, Never>?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var stderrContinuation: AsyncStream<String>.Continuation?

    /// Test seam allowing simulated liveness behavior (used for F5 shutdown timeout test).
    public var processLivenessChecker: (@Sendable (Process) -> Bool)?

    /// Spawn observer test seam allowing callers to capture the real OS PID on launch.
    public var onProcessSpawned: (@Sendable (Int32) -> Void)?

    private let onUnexpectedTermination: @Sendable (Int32, String?) -> Void
    private let onChannelFailure: @Sendable (ComputerUseDriverError, DriverTerminationResult) -> Void

    public init(
        generation: Int,
        maxFrameSizeBytes: Int = defaultMaxFrameSizeBytes,
        processLivenessChecker: (@Sendable (Process) -> Bool)? = nil,
        onProcessSpawned: (@Sendable (Int32) -> Void)? = nil,
        onUnexpectedTermination: @escaping @Sendable (Int32, String?) -> Void,
        onChannelFailure: @escaping @Sendable (ComputerUseDriverError, DriverTerminationResult) -> Void
    ) {
        self.generation = generation
        self.maxFrameSizeBytes = maxFrameSizeBytes
        self.processLivenessChecker = processLivenessChecker
        self.onProcessSpawned = onProcessSpawned
        self.onUnexpectedTermination = onUnexpectedTermination
        self.onChannelFailure = onChannelFailure
    }

    public func setProcessLivenessChecker(_ checker: (@Sendable (Process) -> Bool)?) {
        self.processLivenessChecker = checker
    }

    /// Spawns the driver child process directly (NO shell) and hooks anonymous pipes.
    public func start(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ComputerUseDriverError.driverExecutableMissing(path: executableURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ComputerUseDriverError.driverNotExecutable(path: executableURL.path)
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
        self.stderrHandle = errPipe.fileHandleForReading
        self.isStopping = false
        self.isDead = false
        self.stdoutBuffer.removeAll()
        self.recentStderr = ""

        let outH = outPipe.fileHandleForReading
        let errH = errPipe.fileHandleForReading

        let (outStream, outCont) = AsyncStream<Data>.makeStream()
        let (errStream, errCont) = AsyncStream<String>.makeStream()
        self.stdoutContinuation = outCont
        self.stderrContinuation = errCont

        errH.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                errCont.finish()
            } else if let text = String(data: data, encoding: .utf8) {
                errCont.yield(text)
            }
        }

        outH.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                outCont.finish()
            } else {
                outCont.yield(data)
            }
        }

        self.stdoutReaderTask = Task { [weak self] in
            for await chunk in outStream {
                guard let self else { break }
                await self.consumeStdout(chunk)
            }
            await self?.handleStdoutEOF()
        }

        self.stderrReaderTask = Task { [weak self] in
            for await text in errStream {
                guard let self else { break }
                await self.appendStderr(text)
            }
        }

        proc.terminationHandler = { [weak self] p in
            let exitCode = p.terminationStatus
            Task { [weak self] in
                await self?.handleProcessTermination(exitCode: exitCode)
            }
        }

        do {
            try proc.run()
            let pid = proc.processIdentifier
            self.onProcessSpawned?(pid)
        } catch {
            cleanupPipes()
            throw ComputerUseDriverError.spawnFailed(reason: error.localizedDescription)
        }
    }

    /// Sends a JSON-RPC 2.0 request over stdin and awaits the matching response.
    public func sendRPC(
        method: String,
        params: [String: Any],
        timeoutSeconds: Int = 10
    ) async throws -> MCPResponseBox {
        guard let proc = process, proc.isRunning, !isStopping, !isDead else {
            throw ComputerUseDriverError.connectionClosed(detail: "Process is not running")
        }
        guard let stdin = stdinHandle else {
            throw ComputerUseDriverError.connectionClosed(detail: "Stdin pipe is closed")
        }

        let reqId = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": params
        ]

        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0a)

        let box: MCPResponseBox = try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPResponseBox, Error>) in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    } catch {
                        // Section 18: Cancelled timeout task exits immediately without executing timeout logic
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.handleTimeout(reqId: reqId, timeoutSeconds: timeoutSeconds)
                }

                pendingRequests[reqId] = PendingRequest(continuation: continuation, timeoutTask: timeoutTask)

                do {
                    try stdin.write(contentsOf: data)
                } catch {
                    pendingRequests.removeValue(forKey: reqId)
                    timeoutTask.cancel()
                    continuation.resume(throwing: ComputerUseDriverError.connectionClosed(detail: "Write to stdin failed: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingRequest(reqId: reqId)
            }
        }
        return box
    }

    private func cancelPendingRequest(reqId: Int) {
        if let pending = pendingRequests.removeValue(forKey: reqId) {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: ComputerUseDriverError.cancelled)
        }
    }

    /// Sends a JSON-RPC 2.0 notification (no response expected).
    public func sendNotification(
        method: String,
        params: [String: Any]? = nil
    ) throws {
        guard let proc = process, proc.isRunning, !isStopping, !isDead else {
            throw ComputerUseDriverError.connectionClosed(detail: "Process is not running")
        }
        guard let stdin = stdinHandle else {
            throw ComputerUseDriverError.connectionClosed(detail: "Stdin pipe is closed")
        }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            payload["params"] = params
        }

        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0a)
        try stdin.write(contentsOf: data)
    }

    /// Gracefully stops the child process, closes pipes, and verifies termination truthfully.
    /// Returns confirmedTerminated only when process is verified dead.
    public func stop(timeoutSeconds: Double = 2.0) async -> DriverTerminationResult {
        guard !isStopping else {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while let proc = process, checkIsProcessRunning(proc) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if let proc = process, checkIsProcessRunning(proc) {
                return .timeoutStillRunning(pid: proc.processIdentifier)
            }
            cleanupPipes()
            process = nil
            return .confirmedTerminated
        }
        isStopping = true

        // Disable readability handlers first to prevent callbacks during shutdown
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil

        // Close stdin to signal EOF to child
        try? stdinHandle?.close()
        stdinHandle = nil

        // Fail pending requests
        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: ComputerUseDriverError.connectionClosed(detail: "Driver stopped"))
        }
        pendingRequests.removeAll()

        return await terminateAndVerifyProcess(timeoutSeconds: timeoutSeconds)
    }

    /// CU2-S1-I18: Causally terminates the child process and verifies death via deadline polling.
    private func terminateAndVerifyProcess(timeoutSeconds: Double = 0.5) async -> DriverTerminationResult {
        guard let proc = process, checkIsProcessRunning(proc) else {
            cleanupPipes()
            process = nil
            return .confirmedTerminated
        }

        // Attempt graceful SIGTERM
        proc.terminate()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while checkIsProcessRunning(proc) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // If still running, escalate to SIGKILL
        if checkIsProcessRunning(proc) {
            kill(proc.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while checkIsProcessRunning(proc) && Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        // CU2-S1-I18 Truthful Verification: check if process is ACTUALLY dead
        if checkIsProcessRunning(proc) {
            // Did not terminate! Do NOT discard process handle so PID is preserved.
            return .timeoutStillRunning(pid: proc.processIdentifier)
        } else {
            cleanupPipes()
            process = nil
            return .confirmedTerminated
        }
    }

    private func checkIsProcessRunning(_ proc: Process) -> Bool {
        if let customChecker = processLivenessChecker {
            return customChecker(proc)
        }
        return proc.isRunning && (kill(proc.processIdentifier, 0) == 0)
    }

    public var runningPID: Int32? {
        guard let p = process, checkIsProcessRunning(p) else { return nil }
        return p.processIdentifier
    }

    public var recentStderrTail: String {
        recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Handlers

    private func appendStderr(_ text: String) {
        recentStderr += text
        // Keep bounded to last 4096 characters
        if recentStderr.count > 4096 {
            recentStderr = String(recentStderr.suffix(4096))
        }
    }

    private func consumeStdout(_ data: Data) async {
        guard !isDead else { return }

        stdoutBuffer.append(data)

        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0a) {
            // F1: Check individual frame limit
            if newlineIndex > maxFrameSizeBytes {
                await handleOversizedBuffer()
                return
            }

            let lineData = stdoutBuffer.subdata(in: 0..<newlineIndex)
            stdoutBuffer.removeSubrange(0...newlineIndex)

            // Ignore empty lines
            if lineData.isEmpty { continue }

            do {
                guard let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    handleMalformedMessage(detail: "Line is not a valid JSON object")
                    continue
                }
                handleIncomingMessage(json)
            } catch {
                handleMalformedMessage(detail: "JSON parse failed: \(error.localizedDescription)")
            }
        }

        // F1: If accumulated unterminated bytes exceed maxFrameSizeBytes before newline arrives, fail closed!
        if stdoutBuffer.count > maxFrameSizeBytes {
            await handleOversizedBuffer()
            return
        }
    }

    private func handleOversizedBuffer() async {
        guard !isDead else { return }
        isDead = true
        isStopping = true

        stdoutBuffer.removeAll()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil

        let err = ComputerUseDriverError.protocolFrameTooLarge(limit: maxFrameSizeBytes)

        // CU2-S1-I18: Causally terminate and verify child death before notifying backend
        let termResult = await terminateAndVerifyProcess(timeoutSeconds: 0.5)

        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: err)
        }
        pendingRequests.removeAll()

        onChannelFailure(err, termResult)
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        guard let idVal = message["id"] else {
            // Notification from driver; ignore in Stage 1
            return
        }

        let reqId: Int?
        if let i = idVal as? Int {
            reqId = i
        } else if let num = idVal as? NSNumber {
            reqId = num.intValue
        } else if let str = idVal as? String, let parsed = Int(str) {
            reqId = parsed
        } else {
            reqId = nil
        }

        guard let id = reqId, let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }

        pending.timeoutTask?.cancel()

        if let errorDict = message["error"] as? [String: Any] {
            let msg = errorDict["message"] as? String ?? "MCP error"
            pending.continuation.resume(throwing: ComputerUseDriverError.handshakeFailed(reason: msg))
        } else {
            pending.continuation.resume(returning: MCPResponseBox(message))
        }
    }

    private func handleMalformedMessage(detail: String) {
        if let oldestKey = pendingRequests.keys.sorted().first,
           let pending = pendingRequests.removeValue(forKey: oldestKey) {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: ComputerUseDriverError.protocolMalformed(detail: detail))
        }
    }

    private func handleTimeout(reqId: Int, timeoutSeconds: Int) {
        guard !isStopping && !isDead else { return }
        if let pending = pendingRequests.removeValue(forKey: reqId) {
            pending.continuation.resume(throwing: ComputerUseDriverError.connectionClosed(detail: "Request id \(reqId) timed out after \(timeoutSeconds)s"))
        }
    }

    /// F2 & Invariant S1-I17: Unexpected stdout EOF invalidates readiness and marks channel dead.
    private func handleStdoutEOF() async {
        guard !isStopping && !isDead else { return }

        // If child process died/exited, give it up to 50ms to register process termination
        // so that unexpectedExit(statusCode:) with stderr tail is preserved for pending requests!
        if let proc = process {
            let deadline = Date().addingTimeInterval(0.05)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            guard !isStopping && !isDead else { return }

            if !proc.isRunning {
                handleProcessTermination(exitCode: proc.terminationStatus)
                return
            }
        }

        // Child process is genuinely still alive, but its stdout descriptor reached EOF.
        // Pure channel failure (F2).
        isDead = true
        isStopping = true

        stdoutBuffer.removeAll()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        stdinHandle = nil

        let err = ComputerUseDriverError.connectionClosed(detail: "Unexpected stdout EOF")

        // CU2-S1-I18: Causally terminate and verify child death before notifying backend
        let termResult = await terminateAndVerifyProcess(timeoutSeconds: 0.5)

        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: err)
        }
        pendingRequests.removeAll()

        onChannelFailure(err, termResult)
    }

    private func handleProcessTermination(exitCode: Int32) {
        guard !isStopping && !isDead else { return }
        isStopping = true
        isDead = true

        let tail = recentStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrTail = tail.isEmpty ? nil : tail

        // Fail pending requests exactly once
        for (_, pending) in pendingRequests {
            pending.timeoutTask?.cancel()
            pending.continuation.resume(throwing: ComputerUseDriverError.unexpectedExit(statusCode: exitCode, stderrTail: stderrTail))
        }
        pendingRequests.removeAll()
        cleanupPipes()

        onUnexpectedTermination(exitCode, stderrTail)
    }

    private func cleanupPipes() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutContinuation?.finish()
        stderrContinuation?.finish()
        stdoutReaderTask?.cancel()
        stderrReaderTask?.cancel()
        stdoutContinuation = nil
        stderrContinuation = nil
        stdoutReaderTask = nil
        stderrReaderTask = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
    }
}
