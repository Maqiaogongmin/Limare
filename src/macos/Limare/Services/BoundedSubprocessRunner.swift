import Foundation
import Darwin

/// Process facts only. No run, verification or Outcome authority.
struct BoundedSubprocessRunner: Sendable {
    struct Request: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]? = nil
        var timeoutSeconds: TimeInterval = 60
        var outputLimitBytes: Int = 4 * 1024 * 1024
        var terminationGraceSeconds: TimeInterval = 0.5
    }

    struct Outcome: Sendable {
        let exitCode: Int32?
        let launched: Bool
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
        let stderrTruncated: Bool
        let timedOut: Bool
        let cancelled: Bool
        let terminationEscalated: Bool
        let launchError: String?
    }

    func run(_ request: Request) async -> Outcome {
        let lifecycle = Lifecycle(request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lifecycle.start(continuation)
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    /// All mutable state, pipe callbacks, deadlines and completion are serialized here.
    /// Nonblocking reads never wait for EOF held by a descendant of the launched process.
    private final class Lifecycle: @unchecked Sendable {
        let queue = DispatchQueue(label: "limare.bounded-subprocess")
        let request: Request
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var readers: [DispatchSourceRead] = []
        var endedReaders: Set<Int32> = []
        let outputFD: Int32
        let errorFD: Int32
        var timer: DispatchSourceTimer?
        var continuation: CheckedContinuation<Outcome, Never>?
        var output = Data()
        var errors = Data()
        var outputTruncated = false
        var errorTruncated = false
        var cancelled = false
        var timedOut = false
        var launched = false
        var escalated = false
        var completed = false
        var stopping = false
        var launchError: String?

        init(_ request: Request) {
            self.request = request
            outputFD = outputPipe.fileHandleForReading.fileDescriptor
            errorFD = errorPipe.fileHandleForReading.fileDescriptor
        }

        func start(_ continuation: CheckedContinuation<Outcome, Never>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !self.cancelled else { self.finish(); return }
                guard self.request.timeoutSeconds.isFinite, self.request.timeoutSeconds > 0,
                      self.request.terminationGraceSeconds.isFinite, self.request.terminationGraceSeconds > 0,
                      self.request.outputLimitBytes >= 0 else {
                    self.launchError = "Invalid subprocess lifecycle bounds"
                    self.finish()
                    return
                }
                self.process.executableURL = self.request.executable
                self.process.arguments = self.request.arguments
                self.process.environment = self.request.environment
                self.process.standardOutput = self.outputPipe
                self.process.standardError = self.errorPipe
                self.process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        guard !self.completed else { return }
                        // Brief bounded drain grace for final bytes; no dependence on pipe EOF.
                        self.arm(after: 0.1) { self.finish() }
                    }
                }
                self.installReader(self.outputPipe.fileHandleForReading, isError: false)
                self.installReader(self.errorPipe.fileHandleForReading, isError: true)
                do {
                    try self.process.run()
                    self.launched = true
                    try? self.outputPipe.fileHandleForWriting.close()
                    try? self.errorPipe.fileHandleForWriting.close()
                    self.arm(after: self.request.timeoutSeconds) {
                        if self.process.isRunning {
                            self.timedOut = true
                            self.stop()
                        } else {
                            self.finish()
                        }
                    }
                } catch {
                    self.launchError = error.localizedDescription
                    self.finish()
                }
            }
        }

        func cancel() {
            queue.async {
                guard !self.completed else { return }
                self.cancelled = true
                if self.launched { self.stop() }
                // Cancellation before start is remembered; start completes its continuation.
            }
        }

        func installReader(_ handle: FileHandle, isError: Bool) {
            let fd = handle.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let index = readers.count
            reader.setEventHandler { [weak self] in
                guard let self, !self.completed else { return }
                if self.drain(fd, isError: isError) {
                    self.endedReaders.insert(fd)
                    self.readers[index].cancel()
                }
            }
            // Closing occurs after cancelled read callbacks on the same serial queue.
            reader.setCancelHandler { try? handle.close() }
            readers.append(reader)
            reader.resume()
        }

        func drain(_ fd: Int32, isError: Bool) -> Bool {
            guard !completed, !endedReaders.contains(fd) else { return false }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            // Limit callback work so an output flood cannot starve cancellation/deadlines.
            for _ in 0..<16 {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count == 0 { return true }
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno != EAGAIN && errno != EWOULDBLOCK
                }
                let retained = isError ? errors.count : output.count
                let keep = min(count, max(0, request.outputLimitBytes - retained))
                if isError {
                    errors.append(contentsOf: bytes.prefix(keep))
                    errorTruncated = errorTruncated || keep < count
                } else {
                    output.append(contentsOf: bytes.prefix(keep))
                    outputTruncated = outputTruncated || keep < count
                }
            }
            return false
        }

        func arm(after seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) {
            timer?.cancel()
            let next = DispatchSource.makeTimerSource(queue: queue)
            next.schedule(deadline: .now() + seconds)
            next.setEventHandler(handler: action)
            timer = next
            next.resume()
        }

        func stop() {
            guard !stopping else { return }
            stopping = true
            if process.isRunning { process.terminate() }
            arm(after: request.terminationGraceSeconds) {
                if self.process.isRunning {
                    // Exact Process instance/PID only, never scan or kill a process tree.
                    self.escalated = true
                    _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
                }
                // Even kill/reap/descendant-held pipe EOF cannot extend cleanup indefinitely.
                self.arm(after: self.request.terminationGraceSeconds) { self.finish() }
            }
        }

        func finish() {
            guard !completed, let continuation else { return }
            if !readers.isEmpty {
                _ = drain(outputFD, isError: false)
                _ = drain(errorFD, isError: true)
            } else {
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
            }
            completed = true
            timer?.cancel()
            timer = nil
            process.terminationHandler = nil
            readers.forEach { $0.cancel() }
            readers.removeAll()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            self.continuation = nil
            continuation.resume(returning: Outcome(
                exitCode: launched && !process.isRunning ? process.terminationStatus : nil,
                launched: launched,
                stdout: String(decoding: output, as: UTF8.self),
                stderr: String(decoding: errors, as: UTF8.self),
                stdoutTruncated: outputTruncated, stderrTruncated: errorTruncated,
                timedOut: timedOut, cancelled: cancelled,
                terminationEscalated: escalated, launchError: launchError
            ))
        }
    }
}
