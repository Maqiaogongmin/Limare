import Darwin
import Foundation
import Observation

/// Runs the bundled cloudflared for as long as Remote Access serves: the outbound connection
/// that makes the loopback server reachable through Cloudflare. cloudflared reconnects to the
/// edge by itself; this only restarts the process if it exits, and stops it with the app.
///
/// macOS has no parent-death signal, so a cloudflared left behind by a crash keeps its tunnel
/// open (it reaches nothing: the server died with the app). Its pid file lets the next launch
/// stop it, but only if that pid is still this bundle's cloudflared.
@MainActor
@Observable
final class CloudflareTunnelSupervisor {
    enum Status: Equatable {
        case stopped
        case starting
        /// The process runs; it has not reported an edge connection yet.
        case running
        /// cloudflared reported a registered tunnel connection.
        case connected
        case restarting(inSeconds: Int)
        case failed(String)
    }

    static let quickExitLimit = 5
    static let quickExitWindow: TimeInterval = 60
    static let maxLogBytes = 5 * 1_024 * 1_024

    private(set) var status: Status = .stopped
    /// cloudflared's most recent error line (token masked), shown while it has not connected.
    private(set) var lastError: String?

    @ObservationIgnored private let executableURL: URL
    @ObservationIgnored private let pidFileURL: URL
    @ObservationIgnored private let logFileURL: URL
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored private let restartDelay: (Int) -> Duration
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var exitTimes: [Date] = []
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastErrorLine: String?

    init(
        executableURL: URL,
        stateDirectory: URL,
        logDirectory: URL,
        logs: DebugLogStore,
        restartDelay: @escaping (Int) -> Duration = { attempt in .seconds(min(60, 1 << min(attempt - 1, 6))) }
    ) {
        self.executableURL = executableURL
        self.pidFileURL = stateDirectory.appendingPathComponent("cloudflared.pid")
        self.logFileURL = logDirectory.appendingPathComponent("cloudflared.log")
        self.logs = logs
        self.restartDelay = restartDelay
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The cloudflared inside this app bundle.
    static var bundledExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cloudflared")
    }

    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    func start(token: String) async {
        guard process == nil, restartTask == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            status = .failed("cloudflared is missing from this build.")
            return
        }
        self.token = token
        isStopping = false
        exitTimes = []
        lastErrorLine = nil
        lastError = nil
        await stopLeftoverProcess()
        launch()
    }

    func stop() async {
        isStopping = true
        restartTask?.cancel()
        restartTask = nil
        token = nil
        if let process {
            self.process = nil
            await Self.terminate(process)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
        status = .stopped
    }

    // MARK: - Process

    private func launch() {
        guard let token, !isStopping else { return }
        status = .starting
        let process = Process()
        process.executableURL = executableURL
        // HTTP/2 over TCP, not QUIC: networks that block outbound UDP 7844 are common, and there
        // cloudflared keeps dialing QUIC even after its own pre-check picks http2. TCP works
        // wherever HTTPS does, and this low-volume control channel gains nothing from QUIC.
        process.arguments = ["tunnel", "--no-autoupdate", "--loglevel", "info", "--protocol", "http2",
                             "--pidfile", pidFileURL.path, "--grace-period", "2s", "run"]
        // The token travels in the environment, not argv (which `ps` and Activity Monitor show).
        // Nothing else of Limare's environment is passed on.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "TUNNEL_TOKEN": token,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let logHandle = Self.openLog(at: logFileURL)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                try? logHandle?.close()
                return
            }
            logHandle?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.consume(text, from: process) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in self?.processExited(finished, code: code) }
        }
        do {
            try process.run()
            self.process = process
            status = .running
            logs.info("Remote", "cloudflared started (pid \(process.processIdentifier)).")
        } catch {
            status = .failed("cloudflared could not start: \(error.localizedDescription)")
            logs.error("Remote", "cloudflared could not start: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String, from source: Process) {
        guard source === process else { return }
        let secrets = token.map { [$0] } ?? []
        for line in text.split(separator: "\n") {
            if line.contains("Registered tunnel connection") {
                status = .connected
                lastError = nil
            } else if line.contains(" ERR ") || line.contains(" FTL ") {
                let clean = SecretMasker.redact(String(line), secrets: secrets)
                lastErrorLine = clean
                lastError = Self.message(of: clean)
                logs.error("Remote", "cloudflared: \(clean)", masking: secrets)
            }
        }
    }

    private func processExited(_ finished: Process, code: Int32) {
        guard finished === process else { return }
        process = nil
        guard !isStopping else { return }
        let now = Date()
        exitTimes = exitTimes.filter { now.timeIntervalSince($0) < Self.quickExitWindow } + [now]
        if exitTimes.count >= Self.quickExitLimit {
            let reason = lastErrorLine ?? "cloudflared exited with status \(code)."
            status = .failed(reason)
            logs.error("Remote", "cloudflared keeps exiting; not restarting until Remote Access is restarted. Last: \(reason)")
            return
        }
        let delay = restartDelay(exitTimes.count)
        status = .restarting(inSeconds: Int(delay.components.seconds))
        logs.info("Remote", "cloudflared exited with status \(code); restarting.")
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.launch()
        }
    }

    /// Stops a cloudflared left running by a previous Limare that did not quit normally, if the
    /// pid file still names one and that pid is still this bundle's cloudflared.
    private func stopLeftoverProcess() async {
        defer { try? FileManager.default.removeItem(at: pidFileURL) }
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0,
              Self.executablePath(of: pid) == executableURL.resolvingSymlinksInPath().path else { return }
        logs.info("Remote", "Stopping cloudflared left over from a previous run (pid \(pid)).")
        kill(pid, SIGTERM)
        for _ in 0..<30 where kill(pid, 0) == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// A cloudflared log line without its timestamp and level.
    static func message(of line: String) -> String {
        for marker in [" ERR ", " FTL "] {
            if let range = line.range(of: marker) { return String(line[range.upperBound...]) }
        }
        return line
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    /// SIGTERM, then SIGKILL; returns once the process is gone.
    private static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The cloudflared log, started afresh once it passes 5 MB.
    private static func openLog(at url: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxLogBytes || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}
