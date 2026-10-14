import Foundation
import Darwin

struct HookProcessOutput: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let stdoutDataSize: Int
    let stderrDataSize: Int
    let isStdoutTruncated: Bool
    let isStderrTruncated: Bool
    let durationMilliseconds: Double
    let isTimeout: Bool
    let isCancelled: Bool
}

private final class HookProcessState: @unchecked Sendable {
    let lock = NSLock()
    var stdoutData = Data()
    var stderrData = Data()
    var isStdoutTruncated = false
    var isStderrTruncated = false
    var processEnded = false
    var exitCode: Int32 = -1
    var continuation: CheckedContinuation<Int32, Never>?
    var didTimeout = false
    var didCancel = false

    func markTimeout() {
        lock.lock()
        defer { lock.unlock() }
        didTimeout = true
    }

    func markCancelled() {
        lock.lock()
        defer { lock.unlock() }
        didCancel = true
    }

    func isTimedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeout
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    func appendStdout(_ chunk: Data, maxBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else { return }
        if stdoutData.count + chunk.count > maxBytes {
            let allowed = max(0, maxBytes - stdoutData.count)
            stdoutData.append(chunk.prefix(allowed))
            isStdoutTruncated = true
        } else {
            stdoutData.append(chunk)
        }
    }

    func appendStderr(_ chunk: Data, maxBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !chunk.isEmpty else { return }
        if stderrData.count + chunk.count > maxBytes {
            let allowed = max(0, maxBytes - stderrData.count)
            stderrData.append(chunk.prefix(allowed))
            isStderrTruncated = true
        } else {
            stderrData.append(chunk)
        }
    }

    func markEnded(status: Int32, remainingOut: Data, remainingErr: Data, maxOut: Int, maxErr: Int) {
        lock.lock()
        processEnded = true
        exitCode = status
        if !remainingOut.isEmpty {
            if stdoutData.count + remainingOut.count > maxOut {
                let allowed = max(0, maxOut - stdoutData.count)
                stdoutData.append(remainingOut.prefix(allowed))
                isStdoutTruncated = true
            } else {
                stdoutData.append(remainingOut)
            }
        }
        if !remainingErr.isEmpty {
            if stderrData.count + remainingErr.count > maxErr {
                let allowed = max(0, maxErr - stderrData.count)
                stderrData.append(remainingErr.prefix(allowed))
                isStderrTruncated = true
            } else {
                stderrData.append(remainingErr)
            }
        }
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(returning: status)
    }

    var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return processEnded
    }

    func snapshot() -> (stdoutData: Data, stderrData: Data, isStdoutTruncated: Bool, isStderrTruncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData, isStdoutTruncated, isStderrTruncated)
    }
}

actor HookCommandRunner {
    static let maxStdoutBytes = 256 * 1024 // 256 KB
    static let maxStderrBytes = 64 * 1024  // 64 KB
    static let maxAdditionalContextChars = 40_000

    let containmentPolicy: HookContainmentPolicy

    init(containmentPolicy: HookContainmentPolicy = .defaultPolicy()) {
        self.containmentPolicy = containmentPolicy
    }

    func run(
        command: String,
        packageRootURL: URL,
        workspaceURL: URL?,
        sessionID: String,
        stdinData: Data,
        timeoutSeconds: Int
    ) async -> HookProcessOutput {
        let startTime = ContinuousClock.now

        // Enforce Fail-Closed: Verify sandbox-exec availability
        guard containmentPolicy.isAvailable else {
            let err = HookContainmentError.sandboxExecutableUnavailable(path: containmentPolicy.sandboxExecutablePath)
            let errDesc = err.localizedDescription
            let duration = ContinuousClock.now - startTime
            return HookProcessOutput(
                exitCode: -1,
                stdout: "",
                stderr: errDesc,
                stdoutDataSize: 0,
                stderrDataSize: errDesc.utf8.count,
                isStdoutTruncated: false,
                isStderrTruncated: false,
                durationMilliseconds: Double(duration.components.attoseconds) / 1_000_000_000_000_000.0,
                isTimeout: false,
                isCancelled: false
            )
        }

        // Enforce Fail-Closed: Preflight check for pre-existing hard-link aliases
        do {
            try containmentPolicy.validateNoHardLinkedFiles()
        } catch {
            let errDesc = error.localizedDescription
            let duration = ContinuousClock.now - startTime
            return HookProcessOutput(
                exitCode: -1,
                stdout: "",
                stderr: errDesc,
                stdoutDataSize: 0,
                stderrDataSize: errDesc.utf8.count,
                isStdoutTruncated: false,
                isStderrTruncated: false,
                durationMilliseconds: Double(duration.components.attoseconds) / 1_000_000_000_000_000.0,
                isTimeout: false,
                isCancelled: false
            )
        }

        // Generate Seatbelt Profile
        let seatbeltProfile: String
        do {
            seatbeltProfile = try containmentPolicy.generateSeatbeltProfile()
        } catch {
            let errDesc = error.localizedDescription
            let duration = ContinuousClock.now - startTime
            return HookProcessOutput(
                exitCode: -1,
                stdout: "",
                stderr: errDesc,
                stdoutDataSize: 0,
                stderrDataSize: errDesc.utf8.count,
                isStdoutTruncated: false,
                isStderrTruncated: false,
                durationMilliseconds: Double(duration.components.attoseconds) / 1_000_000_000_000_000.0,
                isTimeout: false,
                isCancelled: false
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: containmentPolicy.sandboxExecutablePath)
        process.arguments = ["-p", seatbeltProfile, "/bin/zsh", "-lc", command]

        let cwdURL = workspaceURL ?? FileManager.default.homeDirectoryForCurrentUser
        process.currentDirectoryURL = cwdURL

        var env = ProcessInfo.processInfo.environment
        env["LIMARE_PLUGIN_ROOT"] = packageRootURL.path
        env["CODEX_PLUGIN_ROOT"] = packageRootURL.path
        env["CLAUDE_PLUGIN_ROOT"] = packageRootURL.path
        env["LIMARE_SESSION_ID"] = sessionID
        if let ws = workspaceURL {
            env["LIMARE_WORKSPACE"] = ws.path
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = HookProcessState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak state] handle in
            state?.appendStdout(handle.availableData, maxBytes: Self.maxStdoutBytes)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak state] handle in
            state?.appendStderr(handle.availableData, maxBytes: Self.maxStderrBytes)
        }

        process.terminationHandler = { [weak state] p in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            state?.markEnded(
                status: p.terminationStatus,
                remainingOut: remainingOut,
                remainingErr: remainingErr,
                maxOut: Self.maxStdoutBytes,
                maxErr: Self.maxStderrBytes
            )
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let duration = ContinuousClock.now - startTime
            let errDesc = "Failed to spawn contained hook process: \(error.localizedDescription)"
            return HookProcessOutput(
                exitCode: -1,
                stdout: "",
                stderr: errDesc,
                stdoutDataSize: 0,
                stderrDataSize: errDesc.utf8.count,
                isStdoutTruncated: false,
                isStderrTruncated: false,
                durationMilliseconds: Double(duration.components.attoseconds) / 1_000_000_000_000_000.0,
                isTimeout: false,
                isCancelled: false
            )
        }

        let pid = process.processIdentifier
        let ownsProcessGroup = setpgid(pid, pid) == 0

        // Write stdin asynchronously and close
        Task.detached {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        }

        func killTree(signal: Int32) {
            Darwin.kill(ownsProcessGroup ? -pid : pid, signal)
        }

        let timeoutTask = Task.detached { [weak state] in
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            guard let state, !state.isEnded else { return }
            state.markTimeout()
            killTree(signal: SIGINT)
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !state.isEnded else { return }
            killTree(signal: SIGTERM)
            try? await Task.sleep(nanoseconds: 300_000_000)
            killTree(signal: SIGKILL)
        }

        let finalExitCode: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                state.lock.lock()
                if state.processEnded {
                    let code = state.exitCode
                    state.lock.unlock()
                    cont.resume(returning: code)
                } else {
                    state.continuation = cont
                    state.lock.unlock()
                }
            }
        } onCancel: {
            state.markCancelled()
            killTree(signal: SIGINT)
            Task.detached {
                try? await Task.sleep(nanoseconds: 100_000_000)
                killTree(signal: SIGKILL)
            }
        }

        timeoutTask.cancel()

        let duration = ContinuousClock.now - startTime
        let durationMs = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0

        let (outCopy, errCopy, isOutTrunc, isErrTrunc) = state.snapshot()

        let stdoutStr = String(decoding: outCopy, as: UTF8.self)
        let stderrStr = String(decoding: errCopy, as: UTF8.self)

        return HookProcessOutput(
            exitCode: finalExitCode,
            stdout: stdoutStr,
            stderr: stderrStr,
            stdoutDataSize: outCopy.count,
            stderrDataSize: errCopy.count,
            isStdoutTruncated: isOutTrunc,
            isStderrTruncated: isErrTrunc,
            durationMilliseconds: durationMs,
            isTimeout: state.isTimedOut(),
            isCancelled: state.isCancelled()
        )
    }

    static func parseExecutionResult(
        eventName: String,
        output: HookProcessOutput,
        handler: HookHandlerConfig,
        source: HookSource
    ) -> HookExecutionSummary {
        var additionalContext: String?
        var permissionDecision: String?
        var permissionDecisionReason: String?
        var continueTurn: Bool?
        var stopReason: String?
        var errorString: String?

        if output.isCancelled {
            errorString = "Hook execution cancelled"
        } else if output.isTimeout {
            errorString = "Hook execution timed out after \(handler.effectiveTimeout)s"
        } else if output.exitCode == -1 && !output.stderr.isEmpty {
            errorString = output.stderr
        } else if output.exitCode == 2 {
            // Codex convention: exit 2 -> deny PreToolUse / block UserPromptSubmit
            permissionDecision = "deny"
            permissionDecisionReason = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if permissionDecisionReason?.isEmpty == true {
                permissionDecisionReason = "Denied by hook (exit code 2)"
            }
            continueTurn = false
            stopReason = permissionDecisionReason
        } else if output.exitCode != 0 {
            errorString = "Hook process exited with code \(output.exitCode)"
        }

        // Parse stdout only if not cancelled, not timed out, and process spawned successfully
        if !output.isCancelled && !output.isTimeout && output.exitCode != -1 {
            let trimmedStdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedStdout.isEmpty {
                if let data = trimmedStdout.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check hookSpecificOutput
                    if let specific = json["hookSpecificOutput"] as? [String: Any] {
                        if let ctx = specific["additionalContext"] as? String {
                            additionalContext = ctx
                        }
                        if let decision = specific["permissionDecision"] as? String {
                            permissionDecision = decision
                        }
                        if let reason = specific["permissionDecisionReason"] as? String {
                            permissionDecisionReason = reason
                        }
                    }
                    // Check top-level keys
                    if let permDec = json["permissionDecision"] as? String {
                        permissionDecision = permDec
                    }
                    if let permReason = json["permissionDecisionReason"] as? String {
                        if permissionDecisionReason == nil {
                            permissionDecisionReason = permReason
                        }
                    }
                    if let decision = json["decision"] as? String {
                        if decision.lowercased() == "block" || decision.lowercased() == "deny" {
                            permissionDecision = "deny"
                        } else if decision.lowercased() == "allow" {
                            permissionDecision = "allow"
                        }
                    }
                    if let reason = json["reason"] as? String {
                        if permissionDecisionReason == nil {
                            permissionDecisionReason = reason
                        }
                    }
                    if let cont = json["continue"] as? Bool {
                        continueTurn = cont
                    }
                    if let stopR = json["stopReason"] as? String {
                        stopReason = stopR
                    }
                    if let ctx = json["additionalContext"] as? String, additionalContext == nil {
                        additionalContext = ctx
                    }
                } else {
                    // Plain text stdout compatibility
                    additionalContext = trimmedStdout
                }
            }
        }

        // Apply context limit
        if let rawContext = additionalContext {
            let tokenLimit = handler.additionalContextLimit ?? 2500
            let charLimit = min(tokenLimit * 4, maxAdditionalContextChars)
            if rawContext.count > charLimit {
                let truncated = String(rawContext.prefix(charLimit))
                additionalContext = truncated + "\n[Hook context truncated]"
            }
        }

        return HookExecutionSummary(
            sourceID: source.id,
            sourceName: source.name,
            eventName: eventName,
            handlerID: handler.id,
            command: handler.command ?? "",
            exitCode: output.exitCode,
            durationMilliseconds: output.durationMilliseconds,
            stdoutSize: output.stdoutDataSize,
            stderrSize: output.stderrDataSize,
            additionalContext: additionalContext,
            permissionDecision: permissionDecision,
            permissionDecisionReason: permissionDecisionReason,
            continueTurn: continueTurn,
            stopReason: stopReason,
            isTimeout: output.isTimeout,
            isCancelled: output.isCancelled,
            error: errorString,
            definitionHash: source.definitionHash
        )
    }
}
