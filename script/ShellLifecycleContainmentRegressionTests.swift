import Foundation
import Darwin

@main
struct ShellLifecycleContainmentRegressionTests {
    static var passed = 0
    static var failed = 0

    static func check(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
            print("PASS: \(label)")
        } else {
            failed += 1
            print("FAIL: \(label)")
        }
        fflush(stdout)
    }

    @MainActor
    static func main() async throws {
        let args = ProcessInfo.processInfo.arguments
        if args.count >= 3 && args[1] == "--subprocess" {
            let caseName = args[2]
            try await runSubprocessCase(caseName)
            return
        }

        print("=== Shell Lifecycle Containment Regression Tests ===")
        let executablePath = args[0]

        // S01: valid cwd -> command completes normally
        print("\n--- S01: Valid cwd completes normally ---")
        let s01Result = try runChildHarness(executablePath: executablePath, caseName: "S01")
        check(s01Result.exitCode == 0, "S01: child harness exited with code 0")
        check(s01Result.output.contains("SUBPROCESS_OK_S01"), "S01: valid command completed normally")

        // S02: missing cwd -> receives ShellRunnerError.invalidWorkingDirectory -> harness process remains alive
        print("\n--- S02: Missing cwd receives error and remains alive ---")
        let s02Result = try runChildHarness(executablePath: executablePath, caseName: "S02")
        check(s02Result.exitCode == 0, "S02: child harness survived missing cwd (did not exit from SIGINT/SIGTERM/SIGKILL)")
        check(s02Result.output.contains("SUBPROCESS_OK_S02"), "S02: received ShellRunnerError.invalidWorkingDirectory")

        // S03: missing cwd + stream teardown/cancellation -> harness process remains alive
        print("\n--- S03: Missing cwd with stream cancellation remains alive ---")
        let s03Result = try runChildHarness(executablePath: executablePath, caseName: "S03")
        check(s03Result.exitCode == 0, "S03: child harness survived stream teardown/cancellation")
        check(s03Result.output.contains("SUBPROCESS_OK_S03"), "S03: stream teardown after missing cwd completed safely")

        // S04: cancellation before successful process launch -> must never signal pid <= 0
        print("\n--- S04: Pre-spawn cancellation never signals host or pid <= 0 ---")
        let s04Result = try runChildHarness(executablePath: executablePath, caseName: "S04")
        check(s04Result.exitCode == 0, "S04: child harness survived pre-spawn cancellation")
        check(s04Result.output.contains("SUBPROCESS_OK_S04"), "S04: pre-spawn cancel handled safely without signalling")

        // S05: normal running process cancellation -> child shell terminates correctly -> harness remains alive
        print("\n--- S05: Normal running process cancellation terminates child and keeps harness alive ---")
        let s05Result = try runChildHarness(executablePath: executablePath, caseName: "S05")
        check(s05Result.exitCode == 0, "S05: child harness survived normal running cancellation")
        check(s05Result.output.contains("SUBPROCESS_OK_S05"), "S05: running process cancelled and child terminated")

        // Direct in-process checks
        print("\n--- Direct in-process lifecycle checks ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("shell_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Test timeout works
        do {
            let req = ShellExecutionRequest(command: "sleep 5", cwd: tempDir, timeoutSeconds: 0.1)
            var finalResult: ShellExecutionResult?
            for try await event in ShellRunner().stream(req) {
                if case .finished(let res) = event {
                    finalResult = res
                }
            }
            check(finalResult?.timedOut == true, "Timeout still works and marks result timedOut")
        }

        // A descendant that leaves the shell's process group (as a helper launched through
        // Foundation's Process does) survives the group kill and keeps the output pipes open.
        // The result must not wait for it, after a timeout or after a normal exit.
        do {
            let escape = #"if (fork() == 0) { setpgrp(0, 0); open(F, ">", "escaped-$$.pid"); print F $$; close F; sleep 30; exit } "#
            let timedOut = await runBounded(
                ShellExecutionRequest(command: "perl -e '\(escape)sleep 30'", cwd: tempDir, timeoutSeconds: 0.5),
                deadline: 8
            )
            check(timedOut.result?.timedOut == true, "Timeout returns although an escaped descendant holds the pipes")
            let exited = await runBounded(
                ShellExecutionRequest(command: "perl -e '\(escape)print \"parent_done\\n\"'", cwd: tempDir, timeoutSeconds: 30),
                deadline: 8
            )
            check(
                exited.result?.exitCode == 0 && exited.result?.timedOut == false && exited.stdout.contains("parent_done"),
                "Normal exit returns its output although an escaped descendant holds the pipes"
            )
            let pidFiles = (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path))?.filter { $0.hasPrefix("escaped-") } ?? []
            for file in pidFiles {
                if let text = try? String(contentsOf: tempDir.appendingPathComponent(file), encoding: .utf8),
                   let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    Darwin.kill(pid, SIGKILL)
                }
            }
        }

        // Test successful shell works
        do {
            let req = ShellExecutionRequest(command: "printf 'containment_ok\n'", cwd: tempDir, timeoutSeconds: 5)
            var stdout = ""
            var exitCode: Int32?
            for try await event in ShellRunner().stream(req) {
                switch event {
                case .output(let stream, _, _, let text):
                    if stream == .stdout { stdout += text }
                case .finished(let res):
                    exitCode = res.exitCode
                }
            }
            check(exitCode == 0 && stdout.contains("containment_ok"), "Successful shell command works normally")
        }

        // Test ToolExecutor converts invalid cwd into failed ToolExecutionOutcome
        do {
            let logs = DebugLogStore(storageRootURL: tempDir)
            let unavailableDir = tempDir.appendingPathComponent("unavailable_workspace_dir_\(UUID().uuidString)")
            let wsStore = WorkspaceStore(storageRootURL: tempDir, logs: logs)
            wsStore.restoreWorkspaceConfiguration(WorkspaceConfiguration.from(url: unavailableDir))
            let permStore = PermissionStore(logs: logs, initialMode: .fullAccess)

            let toolExecutor = ToolExecutor(workspace: wsStore, permissions: permStore, logs: logs)
            let call = ProviderToolCall(
                id: "call_shell_unavailable_test",
                function: .init(name: "shell_execute", arguments: "{\"command\": \"pwd\"}")
            )

            var reportedState: ToolExecutionState?
            let outcome = await toolExecutor.execute(call) { update in
                reportedState = update.state
            }

            check(outcome.isError, "ToolExecutor: outcome.isError is true for unavailable workspace")
            check(outcome.content.contains("Shell working directory does not exist: \(unavailableDir.path)"),
                  "ToolExecutor: outcome content contains exact 'Shell working directory does not exist' failure contract")
            check(reportedState == .failed, "ToolExecutor: reported state transitioned to failed")
        }

        print("\n=== Final Summary: \(passed) passed, \(failed) failed ===")
        if failed > 0 {
            exit(1)
        }
    }

    /// Streams a request, giving up after `deadline` seconds so a hang fails the check
    /// instead of the suite.
    private static func runBounded(
        _ request: ShellExecutionRequest,
        deadline: TimeInterval
    ) async -> (result: ShellExecutionResult?, stdout: String) {
        await withTaskGroup(of: (result: ShellExecutionResult?, stdout: String)?.self) { group in
            group.addTask {
                var stdout = ""
                var result: ShellExecutionResult?
                do {
                    for try await event in ShellRunner().stream(request) {
                        switch event {
                        case .output(let stream, _, _, let text):
                            if stream == .stdout { stdout += text }
                        case .finished(let finished):
                            result = finished
                        }
                    }
                } catch {}
                return (result, stdout)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? (nil, "")
        }
    }

    private static func runChildHarness(executablePath: String, caseName: String) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--subprocess", caseName]
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus != 0 {
            print("Child harness failed [status=\(process.terminationStatus)]: \(output)")
        }
        return (process.terminationStatus, output)
    }

    private static func runSubprocessCase(_ caseName: String) async throws {
        // Put subprocess in its own process group to isolate any unintended signal
        setpgid(0, 0)

        switch caseName {
        case "S01":
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("s01_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let req = ShellExecutionRequest(command: "echo s01_success", cwd: tempDir, timeoutSeconds: 5)
            var captured = ""
            var code: Int32 = -1
            for try await event in ShellRunner().stream(req) {
                switch event {
                case .output(_, _, _, let text):
                    captured += text
                case .finished(let res):
                    code = res.exitCode ?? -1
                }
            }
            guard code == 0, captured.contains("s01_success") else {
                print("S01 failed: exitCode=\(code), output=\(captured)")
                exit(1)
            }
            print("SUBPROCESS_OK_S01")
            exit(0)

        case "S02":
            let missingDir = URL(fileURLWithPath: "/tmp/nonexistent_cwd_s02_\(UUID().uuidString)")
            let req = ShellExecutionRequest(command: "pwd", cwd: missingDir, timeoutSeconds: 5)
            var caughtExpected = false
            do {
                for try await _ in ShellRunner().stream(req) {}
            } catch let error as ShellRunnerError {
                if case .invalidWorkingDirectory = error {
                    caughtExpected = true
                }
            } catch {
                print("Caught unexpected error: \(error)")
            }

            guard caughtExpected else {
                print("S02 failed: did not catch invalidWorkingDirectory")
                exit(1)
            }
            // Sleep 1.2s to verify harness process remains alive after any delayed escalation
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("SUBPROCESS_OK_S02")
            exit(0)

        case "S03":
            let missingDir = URL(fileURLWithPath: "/tmp/nonexistent_cwd_s03_\(UUID().uuidString)")
            let req = ShellExecutionRequest(command: "pwd", cwd: missingDir, timeoutSeconds: 5)
            let task = Task {
                for try await _ in ShellRunner().stream(req) {}
            }
            task.cancel()
            _ = try? await task.value
            // Sleep 1.2s to exceed delayed escalation timers
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("SUBPROCESS_OK_S03")
            exit(0)

        case "S04":
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("s04_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Empty command pre-spawn failure
            let emptyReq = ShellExecutionRequest(command: "   ", cwd: tempDir, timeoutSeconds: 5)
            var caughtEmpty = false
            do {
                for try await _ in ShellRunner().stream(emptyReq) {}
            } catch let error as ShellRunnerError {
                if case .emptyCommand = error {
                    caughtEmpty = true
                }
            } catch {}

            guard caughtEmpty else {
                print("S04 failed: did not catch emptyCommand")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            print("SUBPROCESS_OK_S04")
            exit(0)

        case "S05":
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("s05_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let pidFile = tempDir.appendingPathComponent("child.pid")
            // Launch child shell that records its own PID and runs sleep
            let command = "echo $$ > '\(pidFile.path)' && exec sleep 30"
            let req = ShellExecutionRequest(command: command, cwd: tempDir, timeoutSeconds: 30)

            let task = Task {
                do {
                    for try await _ in ShellRunner().stream(req) {}
                } catch {}
            }

            // Wait until child writes its PID
            var childPID: pid_t = 0
            for _ in 0..<50 {
                if let content = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                   let pid = Int32(content), pid > 0 {
                    childPID = pid
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            guard childPID > 0 else {
                print("S05 failed: child PID file was not written")
                exit(1)
            }

            // Verify child process is alive
            guard kill(childPID, 0) == 0 else {
                print("S05 failed: child process was not running before cancellation")
                exit(1)
            }

            // Cancel the stream
            task.cancel()
            _ = await task.result

            // Wait for child process to terminate
            var childTerminated = false
            for _ in 0..<30 {
                if kill(childPID, 0) != 0 {
                    childTerminated = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            guard childTerminated else {
                print("S05 failed: child process \(childPID) did not terminate upon cancellation")
                exit(1)
            }

            print("SUBPROCESS_OK_S05")
            exit(0)

        default:
            print("Unknown subprocess case: \(caseName)")
            exit(1)
        }
    }
}
