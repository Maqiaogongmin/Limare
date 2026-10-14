@preconcurrency import Foundation
import Darwin

struct ShellRunner: Sendable {
    func stream(_ request: ShellExecutionRequest, onTerminationObserved: (@Sendable (ShellExecutionResult) -> Void)? = nil) -> AsyncThrowingStream<ShellStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let execution = ShellExecution(request: request, continuation: continuation, onTerminationObserved: onTerminationObserved)
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason {
                    execution.cancel()
                }
            }
            do {
                try execution.start()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

private final class ShellExecution: @unchecked Sendable {
    private let onTerminationObserved: (@Sendable (ShellExecutionResult) -> Void)?
    private let request: ShellExecutionRequest
    private let continuation: AsyncThrowingStream<ShellStreamEvent, Error>.Continuation
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutDecoder = IncrementalUTF8Decoder()
    private var stderrDecoder = IncrementalUTF8Decoder()
    private var stdoutBuffer = BoundedTextBuffer()
    private var stderrBuffer = BoundedTextBuffer()
    private var sequence = 0
    private var startedAt = ContinuousClock.now
    private var stdoutEnded = false
    private var stderrEnded = false
    private var processEnded = false
    private var didFinish = false
    private var timedOut = false
    private var cancelled = false
    private var processLaunched = false
    private var processPID: pid_t = 0
    private var ownsProcessGroup = false

    init(
        request: ShellExecutionRequest,
        continuation: AsyncThrowingStream<ShellStreamEvent, Error>.Continuation,
        onTerminationObserved: (@Sendable (ShellExecutionResult) -> Void)?
    ) {
        self.onTerminationObserved = onTerminationObserved
        self.request = request
        self.continuation = continuation
    }

    func start() throws {
        lock.lock()
        if cancelled {
            didFinish = true
            lock.unlock()
            throw CancellationError()
        }
        lock.unlock()

        guard !request.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lock.lock()
            didFinish = true
            lock.unlock()
            throw ShellRunnerError.emptyCommand
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.cwd.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            lock.lock()
            didFinish = true
            lock.unlock()
            throw ShellRunnerError.invalidWorkingDirectory(request.cwd.path)
        }

        switch request.boundary {
        case .primaryInteractive:
            let launch = try MCPExecutionPolicy.launch(executable: "/bin/zsh", arguments: ["-c", request.command], workspace: request.writableRoot,
                                                        unconfined: request.unconfined)
            process.executableURL = launch.0
            process.arguments = launch.1
            let allowed: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"]
            var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
            request.environment.forEach { environment[$0.key] = $0.value }
            process.environment = environment
        }

        process.currentDirectoryURL = request.cwd
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stream: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData, stream: .stderr)
        }
        process.terminationHandler = { [weak self] _ in
            self?.markProcessEnded()
        }

        startedAt = .now
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            didFinish = true
            lock.unlock()
            throw ShellRunnerError.spawnFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        guard pid > 0 else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            didFinish = true
            lock.unlock()
            throw ShellRunnerError.spawnFailed("Process spawned with invalid PID: \(pid)")
        }

        lock.lock()
        processLaunched = true
        processPID = pid
        ownsProcessGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        let shouldStop = cancelled || timedOut
        lock.unlock()

        if shouldStop {
            stopProcess(cancelled: false, timedOut: false)
            return
        }

        if request.timeoutSeconds > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + request.timeoutSeconds) { [weak self] in
                self?.timeout()
            }
        }
    }

    func cancel() {
        stopProcess(cancelled: true, timedOut: false)
    }

    private func timeout() {
        stopProcess(cancelled: false, timedOut: true)
    }

    private func stopProcess(cancelled: Bool, timedOut: Bool) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        self.cancelled = self.cancelled || cancelled
        self.timedOut = self.timedOut || timedOut
        guard processLaunched, processPID > 0,
              ownsProcessGroup || (!processEnded && !didFinish) else {
            lock.unlock()
            return
        }
        let pid = processPID
        let useGroup = ownsProcessGroup
        lock.unlock()

        send(signal: SIGINT, pid: pid, processGroup: useGroup)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.escalate(signal: SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.escalate(signal: SIGKILL)
        }
    }

    private func escalate(signal: Int32) {
        lock.lock()
        // The shell may exit on SIGINT while a background descendant ignores it.
        // Continue escalation for the owned group until it is actually absent.
        guard processLaunched, processPID > 0,
              ownsProcessGroup || (!processEnded && !didFinish) else {
            lock.unlock()
            return
        }
        let pid = processPID
        let useGroup = ownsProcessGroup
        lock.unlock()
        if useGroup, Darwin.kill(-pid, 0) == -1, errno == ESRCH { return }
        send(signal: signal, pid: pid, processGroup: useGroup)
    }

    private func send(signal: Int32, pid: Int32, processGroup: Bool) {
        guard pid > 0 else { return }
        Darwin.kill(processGroup ? -pid : pid, signal)
    }

    private func consume(_ data: Data, stream: ShellOutputStream) {
        lock.lock()
        if data.isEmpty {
            let finalText: String
            switch stream {
            case .stdout:
                finalText = stdoutDecoder.finish()
                stdoutBuffer.append(finalText)
                stdoutEnded = true
            case .stderr:
                finalText = stderrDecoder.finish()
                stderrBuffer.append(finalText)
                stderrEnded = true
            }
            let event = makeOutputEvent(stream: stream, text: finalText)
            let result = makeResultIfReady()
            lock.unlock()
            if let event { continuation.yield(event) }
            finishIfReady(result)
            return
        }

        let text: String
        switch stream {
        case .stdout:
            text = stdoutDecoder.append(data)
            stdoutBuffer.append(text)
        case .stderr:
            text = stderrDecoder.append(data)
            stderrBuffer.append(text)
        }
        let event = makeOutputEvent(stream: stream, text: text)
        lock.unlock()
        if let event { continuation.yield(event) }
    }

    private func markProcessEnded() {
        lock.lock()
        processEnded = true
        let result = makeResultIfReady()
        lock.unlock()
        finishIfReady(result)
    }

    private func makeOutputEvent(stream: ShellOutputStream, text: String) -> ShellStreamEvent? {
        guard !text.isEmpty else { return nil }
        sequence += 1
        return .output(
            stream: stream,
            sequence: sequence,
            elapsedMilliseconds: elapsedMilliseconds(),
            text: text
        )
    }

    private func makeResultIfReady() -> ShellExecutionResult? {
        guard processEnded, stdoutEnded, stderrEnded, !didFinish else { return nil }
        didFinish = true
        let elapsed = startedAt.duration(to: .now)
        return ShellExecutionResult(
            stdout: stdoutBuffer.text,
            stderr: stderrBuffer.text,
            stdoutOriginalByteCount: stdoutBuffer.originalByteCount,
            stderrOriginalByteCount: stderrBuffer.originalByteCount,
            exitCode: process.terminationStatus,
            durationMilliseconds: elapsedMilliseconds(elapsed),
            timedOut: timedOut,
            cancelled: cancelled,
            truncated: stdoutBuffer.truncated || stderrBuffer.truncated,
            processID: processPID > 0 ? processPID : nil,
            processGroupID: ownsProcessGroup ? processPID : nil,
            processExitObserved: processEnded,
            originalProcessGroupAbsent: ownsProcessGroup
                ? (Darwin.kill(-processPID, 0) == -1 && errno == ESRCH) : nil
        )
    }

    private func elapsedMilliseconds() -> Int {
        elapsedMilliseconds(startedAt.duration(to: .now))
    }

    private func elapsedMilliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func finishIfReady(_ result: ShellExecutionResult?) {
        guard let result else { return }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        onTerminationObserved?(result)
        continuation.yield(.finished(result))
        continuation.finish()
    }
}

private struct IncrementalUTF8Decoder {
    private var pending = Data()

    mutating func append(_ data: Data) -> String {
        pending.append(data)
        let count = completePrefixCount(in: pending)
        guard count > 0 else { return "" }
        let prefix = pending.prefix(count)
        pending.removeFirst(count)
        return String(decoding: prefix, as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return String(decoding: pending, as: UTF8.self)
    }

    private func completePrefixCount(in data: Data) -> Int {
        let bytes = Array(data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let expected: Int
            switch first {
            case 0x00...0x7F: expected = 1
            case 0xC2...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF4: expected = 4
            default: expected = 1
            }
            if index + expected > bytes.count { return index }
            if expected > 1 {
                let continuationBytes = bytes[(index + 1)..<(index + expected)]
                if continuationBytes.contains(where: { $0 & 0xC0 != 0x80 }) {
                    index += 1
                    continue
                }
            }
            index += expected
        }
        return index
    }
}

private struct BoundedTextBuffer {
    private static let maximumBytes = 1_048_576
    private static let halfBytes = maximumBytes / 2
    private var head = Data()
    private var tail = Data()
    private(set) var truncated = false
    private(set) var originalByteCount = 0

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        var incoming = Data(text.utf8)
        originalByteCount += incoming.count
        if !truncated, head.count + incoming.count <= Self.maximumBytes {
            head.append(incoming)
            return
        }
        if !truncated {
            let combined = head + incoming
            head = combined.prefix(Self.halfBytes)
            tail = combined.suffix(Self.halfBytes)
            truncated = true
            return
        }
        incoming = tail + incoming
        tail = incoming.suffix(Self.halfBytes)
    }

    var text: String {
        if truncated {
            return String(decoding: head, as: UTF8.self)
                + "\n… output truncated; original \(originalByteCount) bytes …\n"
                + String(decoding: tail, as: UTF8.self)
        }
        return String(decoding: head, as: UTF8.self)
    }
}
