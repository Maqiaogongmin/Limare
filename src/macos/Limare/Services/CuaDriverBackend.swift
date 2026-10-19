import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Production execution driver backend for Computer Use v0.2.
///
/// Implements Option C2 (Direct MCP Child / Stdio) communicating directly with
/// `cua-driver mcp --direct` via anonymous stdio JSON-RPC pipes.
/// Operates in pure direct mode without filesystem sockets, shell wrappers,
/// or advisory host bundle IDs.
public actor CuaDriverBackend: ComputerUseDriver {
    /// Required foundational tools that must be registered on `tools/list`
    /// for the backend to be declared `.ready`.
    public static let requiredFoundationalTools: Set<String> = [
        "start_session", "get_session", "end_session",
        "check_permissions",
        "list_apps",
        "list_windows",
        "launch_app",
        "get_window_state",
        "click"
    ]

    private var runCreatedAt: [UUID: Date] = [:]
    private var runConversations: [UUID: UUID] = [:]
    private var runSessions: [UUID: ComputerUseDriverRunSession] = [:]
    private var endedRunIDs: Set<UUID> = []
    private var snapshotOwners: [String: (UUID, Int)] = [:]
    private var implicitLeaseCreated = false
    private var sessionDiagnostics: [UUID: [String]] = [:]

    /// Strongly-typed lifecycle state
    private(set) public var state: ComputerUseDriverReadiness = .stopped

    /// Custom injected executable URL (used for deterministic testing and development smoke)
    public let customExecutableURL: URL?

    /// Monotonically increasing generation number
    private var generationCounter: Int = 0

    /// Maximum protocol frame size in bytes (configurable for testing)
    public let maxFrameSizeBytes: Int

    /// Active transport instance for current generation
    private var transport: CuaDriverMCPTransport?

    /// Active start task to enforce S1-I06 (concurrent start requests spawn at most one child)
    private var startingTask: Task<Void, Error>?

    /// Active shutdown task to enforce F4 serialization across async suspension points
    private var activeShutdownTask: Task<Void, Never>?

    /// Test seam allowing simulated process liveness behavior for shutdown timeout tests
    public var processLivenessChecker: (@Sendable (Process) -> Bool)?

    /// Spawn observer test seam allowing callers to observe real spawned PID
    public var onProcessSpawned: (@Sendable (Int32) -> Void)?

    /// Tool names discovered during the latest successful handshake
    private(set) public var discoveredToolNames: Set<String> = []

    /// Running child process PID (if alive and ready)
    public var runningPID: Int32? {
        get async {
            await transport?.runningPID
        }
    }

    /// Current generation number
    public var currentGeneration: Int {
        generationCounter
    }

    /// Bounded stderr tail from active transport
    public var recentStderrTail: String {
        get async {
            await transport?.recentStderrTail ?? ""
        }
    }

    public init(
        executableURL: URL? = nil,
        maxFrameSizeBytes: Int = 1_048_576,
        processLivenessChecker: (@Sendable (Process) -> Bool)? = nil
    ) {
        self.customExecutableURL = executableURL
        self.maxFrameSizeBytes = maxFrameSizeBytes
        self.processLivenessChecker = processLivenessChecker
    }

    public func setProcessLivenessChecker(_ checker: (@Sendable (Process) -> Bool)?) async {
        self.processLivenessChecker = checker
        await self.transport?.setProcessLivenessChecker(checker)
    }

    public func setOnProcessSpawned(_ handler: (@Sendable (Int32) -> Void)?) async {
        self.onProcessSpawned = handler
    }

    public func readiness() async -> ComputerUseDriverReadiness {
        return state
    }

    /// Starts the backend process and performs the MCP handshake.
    /// Idempotent if already in `.ready` state. Serializes concurrent callers.
    public func start() async throws {
        // F4: If a shutdown is in progress, await its completion before starting fresh
        if let inFlightShutdown = activeShutdownTask {
            await inFlightShutdown.value
        }

        // S1-I05: If already ready, start() is idempotent
        if case .ready = state {
            return
        }

        // S1-I06: If another caller is already starting, join its in-flight task
        if let existing = startingTask {
            return try await withTaskCancellationHandler {
                try await existing.value
            } onCancel: {
                existing.cancel()
            }
        }

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startingTask = task
        defer { startingTask = nil }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performStart() async throws {
        // S1-I02: Transition stopped/failed -> starting
        state = .starting

        // If there's an existing residual transport (e.g. from previous failed shutdown), ensure it's stopped
        if let residual = self.transport {
            let res = await residual.stop(timeoutSeconds: 1.0)
            if case .timeoutStillRunning = res {
                let err = ComputerUseDriverError.spawnFailed(reason: "Previous driver process could not be terminated")
                self.state = .failed(err)
                throw err
            }
            self.transport = nil
        }

        // F3: Monotonically advance and reserve generation counter BEFORE transport incarnation becomes observable
        runCreatedAt.removeAll()
        runConversations.removeAll()
        runSessions.removeAll()
        snapshotOwners.removeAll()
        implicitLeaseCreated = false
        generationCounter += 1
        let thisGeneration = generationCounter
        var newTransport: CuaDriverMCPTransport?

        do {
            try Task.checkCancellation()

            let executableURL = try resolveExecutableURL()
            let environment = Self.makeTrustedEnvironment()

            let transportInstance = CuaDriverMCPTransport(
                generation: thisGeneration,
                maxFrameSizeBytes: self.maxFrameSizeBytes,
                processLivenessChecker: self.processLivenessChecker,
                onProcessSpawned: self.onProcessSpawned,
                onUnexpectedTermination: { [weak self] exitCode, stderrTail in
                    Task { [weak self] in
                        await self?.handleUnexpectedChildDeath(generation: thisGeneration, exitCode: exitCode, stderrTail: stderrTail)
                    }
                },
                onChannelFailure: { [weak self] error, termResult in
                    Task { [weak self] in
                        await self?.handleChannelFailure(generation: thisGeneration, error: error, terminationResult: termResult)
                    }
                }
            )
            newTransport = transportInstance
            self.transport = transportInstance

            try Task.checkCancellation()

            // 1. Direct process launch (NO shell wrapper)
            try await transportInstance.start(
                executableURL: executableURL,
                arguments: ["mcp", "--direct"],
                environment: environment
            )

            try Task.checkCancellation()

            // 2. MCP initialize handshake
            let initParams: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "Limare",
                    "version": "0.2.0"
                ]
            ]
            let initResponse = try await transportInstance.sendRPC(method: "initialize", params: initParams, timeoutSeconds: 10)
            guard initResponse["error"] == nil,
                  let _ = initResponse["result"] as? [String: Any] else {
                throw ComputerUseDriverError.handshakeFailed(reason: "Invalid initialize response: \(initResponse.value)")
            }

            try Task.checkCancellation()

            // 3. notifications/initialized
            try await transportInstance.sendNotification(method: "notifications/initialized")

            try Task.checkCancellation()

            // 4. tools/list capability validation
            let toolsResponse = try await transportInstance.sendRPC(method: "tools/list", params: [:], timeoutSeconds: 10)
            guard let toolsResult = toolsResponse["result"] as? [String: Any],
                  let toolsList = toolsResult["tools"] as? [[String: Any]] else {
                throw ComputerUseDriverError.protocolMalformed(detail: "tools/list response missing 'tools' array")
            }

            // 5. Verify presence of all required foundational tools
            let discovered = Set(toolsList.compactMap { $0["name"] as? String })
            let missing = Self.requiredFoundationalTools.subtracting(discovered)
            guard missing.isEmpty else {
                throw ComputerUseDriverError.requiredToolMissing(missingTools: Array(missing).sorted())
            }

            try Task.checkCancellation()

            // 6. Transition to .ready
            self.discoveredToolNames = discovered
            self.state = .ready(generation: thisGeneration)

        } catch is CancellationError {
            if let t = newTransport {
                let termRes = await t.stop(timeoutSeconds: 0.5)
                if case .timeoutStillRunning = termRes {
                    self.transport = t
                    self.state = .failed(.shutdownTimeout)
                    throw ComputerUseDriverError.shutdownTimeout
                }
            }
            self.transport = nil
            self.state = .failed(.cancelled)
            throw ComputerUseDriverError.cancelled
        } catch let driverErr as ComputerUseDriverError {
            if let t = newTransport {
                let termRes = await t.stop(timeoutSeconds: 0.5)
                if case .timeoutStillRunning = termRes {
                    self.transport = t
                    self.state = .failed(.shutdownTimeout)
                    throw ComputerUseDriverError.shutdownTimeout
                }
            }
            self.transport = nil
            self.state = .failed(driverErr)
            throw driverErr
        } catch {
            let driverErr = ComputerUseDriverError.spawnFailed(reason: error.localizedDescription)
            if let t = newTransport {
                let termRes = await t.stop(timeoutSeconds: 0.5)
                if case .timeoutStillRunning = termRes {
                    self.transport = t
                    self.state = .failed(.shutdownTimeout)
                    throw ComputerUseDriverError.shutdownTimeout
                }
            }
            self.transport = nil
            self.state = .failed(driverErr)
            throw driverErr
        }
    }

    /// Gracefully shuts down the driver child process and closes all pipes.
    /// F4: Serialized across suspension points; idempotent.
    public func shutdown() async {
        runCreatedAt.removeAll()
        runConversations.removeAll()
        runSessions.removeAll()
        snapshotOwners.removeAll()
        implicitLeaseCreated = false
        if let existingShutdown = activeShutdownTask {
            await existingShutdown.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performShutdown()
        }
        activeShutdownTask = task
        defer { activeShutdownTask = nil }
        await task.value
    }

    private func performShutdown() async {
        // S1-I04: Idempotent if already stopped
        if state == .stopped { return }
        state = .stopping

        if let existing = startingTask {
            existing.cancel()
            _ = try? await existing.value
            startingTask = nil
        }

        if let t = transport {
            let termResult = await t.stop(timeoutSeconds: 2.0)
            switch termResult {
            case .confirmedTerminated:
                self.transport = nil
                self.state = .stopped
            case .timeoutStillRunning:
                // F5: Truthful failure when process did not terminate within timeout
                self.state = .failed(.shutdownTimeout)
                // Retain transport so runningPID / process handle is preserved
            }
        } else {
            self.state = .stopped
        }
    }

    func handleUnexpectedChildDeath(generation: Int, exitCode: Int32, stderrTail: String?) {
        guard generation == generationCounter else { return }
        guard case .ready = state else { return }
        self.state = .failed(.unexpectedExit(statusCode: exitCode, stderrTail: stderrTail))
        self.transport = nil
    }

    func handleChannelFailure(generation: Int, error: ComputerUseDriverError, terminationResult: DriverTerminationResult) {
        guard generation == generationCounter else { return }
        switch terminationResult {
        case .confirmedTerminated:
            self.state = .failed(error)
            self.transport = nil
        case .timeoutStillRunning:
            // CU2-S1-I18: Retain transport ownership so PID is not lost!
            self.state = .failed(.shutdownTimeout)
        }
    }

    /// Resolves the driver executable following strict application ownership priority:
    /// 1. Bundled helper: `Limare.app/Contents/Helpers/cua-driver`
    /// 2. Explicitly injected URL (for deterministic tests and development smoke)
    /// Fails closed if not found. Never searches PATH or Homebrew.
    public func resolveExecutableURL() throws -> URL {
        if let custom = customExecutableURL {
            guard FileManager.default.fileExists(atPath: custom.path) else {
                throw ComputerUseDriverError.driverExecutableMissing(path: custom.path)
            }
            guard FileManager.default.isExecutableFile(atPath: custom.path) else {
                throw ComputerUseDriverError.driverNotExecutable(path: custom.path)
            }
            return custom
        }

        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cua-driver")
        if FileManager.default.fileExists(atPath: bundled.path) {
            guard FileManager.default.isExecutableFile(atPath: bundled.path) else {
                throw ComputerUseDriverError.driverNotExecutable(path: bundled.path)
            }
            return bundled
        }

        if let aux = Bundle.main.url(forAuxiliaryExecutable: "cua-driver"),
           FileManager.default.fileExists(atPath: aux.path) {
            guard FileManager.default.isExecutableFile(atPath: aux.path) else {
                throw ComputerUseDriverError.driverNotExecutable(path: aux.path)
            }
            return aux
        }

        throw ComputerUseDriverError.driverExecutableMissing(path: bundled.path)
    }

    /// Constructs a trusted, deterministic environment for the driver child process.
    /// Strips ALL variables starting with `CUA_DRIVER_` to enforce pure direct runtime.
    public static func makeTrustedEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [:]
        let allowedKeys: Set<String> = [
            "HOME", "USER", "LOGNAME", "PATH", "LANG", "TMPDIR", "SHELL"
        ]
        for (key, val) in inherited {
            if allowedKeys.contains(key) || key.hasPrefix("LC_") {
                env[key] = val
            }
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }

        // Enforce pure direct mode: purge all inherited CUA_DRIVER_* control variables
        for k in Array(env.keys) where k.hasPrefix("CUA_DRIVER_") {
            env.removeValue(forKey: k)
        }
        return env
    }

    // MARK: - Stage 2: Mechanical Driver Tool Invocations

    /// Executes an MCP tool call on the driver child process.
    public func prepareRunSession(runID: UUID) async throws -> ComputerUseDriverRunSession {
        guard !endedRunIDs.contains(runID) else { throw ComputerUseDriverError.cancelled }
        guard case .ready(let expectedTransportGeneration) = state else { throw ComputerUseDriverError.connectionClosed(detail: "Transport not ready") }
        if let conversationID = ComputerUseDriverExecutionContext.current?.conversationID {
            runConversations[runID] = conversationID
        }
        if runCreatedAt[runID] == nil { runCreatedAt[runID] = Date() }
        let old = runSessions[runID]
        let label = "limare-" + runID.uuidString.lowercased()
        let response = try await rawTool(name: "start_session", arguments: ["session": label])
        guard let sc = response["structuredContent"] as? [String: Any],
              sc["active"] as? Bool == true, sc["session"] as? String == label,
              let revived = sc["revived"] as? Bool else {
            throw ComputerUseDriverError.protocolMalformed(detail: "Missing structured lifecycle truth")
        }
        if endedRunIDs.contains(runID) {
            // A terminal callback may have raced a start already dispatched to the serialized child.
            _ = try? await rawTool(name: "end_session", arguments: ["session": label])
            throw ComputerUseDriverError.cancelled
        }
        guard case .ready(let transportGen) = state, transportGen == expectedTransportGeneration else { throw ComputerUseDriverError.cancelled }
        let changed = revived || old == nil || old?.transportGeneration != transportGen
        let session = ComputerUseDriverRunSession(runID: runID, publicSessionLabel: label,
            transportGeneration: transportGen, generation: (old?.generation ?? 0) + (changed ? 1 : 0),
            ensure: revived ? .revived : (old == nil ? .created : .active))
        if changed { snapshotOwners = snapshotOwners.filter { $0.value.0 != runID } }
        sessionDiagnostics[runID, default: []].append("named label=\(label) transportGeneration=\(transportGen) sessionGeneration=\(session.generation) ensure=\(session.ensure.rawValue)")
        runSessions[runID] = session
        return session
    }

    public func finishRunSession(runID: UUID) async throws {
        // Tombstone before suspension: a pending ensure/dispatch cannot resurrect this run.
        endedRunIDs.insert(runID)
        runConversations.removeValue(forKey: runID)
        runCreatedAt.removeValue(forKey: runID)
        snapshotOwners = snapshotOwners.filter { $0.value.0 != runID }
        guard let session = runSessions.removeValue(forKey: runID) else { return }
        _ = try await rawTool(name: "end_session", arguments: ["session": session.publicSessionLabel])
    }

    public func finishConversationSessions(conversationID: UUID, createdBefore: Date) async {
        let ids = runConversations.filter { $0.value == conversationID && (runCreatedAt[$0.key] ?? .distantFuture) <= createdBefore }.map(\.key)
        for id in ids {
            do { try await finishRunSession(runID: id) }
            catch { NSLog("CU driver session cleanup failed run=%@: %@", id.uuidString, error.localizedDescription) }
        }
    }

    public func finishAllRunSessions() async {
        let ids = Array(runSessions.keys)
        for id in ids {
            do { try await finishRunSession(runID: id) }
            catch { NSLog("CU driver session cleanup failed run=%@: %@", id.uuidString, error.localizedDescription) }
        }
    }

    public func drainSessionDiagnostics(runID: UUID) async -> [String] {
        sessionDiagnostics.removeValue(forKey: runID) ?? []
    }

    private func ensureImplicitTransportSession() async throws {
        let response = try await rawTool(name: "start_session", arguments: [:])
        guard let sc = response["structuredContent"] as? [String: Any], sc["active"] as? Bool == true,
              sc["revived"] is Bool else {
            throw ComputerUseDriverError.protocolMalformed(detail: "Missing implicit lease lifecycle truth")
        }
        if let context = ComputerUseDriverExecutionContext.current {
            let outcome = sc["revived"] as? Bool == true ? "revived" : (implicitLeaseCreated ? "active" : "created")
            sessionDiagnostics[context.runID, default: []].append("implicit label=transport-implicit transportGeneration=\(generationCounter) ensure=\(outcome)")
        }
        implicitLeaseCreated = true
    }

    public func callTool(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let scopedTools: Set<String> = ["get_window_state", "click", "double_click", "right_click", "type_text", "press_key", "hotkey", "set_value", "scroll", "drag"]
        var args = arguments
        if scopedTools.contains(name) {
            guard let context = ComputerUseDriverExecutionContext.current else {
                throw ComputerUseDriverError.protocolMalformed(detail: "Explicit authoritative run execution context required")
            }
            let session = try await prepareRunSession(runID: context.runID)
            let mutation = name != "get_window_state"
            if mutation && session.ensure != .active {
                throw ComputerUseDriverError.staleElementReference(detail: "staleDriverSession: fresh observation required")
            }
            if mutation, !snapshotOwners.values.contains(where: { $0.0 == context.runID && $0.1 == session.generation }) {
                throw ComputerUseDriverError.staleElementReference(detail: "fresh observation required for this driver run session")
            }
            if let token = args["element_token"] as? String {
                let snapshot = String(token.split(separator: ":").first ?? "")
                guard let owner = snapshotOwners[snapshot], owner.0 == context.runID, owner.1 == session.generation else {
                    throw ComputerUseDriverError.staleElementReference(detail: "Snapshot belongs to another run or session generation")
                }
            }
            guard await context.isAuthoritative(), !endedRunIDs.contains(context.runID) else { throw ComputerUseDriverError.cancelled }
            args["session"] = session.publicSessionLabel
            let result = try await rawTool(name: name, arguments: args)
            guard await context.isAuthoritative(), !endedRunIDs.contains(context.runID) else { throw ComputerUseDriverError.cancelled }
            if name == "get_window_state", let sc = result["structuredContent"] as? [String: Any], let snapshot = sc["snapshot_id"] as? String {
                snapshotOwners = snapshotOwners.filter { $0.value.0 != context.runID }
                snapshotOwners[snapshot] = (context.runID, session.generation)
            }
            return result
        }
        if ["list_apps", "list_windows", "launch_app"].contains(name) {
            try await ensureImplicitTransportSession()
            if let context = ComputerUseDriverExecutionContext.current {
                guard await context.isAuthoritative(), !endedRunIDs.contains(context.runID) else { throw ComputerUseDriverError.cancelled }
            }
        }
        return try await rawTool(name: name, arguments: args)
    }

    private func rawTool(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        guard case .ready = state else {
            throw ComputerUseDriverError.connectionClosed(detail: "Backend is not in .ready state (state: \(state))")
        }
        guard let transport = self.transport else {
            throw ComputerUseDriverError.connectionClosed(detail: "Transport is nil")
        }
        let params: [String: Any] = [
            "name": name,
            "arguments": arguments
        ]
        let response = try await transport.sendRPC(method: "tools/call", params: params, timeoutSeconds: 30)
        let resDict = response["result"] as? [String: Any] ?? response.value
        if let isError = resDict["isError"] as? Bool, isError {
            let structured = resDict["structuredContent"] as? [String: Any] ?? [:]
            let refusal = structured["refusal"] as? [String: Any] ?? [:]
            if refusal["code"] as? String == "session_ended" || structured["code"] as? String == "session_not_started" {
                // Structured lifecycle refusal; never match prose or replay the rejected mutation.
                throw ComputerUseDriverError.staleElementReference(detail: "driverSessionEnded: fresh observation required")
            }
            let content = resDict["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            throw ComputerUseDriverError.driverToolFailed(tool: name, reason: text.isEmpty ? "Unknown driver tool error" : text)
        }
        return resDict
    }

    public private(set) var lastApplicationDiscoveryPayload: MCPResponseBox?

    /// Discovers running desktop applications using driver backend.
    public func listApplications() async throws -> [ApplicationInfo] {
        let resp = try await callTool(name: "list_apps", arguments: [:])
        lastApplicationDiscoveryPayload = MCPResponseBox(resp)
        guard let sc = resp["structuredContent"] as? [String: Any],
              let appsList = sc["apps"] as? [[String: Any]] else {
            return []
        }
        #if canImport(AppKit)
        // The driver caches its app catalogue: direct measurement proved running=false/pid=0
        // can survive an explicit successful launch in the same helper. Native process identity
        // is read-only corroboration, never launch authority; preserve the discrepancy explicitly.
        let liveByBundle: [String: [Int]] = await MainActor.run {
            var identities: [String: [Int]] = [:]
            for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
                if let bundle = app.bundleIdentifier {
                    identities[bundle.lowercased(), default: []].append(Int(app.processIdentifier))
                }
            }
            return identities
        }
        #endif
        return try appsList.compactMap { dict in
            guard let bundleID = dict["bundle_id"] as? String else { return nil }
            let name = dict["name"] as? String ?? bundleID
            let pid = dict["pid"] as? Int
            let isRunning = dict["running"] as? Bool ?? (pid != nil && pid! > 0)
            guard isRunning ? (pid ?? 0) > 0 : (pid ?? 0) == 0 else {
                throw ComputerUseDriverError.driverToolFailed(tool: "list_apps", reason: "inconsistentApplicationState: upstream running/pid invariant violation for \(bundleID)")
            }
            #if canImport(AppKit)
            let live = liveByBundle[bundleID.lowercased()] ?? []
            guard live.count <= 1 else {
                throw ComputerUseDriverError.driverToolFailed(tool: "list_apps", reason: "inconsistentApplicationState: multiple verified live processes for \(bundleID)")
            }
            if let actualPID = live.first, !isRunning || pid != actualPID {
                return ApplicationInfo(bundleID: bundleID, pid: actualPID, name: name, isRunning: true,
                    discoveryConsistency: "upstream_stale_verified_native_identity", driverReportedPID: pid, driverReportedRunning: isRunning)
            }
            if isRunning && live.isEmpty {
                throw ComputerUseDriverError.driverToolFailed(tool: "list_apps", reason: "inconsistentApplicationState: upstream claims running without corroborated desktop process for \(bundleID)")
            }
            #endif
            return ApplicationInfo(bundleID: bundleID, pid: pid, name: name, isRunning: isRunning)
        }
    }

    /// Discovers visible windows belonging to a specific target process.
    public func listWindows(pid: Int) async throws -> [WindowInfo] {
        guard pid > 0 else { throw ComputerUseDriverError.driverToolFailed(tool: "list_windows", reason: "invalidArguments: positive pid required") }
        let resp = try await callTool(name: "list_windows", arguments: ["pid": pid])
        guard let sc = resp["structuredContent"] as? [String: Any],
              let winList = sc["windows"] as? [[String: Any]] else {
            return []
        }
        return winList.compactMap { dict in
            guard let winID = dict["window_id"] as? Int else { return nil }
            let title = dict["title"] as? String
            let boundsDict = dict["bounds"] as? [String: Any] ?? [:]
            let x = (boundsDict["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["height"] as? NSNumber)?.doubleValue ?? 0
            let bounds = WindowBounds(x: x, y: y, width: w, height: h)
            return WindowInfo(windowID: winID, pid: pid, title: title, bounds: bounds, isOnScreen: dict["is_on_screen"] as? Bool, layer: dict["layer"] as? Int)
        }
    }

    /// Launches an application by bundle identifier in background mode.
    ///
    /// cua-driver hands back an app that is already running as it is, even when it has no window
    /// of its own (its last window was closed and it stayed running, as terminals and editors do).
    /// Such an app gets the reopen request a Dock click sends, through LaunchServices without
    /// activating it, so it opens its default window the way `open -a` would.
    public func launchApplication(bundleID: String, background: Bool = true) async throws -> ApplicationLaunchResult {
        let wasRunning = Self.isRunning(bundleID: bundleID)
        let launched = try await launchThroughDriver(bundleID: bundleID, background: background)
        guard wasRunning,
              ComputerUseTargetStore.usableWindows(launched.windows, pid: launched.pid).isEmpty,
              await Self.reopenWithoutActivating(bundleID: bundleID) else { return launched }
        // Window creation can trail the reopen; the result then says launchedAwaitingWindow and
        // the next capture(target_app) finds the window.
        let windows = (try? await listWindows(pid: launched.pid)) ?? launched.windows
        return ApplicationLaunchResult(bundleID: bundleID, pid: launched.pid, windows: windows)
    }

    private static func isRunning(bundleID: String) -> Bool {
        #if canImport(AppKit)
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        #else
        return false
        #endif
    }

    private static func reopenWithoutActivating(bundleID: String) async -> Bool {
        #if canImport(AppKit)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
        #else
        return false
        #endif
    }

    private func launchThroughDriver(bundleID: String, background: Bool) async throws -> ApplicationLaunchResult {
        let resp = try await callTool(name: "launch_app", arguments: ["bundle_id": bundleID, "background": background])
        guard let sc = resp["structuredContent"] as? [String: Any],
              let pid = sc["pid"] as? Int else {
            let detail = (resp["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "Unknown error"
            throw ComputerUseDriverError.driverToolFailed(tool: "launch_app", reason: "Failed to launch \(bundleID): \(detail)")
        }
        let winList = (sc["windows"] as? [[String: Any]]) ?? []
        let windows: [WindowInfo] = winList.compactMap { dict in
            guard let winID = dict["window_id"] as? Int else { return nil }
            let title = dict["title"] as? String
            let boundsDict = dict["bounds"] as? [String: Any] ?? [:]
            let x = (boundsDict["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["height"] as? NSNumber)?.doubleValue ?? 0
            return WindowInfo(windowID: winID, pid: pid, title: title, bounds: WindowBounds(x: x, y: y, width: w, height: h), isOnScreen: dict["is_on_screen"] as? Bool, layer: dict["layer"] as? Int)
        }

        // Launch/process success and window readiness are independent. Discovery is explicit;
        // no fixed sleep loop, no focus manipulation, and no inferred correctness from delay.
        return ApplicationLaunchResult(bundleID: bundleID, pid: pid, windows: windows)
    }

    // MARK: - Stage 3: Normalized Window Observation

    /// Observes the target window state via driver backend:
    /// Captures normalized AX elements, geometry bounds, and window-only screenshot.
    public func observeWindow(target: WindowTarget) async throws -> ComputerUseObservation {
        let resp = try await callTool(name: "get_window_state", arguments: [
            "pid": target.pid,
            "window_id": target.windowID
        ])

        guard let sc = resp["structuredContent"] as? [String: Any] else {
            let detail = (resp["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "Unknown error"
            throw ComputerUseDriverError.driverToolFailed(tool: "get_window_state", reason: "Failed to observe window: \(detail)")
        }

        let snapshotID = sc["snapshot_id"] as? String ?? ""

        // Window bounds in screen coordinates
        let wb = sc["window_bounds"] as? [String: Any] ?? [:]
        let wbX = (wb["x"] as? NSNumber)?.doubleValue ?? 0
        let wbY = (wb["y"] as? NSNumber)?.doubleValue ?? 0
        let wbW = (wb["w"] as? NSNumber)?.doubleValue ?? (wb["width"] as? NSNumber)?.doubleValue ?? 0
        let wbH = (wb["h"] as? NSNumber)?.doubleValue ?? (wb["height"] as? NSNumber)?.doubleValue ?? 0

        // Authoritative window coordinate space: if root AX element has role AXWindow and larger area, prefer it
        var effWbX = wbX
        var effWbY = wbY
        var effWbW = wbW
        var effWbH = wbH

        let rawElements = (sc["elements"] as? [[String: Any]]) ?? []
        if let rootElem = rawElements.first(where: { ($0["role"] as? String) == "AXWindow" }),
           let f = rootElem["frame"] as? [String: Any] {
            let rX = (f["x"] as? NSNumber)?.doubleValue ?? 0
            let rY = (f["y"] as? NSNumber)?.doubleValue ?? 0
            let rW = (f["w"] as? NSNumber)?.doubleValue ?? (f["width"] as? NSNumber)?.doubleValue ?? 0
            let rH = (f["h"] as? NSNumber)?.doubleValue ?? (f["height"] as? NSNumber)?.doubleValue ?? 0
            if (rW * rH) > (effWbW * effWbH) || (effWbW == 0 && effWbH == 0) {
                effWbX = rX
                effWbY = rY
                effWbW = rW
                effWbH = rH
            }
        }
        let windowBounds = WindowBounds(x: effWbX, y: effWbY, width: effWbW, height: effWbH)

        // Parse accessibility elements and normalize frames relative to window origin
        let elements: [ComputerUseElement] = rawElements.compactMap { dict in
            guard let token = dict["element_token"] as? String else { return nil }
            let index = (dict["element_index"] as? NSNumber)?.intValue ?? 0
            let role = dict["role"] as? String ?? "AXUnknown"
            let label = dict["label"] as? String
            let title = dict["title"] as? String
            let value = dict["value"] as? String
            let isEnabled = dict["enabled"] as? Bool ?? true
            let actions = dict["actions"] as? [String] ?? []

            let f = dict["frame"] as? [String: Any] ?? [:]
            let fx = (f["x"] as? NSNumber)?.doubleValue ?? 0
            let fy = (f["y"] as? NSNumber)?.doubleValue ?? 0
            let fw = (f["w"] as? NSNumber)?.doubleValue ?? (f["width"] as? NSNumber)?.doubleValue ?? 0
            let fh = (f["h"] as? NSNumber)?.doubleValue ?? (f["height"] as? NSNumber)?.doubleValue ?? 0

            let screenFrame = WindowBounds(x: fx, y: fy, width: fw, height: fh)
            let normalizedFrame = WindowBounds(
                x: fx - effWbX,
                y: fy - effWbY,
                width: fw,
                height: fh
            )

            return ComputerUseElement(
                token: token,
                index: index,
                role: role,
                label: label,
                title: title,
                value: value,
                isEnabled: isEnabled,
                actions: actions,
                screenFrame: screenFrame,
                normalizedFrame: normalizedFrame
            )
        }

        // Extract raw window screenshot from content
        var screenshotData: Data? = nil
        let contents = (resp["content"] as? [[String: Any]]) ?? []
        for item in contents {
            if let type = item["type"] as? String, type == "image",
               let b64 = item["data"] as? String,
               let data = Data(base64Encoded: b64) {
                screenshotData = data
                break
            }
        }

        let treeMarkdown = sc["tree_markdown"] as? String

        return ComputerUseObservation(
            snapshotID: snapshotID,
            target: target,
            windowBounds: windowBounds,
            elements: elements,
            treeMarkdown: treeMarkdown,
            screenshotData: screenshotData,
            timestamp: Date()
        )
    }

    // MARK: - Stage 5 & Stage 7: Mechanical Actions

    /// Stage 5: Performs a mechanical click on an element reference in background mode.
    public func click(element: ComputerUseElementRef) async throws -> ComputerUseDriverActionResult {
        try await click(element: element, deliveryMode: "background")
    }

    /// Performs a mechanical click on an element reference with specified delivery mode.
    public func click(element: ComputerUseElementRef, deliveryMode: String?) async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        let args: [String: Any] = [
            "element_token": element.backendToken,
            "pid": element.target.pid,
            "window_id": element.target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        return try await executeAction(name: "click", element: element, target: element.target, args: args)
    }

    /// Stage 7: Performs a double click on an element reference.
    public func doubleClick(element: ComputerUseElementRef, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        let args: [String: Any] = [
            "element_token": element.backendToken,
            "pid": element.target.pid,
            "window_id": element.target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        return try await executeAction(name: "double_click", element: element, target: element.target, args: args)
    }

    /// Stage 7: Performs a right click on an element reference.
    public func rightClick(element: ComputerUseElementRef, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        let args: [String: Any] = [
            "element_token": element.backendToken,
            "pid": element.target.pid,
            "window_id": element.target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        return try await executeAction(name: "right_click", element: element, target: element.target, args: args)
    }

    /// Stage 7: Injects typed text into a target element or window.
    public func typeText(text: String, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        var args: [String: Any] = [
            "text": text,
            "pid": target.pid,
            "window_id": target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        if let element {
            args["element_token"] = element.backendToken
        }
        return try await executeAction(name: "type_text", element: element, target: target, args: args)
    }

    /// Stage 7: Injects a key press into a target window.
    public func pressKey(key: String, target: WindowTarget, modifiers: [String]? = nil, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        var args: [String: Any] = [
            "key": key,
            "pid": target.pid,
            "window_id": target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        if let modifiers, !modifiers.isEmpty {
            args["modifiers"] = modifiers
        }
        return try await executeAction(name: "press_key", element: nil, target: target, args: args)
    }

    /// Stage 7: Injects a hotkey chord into a target window.
    public func hotkey(keys: [String], target: WindowTarget, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        let args: [String: Any] = [
            "keys": keys,
            "pid": target.pid,
            "window_id": target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        return try await executeAction(name: "hotkey", element: nil, target: target, args: args)
    }

    /// Stage 7: Directly sets the native accessibility value of an element.
    public func setValue(value: String, element: ComputerUseElementRef) async throws -> ComputerUseDriverActionResult {
        let args: [String: Any] = [
            "value": value,
            "pid": element.target.pid,
            "window_id": element.target.windowID,
            "element_token": element.backendToken
        ]
        return try await executeAction(name: "set_value", element: element, target: element.target, args: args)
    }

    /// Stage 7: Scrolls inside a window or element.
    public func scroll(direction: String, amount: Int? = nil, element: ComputerUseElementRef?, target: WindowTarget, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        var args: [String: Any] = [
            "direction": direction,
            "amount": amount ?? 3,
            "pid": target.pid,
            "window_id": target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        if let element {
            args["element_token"] = element.backendToken
        }
        return try await executeAction(name: "scroll", element: element, target: target, args: args)
    }

    /// Stage 7: Drags from one element to another within the target window.
    public func drag(from: ComputerUseElementRef, to: ComputerUseElementRef, deliveryMode: String? = "background") async throws -> ComputerUseDriverActionResult {
        let mode = deliveryMode ?? "background"
        let fromX = from.normalizedFrame.x + from.normalizedFrame.width / 2.0
        let fromY = from.normalizedFrame.y + from.normalizedFrame.height / 2.0
        let toX = to.normalizedFrame.x + to.normalizedFrame.width / 2.0
        let toY = to.normalizedFrame.y + to.normalizedFrame.height / 2.0
        let args: [String: Any] = [
            "from_x": fromX,
            "from_y": fromY,
            "to_x": toX,
            "to_y": toY,
            "pid": from.target.pid,
            "window_id": from.target.windowID,
            "delivery_mode": mode,
            "mode": mode
        ]
        return try await executeAction(name: "drag", element: from, target: from.target, args: args)
    }

    /// Stage 8: Governed foreground activation of a target window.
    public func activateWindow(target: WindowTarget) async throws -> Bool {
        #if canImport(AppKit)
        if let app = NSRunningApplication(processIdentifier: pid_t(target.pid)) {
            return app.activate(options: [])
        }
        #endif
        return true
    }

    private func executeAction(
        name: String,
        element: ComputerUseElementRef?,
        target: WindowTarget,
        args: [String: Any]
    ) async throws -> ComputerUseDriverActionResult {
        let resp = try await callTool(name: name, arguments: args)
        let sc = resp["structuredContent"] as? [String: Any] ?? [:]
        let route = sc["route"] as? String ?? (resp["route"] as? String)
        let delivery = sc["delivery"] as? [String: Any] ?? (resp["delivery"] as? [String: Any]) ?? [:]
        let mode = delivery["mode"] as? String ?? (args["delivery_mode"] as? String) ?? "background"
        let effect = sc["effect"] as? String ?? (resp["effect"] as? String)
        let isSuccess = (resp["isError"] as? Bool != true)
        let content = resp["content"] as? [[String: Any]] ?? []
        let detail = content.compactMap { $0["text"] as? String }.joined(separator: "\n")

        return ComputerUseDriverActionResult(
            receiptID: UUID(),
            actionType: name,
            elementRef: element,
            timestamp: Date(),
            isSuccess: isSuccess,
            route: route,
            mode: mode,
            effect: effect,
            detail: detail.isEmpty ? nil : detail
        )
    }
}
