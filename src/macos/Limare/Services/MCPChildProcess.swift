import Foundation
import Darwin

/// Native supervision of one stdio MCP server process (blueprint §11). The SDK only borrows the
/// stdin/stdout descriptors; spawning, stderr, exit, process-group termination and reaping live here.
final class MCPChildProcess: @unchecked Sendable {
    /// The parent's ends: SDK `StdioTransport(input: stdout, output: stdin)`.
    let stdout: Int32
    let stdin: Int32
    let pid: pid_t

    private let lock = NSLock()
    private var stderrTail = Data()
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private var descriptorsClosed = false
    private let exitSource: DispatchSourceProcess
    private let stderrSource: DispatchSourceRead
    private static let stderrLimit = 4096

    /// Spawns `executable` in its own process group with exactly stdin/stdout/stderr inherited
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`) and the given environment.
    init(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            throw MCPTransportError.spawnFailed(String(cString: strerror(errno)))
        }
        for fd in [inPipe[1], outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Writing after the child exits must fail with EPIPE, not signal Limare.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t(), emptyMask = sigset_t()
        sigfillset(&defaultSignals)
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        for fd in [inPipe[0], outPipe[1], errPipe[1]] { close(fd) }
        guard status == 0 else {
            for fd in [inPipe[1], outPipe[0], errPipe[0]] { close(fd) }
            throw MCPTransportError.spawnFailed(String(cString: strerror(status)))
        }
        pid = child
        stdin = inPipe[1]
        stdout = outPipe[0]

        stderrSource = DispatchSource.makeReadSource(fileDescriptor: errPipe[0], queue: .global(qos: .utility))
        exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global(qos: .utility))
        let stderrFD = errPipe[0]
        stderrSource.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(stderrFD, &buffer, buffer.count)
            guard count > 0 else { self?.stderrSource.cancel(); return }
            self?.appendStderr(Data(buffer[0..<count]))
        }
        stderrSource.setCancelHandler { close(stderrFD) }
        exitSource.setEventHandler { [weak self] in
            guard let self, let code = self.reapOnce() else { return }
            self.exitSource.cancel()
            onExit(code)
        }
        stderrSource.resume()
        exitSource.resume()
        // The child may have exited before the source was armed.
        if let code = reapOnce() { exitSource.cancel(); onExit(code) }
    }

    deinit {
        closeDescriptors()
        exitSource.cancel()
        stderrSource.cancel()
    }

    /// The exit code once the child has been reaped.
    var exitCode: Int32? { lock.withLock { exitStatus } }

    /// Bounded tail of the child's stderr; native diagnostics only, never model input.
    var recentStderr: String {
        lock.withLock { String(decoding: stderrTail, as: UTF8.self) }
    }

    /// Closes the parent's descriptors, sends SIGTERM to the whole process group, then SIGKILL
    /// after `grace` if it is still alive, and waits until the child is reaped.
    func terminate(grace: Duration = .seconds(2)) async {
        closeDescriptors()
        guard lock.withLock({ exitStatus == nil }) else {
            _ = Darwin.kill(-pid, SIGKILL) // descendants left in the group
            return
        }
        _ = Darwin.kill(-pid, SIGTERM)
        let killer = Task {
            try await Task.sleep(for: grace)
            _ = Darwin.kill(-self.pid, SIGKILL)
        }
        _ = await waitForExit()
        killer.cancel()
        // Descendants that left the group's leader behind still share the group.
        _ = Darwin.kill(-pid, SIGKILL)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let code: Int32? = lock.withLock {
                if let exitStatus { return exitStatus }
                exitWaiters.append(continuation)
                return nil
            }
            if let code { continuation.resume(returning: code) }
        }
    }

    private func closeDescriptors() {
        let shouldClose = lock.withLock { () -> Bool in
            defer { descriptorsClosed = true }
            return !descriptorsClosed
        }
        guard shouldClose else { return }
        close(stdin)
        close(stdout)
    }

    private func appendStderr(_ data: Data) {
        lock.withLock {
            stderrTail.append(data)
            if stderrTail.count > Self.stderrLimit { stderrTail = stderrTail.suffix(Self.stderrLimit) }
        }
    }

    /// Reaps the child; returns its exit code (128 + signal when killed) only to the first caller
    /// that observes the exit, so the exit is reported once.
    private func reapOnce() -> Int32? {
        lock.lock()
        if exitStatus != nil { lock.unlock(); return nil }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { lock.unlock(); return nil }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        exitStatus = code
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: code) }
        return code
    }
}
