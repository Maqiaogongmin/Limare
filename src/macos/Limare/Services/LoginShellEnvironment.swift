import Foundation
import Darwin

/// The PATH of the user's own login shell.
///
/// An app opened from the Dock or Finder inherits launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`,
/// so Homebrew, nvm, pnpm and whatever else the user's dotfiles add are missing from the commands
/// it runs: the model then concludes that installed tools are absent. Like VS Code and Zed, Limare
/// asks the user's shell once, as a login interactive shell, and runs commands with its PATH.
enum LoginShellEnvironment {
    private static let resolution = Task.detached(priority: .utility) { resolvePATH() }

    /// Starts asking the shell at launch, so the first command does not wait for it.
    static func prefetch() {
        _ = resolution
    }

    /// The login shell's PATH, or nil when the shell could not be asked.
    static func path() async -> String? {
        await resolution.value
    }

    /// Runs `shell -l -i -c` and reads PATH between two markers: an interactive shell may print
    /// anything else (terminal integration escapes, greetings) around it.
    static func resolvePATH(shell: String = userShell(), timeout: TimeInterval = 10) -> String? {
        let marker = "__LIMARE_PATH_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' \(marker); /usr/bin/printenv PATH; printf '%s' \(marker)"]
        var environment = ProcessInfo.processInfo.environment
        // Lets a user's rc file skip slow or interactive setup, as VSCODE_RESOLVING_ENVIRONMENT does.
        environment["LIMARE_RESOLVING_ENVIRONMENT"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let output = LockedData()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())

        let text = String(decoding: output.value, as: UTF8.self)
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.contains("/") ? path : nil
    }

    /// The login shell from the user's account record, as Terminal uses it.
    static func userShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        return "/bin/zsh"
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        var value: Data { lock.withLock { data } }
    }
}
