import Foundation

/// Production-side macOS GUI verifier adapter and runtime (CUGV-G07, CUGV-G08, EC-B01).
///
/// Responsibilities:
/// 1. Structured invocation of XCUITest in an isolated process with generated invocation identity.
/// 2. Bounded, temporary result transport parsing (.xcresult + transport payload).
/// 3. Trust-boundary enforcement: untrusted test runner output is validated against
///    invocationID, requirementID, concreteVerifierIdentity, runID, and taskID before admission.
/// 4. Transport vs xcresult truth agreement: contradictory outcomes reject; never produce canonical PASS.
/// 5. Exact test identity normalization: bundle/suite/method strict matching without substring guessing.
/// 6. Conservative outcome mapping:
///    - Exact test terminal PASS -> VerificationResult.passed + deterministicTest(passed: true)
///    - Exact test terminal assertion FAIL -> VerificationResult.failed + deterministicTest(passed: false)
///    - Runner started without terminal test result -> VerificationResult.indeterminate (GV-I06)
///    - Test target unavailable / unexecutable -> VerificationResult.unsupported
/// 7. Atomic admission into ConversationRunCoordinator (EC-B01).
public final class MacOSGUIVerifierRuntime: @unchecked Sendable {
    public static let shared = MacOSGUIVerifierRuntime()

    private let processRunner: @Sendable (BoundedSubprocessRunner.Request) async -> BoundedSubprocessRunner.Outcome

    public init() {
        processRunner = { await BoundedSubprocessRunner().run($0) }
    }

    /// Injectable execution transport; all stage routing/parsing/admission remains production code.
    init(processRunner: @escaping @Sendable (BoundedSubprocessRunner.Request) async -> BoundedSubprocessRunner.Outcome) {
        self.processRunner = processRunner
    }

    // MARK: - Configuration

    public struct InvocationRequest: Sendable {
        public let invocationID: String
        public let projectPath: String
        public let scheme: String
        public let destination: String
        public let concreteVerifierIdentity: String
        public let requirementID: String
        public let runID: UUID
        public let taskID: String
        public let testStorageRoot: URL
        public let timeoutSeconds: TimeInterval
        public let captureID: String?
        public let verificationRunID: String?
        public let screenshotMetadataURL: URL?
        public let screenshotDataURL: URL?

        public init(
            invocationID: String = UUID().uuidString,
            projectPath: String = "src/macos/Limare.xcodeproj",
            scheme: String = "Limare",
            destination: String = "platform=macOS,arch=arm64",
            concreteVerifierIdentity: String,
            requirementID: String,
            runID: UUID,
            taskID: String,
            testStorageRoot: URL,
            timeoutSeconds: TimeInterval = 60.0,
            captureID: String? = nil,
            verificationRunID: String? = nil,
            screenshotMetadataURL: URL? = nil,
            screenshotDataURL: URL? = nil
        ) {
            self.invocationID = invocationID
            self.projectPath = projectPath
            self.scheme = scheme
            self.destination = destination
            self.concreteVerifierIdentity = concreteVerifierIdentity
            self.requirementID = requirementID
            self.runID = runID
            self.taskID = taskID
            self.testStorageRoot = testStorageRoot
            self.timeoutSeconds = timeoutSeconds
            self.captureID = captureID
            self.verificationRunID = verificationRunID
            self.screenshotMetadataURL = screenshotMetadataURL
            self.screenshotDataURL = screenshotDataURL
        }
    }

    // MARK: - Raw Execution Outcome (Untrusted)

    public struct RawExecutionOutcome: Sendable {
        public let exitCode: Int32
        public let xcresultPath: URL?
        public let transportFilePath: URL?
        public let screenshotMetadataPath: URL?
        public let screenshotDataPath: URL?
        public let exactTestPassed: Bool?
        public let exactTestFound: Bool
        public let runnerStarted: Bool
        public let trustBoundaryRejected: Bool
        public let runnerFailureMessage: String?
        public let rawStdout: String
        public let rawStderr: String
        public let timedOut: Bool
        public let cancelled: Bool

        public init(
            exitCode: Int32,
            xcresultPath: URL?,
            transportFilePath: URL?,
            screenshotMetadataPath: URL? = nil,
            screenshotDataPath: URL? = nil,
            exactTestPassed: Bool?,
            exactTestFound: Bool,
            runnerStarted: Bool,
            trustBoundaryRejected: Bool = false,
            runnerFailureMessage: String?,
            rawStdout: String,
            rawStderr: String,
            timedOut: Bool,
            cancelled: Bool = false
        ) {
            self.exitCode = exitCode
            self.xcresultPath = xcresultPath
            self.transportFilePath = transportFilePath
            self.screenshotMetadataPath = screenshotMetadataPath
            self.screenshotDataPath = screenshotDataPath
            self.exactTestPassed = exactTestPassed
            self.exactTestFound = exactTestFound
            self.runnerStarted = runnerStarted
            self.trustBoundaryRejected = trustBoundaryRejected
            self.runnerFailureMessage = runnerFailureMessage
            self.rawStdout = rawStdout
            self.rawStderr = rawStderr
            self.timedOut = timedOut
            self.cancelled = cancelled
        }
    }

    // MARK: - Transport Payload (Untrusted JSON)

    public struct TransportPayload: Codable, Sendable {
        public let invocationID: String
        public let taskID: String
        public let runID: String
        public let requirementID: String
        public let testID: String
        public let testMethod: String?
        public let passed: Bool
        public let timestamp: Double

        public init(
            invocationID: String,
            taskID: String,
            runID: String,
            requirementID: String,
            testID: String,
            testMethod: String? = nil,
            passed: Bool,
            timestamp: Double = Date().timeIntervalSince1970
        ) {
            self.invocationID = invocationID
            self.taskID = taskID
            self.runID = runID
            self.requirementID = requirementID
            self.testID = testID
            self.testMethod = testMethod
            self.passed = passed
            self.timestamp = timestamp
        }
    }

    // MARK: - Build Products & Test Run Discovery

    public struct BuildProductSettings: Sendable {
        public let buildDir: URL
        public let builtProductsDir: URL

        public init(buildDir: URL, builtProductsDir: URL) {
            self.buildDir = buildDir
            self.builtProductsDir = builtProductsDir
        }
    }

    /// Queries structured build settings from Xcode for the specified project, scheme, and configuration.
    public static func resolveBuildProductSettings(
        projectPath: String, scheme: String, configuration: String = "Debug"
    ) async -> BuildProductSettings? {
        await resolveBuildProductSettings(
            projectPath: projectPath, scheme: scheme, configuration: configuration,
            processRunner: { await BoundedSubprocessRunner().run($0) }
        )
    }

    static func resolveBuildProductSettings(
        projectPath: String,
        scheme: String,
        configuration: String = "Debug",
        processRunner: @escaping @Sendable (BoundedSubprocessRunner.Request) async -> BoundedSubprocessRunner.Outcome
    ) async -> BuildProductSettings? {
        let raw = await processRunner(.init(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "-project", projectPath, "-scheme", scheme,
                        "-configuration", configuration, "-showBuildSettings"],
            timeoutSeconds: 30
        ))
        guard !raw.cancelled, !raw.timedOut, raw.exitCode == 0, !raw.stdoutTruncated else { return nil }
        let output = raw.stdout
        var buildDirStr: String?
        var builtProductsDirStr: String?
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("BUILD_DIR = ") {
                buildDirStr = String(trimmed.dropFirst("BUILD_DIR = ".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("BUILT_PRODUCTS_DIR = ") {
                builtProductsDirStr = String(trimmed.dropFirst("BUILT_PRODUCTS_DIR = ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let bDir = buildDirStr, let bpDir = builtProductsDirStr {
            return BuildProductSettings(
                buildDir: URL(fileURLWithPath: bDir),
                builtProductsDir: URL(fileURLWithPath: bpDir)
            )
        }
        return nil
    }

    /// Searches candidate directories for a matching `.xctestrun` file for the declared scheme.
    public static func locateXCTestRun(in directories: [URL], scheme: String) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        for dir in directories {
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "xctestrun" && !fileURL.lastPathComponent.hasPrefix("inv_") {
                    candidates.append(fileURL)
                }
            }
        }

        let matching = candidates.filter { url in
            let name = url.lastPathComponent
            if name.hasPrefix("\(scheme)_") || name.hasPrefix("\(scheme).") || name == "\(scheme).xctestrun" {
                return true
            }
            if let data = try? Data(contentsOf: url),
               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
               let containerInfo = plist["ContainerInfo"] as? [String: Any],
               let schemeName = containerInfo["SchemeName"] as? String,
               schemeName == scheme {
                return true
            }
            return false
        }

        return matching.sorted { u1, u2 in
            let date1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let date2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return date1 > date2
        }.first
    }

    /// Structured preparation running `xcodebuild build-for-testing` when `.xctestrun` is absent.
    public static func buildXCTestRunForTesting(
        projectPath: String, scheme: String, destination: String
    ) async -> Bool {
        await buildXCTestRunForTesting(
            projectPath: projectPath, scheme: scheme, destination: destination,
            processRunner: { await BoundedSubprocessRunner().run($0) }
        )
    }

    static func buildXCTestRunForTesting(
        projectPath: String,
        scheme: String,
        destination: String,
        processRunner: @escaping @Sendable (BoundedSubprocessRunner.Request) async -> BoundedSubprocessRunner.Outcome
    ) async -> Bool {
        let raw = await processRunner(.init(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild", "build-for-testing", "-project", projectPath,
                        "-scheme", scheme, "-destination", destination,
                        "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO",
                        "CODE_SIGNING_ALLOWED=NO", "-quiet"],
            timeoutSeconds: 180
        ))
        return !raw.cancelled && !raw.timedOut && raw.exitCode == 0
    }

    // MARK: - Core Execution Entrypoint

    /// Executes the mechanical GUI verifier for a declared requirement,
    /// validates the untrusted outcome across the process boundary,
    /// and atomically admits the result and receipt into the coordinator.
    @MainActor
    func executeVerification(
        request: InvocationRequest,
        coordinator: ConversationRunCoordinator
    ) async -> (admitted: Bool, result: VerificationResult?, receipt: EvidenceReceipt?) {
        // 1. Invoke the test runner subprocess
        let raw = await runTestProcess(request: request)

        guard !Task.isCancelled, !raw.cancelled else { return (false, nil, nil) }

        // 2. Validate untrusted output and map to canonical result + receipt
        return validateAndAdmit(raw: raw, request: request, coordinator: coordinator)
    }

    // MARK: - Subprocess Invocation

    public func runTestProcess(request: InvocationRequest) async -> RawExecutionOutcome {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let resultBundleURL = tempDir.appendingPathComponent("gv_\(request.invocationID).xcresult")
        let transportFileURL = tempDir.appendingPathComponent("gv_transport_\(request.invocationID).json")

        let fileManager = FileManager.default

        // 1. Dynamically resolve build products directory from project and scheme
        guard let buildSettings = await Self.resolveBuildProductSettings(
            projectPath: request.projectPath,
            scheme: request.scheme,
            processRunner: processRunner
        ) else {
            if Task.isCancelled { return cancelledOutcome() }
            return RawExecutionOutcome(
                exitCode: -1,
                xcresultPath: nil,
                transportFilePath: nil,
                exactTestPassed: nil,
                exactTestFound: false,
                runnerStarted: false,
                trustBoundaryRejected: false,
                runnerFailureMessage: "Failed to resolve build product settings for project \(request.projectPath) and scheme \(request.scheme)",
                rawStdout: "",
                rawStderr: "Could not resolve build settings",
                timedOut: false
            )
        }

        guard !Task.isCancelled else { return cancelledOutcome() }

        // 2. Discover existing .xctestrun or prepare one deterministically via build-for-testing
        var matchingXCTestRun = Self.locateXCTestRun(
            in: [buildSettings.buildDir, buildSettings.builtProductsDir],
            scheme: request.scheme
        )

        if matchingXCTestRun == nil {
            let prepared = await Self.buildXCTestRunForTesting(
                projectPath: request.projectPath,
                scheme: request.scheme,
                destination: request.destination,
                processRunner: processRunner
            )
            guard !Task.isCancelled else { return cancelledOutcome() }
            if prepared {
                matchingXCTestRun = Self.locateXCTestRun(
                    in: [buildSettings.buildDir, buildSettings.builtProductsDir],
                    scheme: request.scheme
                )
            }
        }

        guard let baseXCTestRunURL = matchingXCTestRun else {
            return RawExecutionOutcome(
                exitCode: -1,
                xcresultPath: nil,
                transportFilePath: nil,
                exactTestPassed: nil,
                exactTestFound: false,
                runnerStarted: false,
                trustBoundaryRejected: false,
                runnerFailureMessage: "No valid matching .xctestrun found for scheme \(request.scheme) after build preparation",
                rawStdout: "",
                rawStderr: "No matching .xctestrun found",
                timedOut: false
            )
        }

        let productsDir = baseXCTestRunURL.deletingLastPathComponent()
        var customXCTestRunURL: URL? = nil

        var arguments: [String] = []

        if fileManager.fileExists(atPath: baseXCTestRunURL.path),
           let data = try? Data(contentsOf: baseXCTestRunURL),
           var plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           var testConfigs = plist["TestConfigurations"] as? [[String: Any]],
           !testConfigs.isEmpty,
           var testTargets = testConfigs[0]["TestTargets"] as? [[String: Any]],
           !testTargets.isEmpty {

            var target = testTargets[0]
            var envVars = (target["EnvironmentVariables"] as? [String: String]) ?? [:]
            envVars["GUI_VERIFICATION_INVOCATION_ID"] = request.invocationID
            envVars["GUI_VERIFICATION_TASK_ID"] = request.taskID
            envVars["GUI_VERIFICATION_RUN_ID"] = request.runID.uuidString
            envVars["GUI_VERIFICATION_REQUIREMENT_ID"] = request.requirementID
            envVars["GUI_VERIFICATION_TEST_ID"] = request.concreteVerifierIdentity
            envVars["GUI_VERIFICATION_TRANSPORT_FILE"] = transportFileURL.path
            if let captureID = request.captureID {
                envVars["GUI_VERIFICATION_CAPTURE_ID"] = captureID
            }
            if let vRunID = request.verificationRunID {
                envVars["GUI_VERIFICATION_VERIFICATION_RUN_ID"] = vRunID
            }
            if let metaURL = request.screenshotMetadataURL {
                envVars["GUI_VERIFICATION_SCREENSHOT_METADATA_FILE"] = metaURL.path
            }
            if let dataURL = request.screenshotDataURL {
                envVars["GUI_VERIFICATION_SCREENSHOT_DATA_FILE"] = dataURL.path
            }
            envVars["UI_TEST_MODE"] = "1"
            envVars["UI_TEST_STORAGE_ROOT"] = request.testStorageRoot.path
            target["EnvironmentVariables"] = envVars

            var uiTargetEnvs = (target["UITargetAppEnvironmentVariables"] as? [String: String]) ?? [:]
            uiTargetEnvs["UI_TEST_MODE"] = "1"
            uiTargetEnvs["UI_TEST_STORAGE_ROOT"] = request.testStorageRoot.path
            target["UITargetAppEnvironmentVariables"] = uiTargetEnvs

            testTargets[0] = target
            testConfigs[0]["TestTargets"] = testTargets
            plist["TestConfigurations"] = testConfigs

            if let mutatedData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                let invocationXCTestRun = productsDir.appendingPathComponent("inv_\(request.invocationID).xctestrun")
                if (try? mutatedData.write(to: invocationXCTestRun)) != nil {
                    customXCTestRunURL = invocationXCTestRun
                }
            }
        }

        if let customXCTestRunURL {
            arguments = [
                "test-without-building",
                "-xctestrun", customXCTestRunURL.path,
                "-resultBundlePath", resultBundleURL.path,
                "-destination", request.destination,
                "-only-testing:\(request.concreteVerifierIdentity)",
                "CODE_SIGN_IDENTITY=-",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "-quiet"
            ]
        } else {
            arguments = [
                "test-without-building",
                "-xctestrun", baseXCTestRunURL.path,
                "-resultBundlePath", resultBundleURL.path,
                "-destination", request.destination,
                "-only-testing:\(request.concreteVerifierIdentity)",
                "-parallel-testing-enabled", "NO",
                "CODE_SIGN_IDENTITY=-",
                "CODE_SIGNING_REQUIRED=NO",
                "CODE_SIGNING_ALLOWED=NO",
                "-quiet"
            ]
        }

        var env = ProcessInfo.processInfo.environment
        env["UI_TEST_MODE"] = "1"
        env["UI_TEST_STORAGE_ROOT"] = request.testStorageRoot.path
        env["GUI_VERIFICATION_INVOCATION_ID"] = request.invocationID
        env["GUI_VERIFICATION_TASK_ID"] = request.taskID
        env["GUI_VERIFICATION_RUN_ID"] = request.runID.uuidString
        env["GUI_VERIFICATION_REQUIREMENT_ID"] = request.requirementID
        env["GUI_VERIFICATION_TEST_ID"] = request.concreteVerifierIdentity
        env["GUI_VERIFICATION_TRANSPORT_FILE"] = transportFileURL.path
        if let captureID = request.captureID {
            env["GUI_VERIFICATION_CAPTURE_ID"] = captureID
        }
        if let vRunID = request.verificationRunID {
            env["GUI_VERIFICATION_VERIFICATION_RUN_ID"] = vRunID
        }
        if let metaURL = request.screenshotMetadataURL {
            env["GUI_VERIFICATION_SCREENSHOT_METADATA_FILE"] = metaURL.path
        }
        if let dataURL = request.screenshotDataURL {
            env["GUI_VERIFICATION_SCREENSHOT_DATA_FILE"] = dataURL.path
        }

        guard !Task.isCancelled else {
            if let customXCTestRunURL { try? fileManager.removeItem(at: customXCTestRunURL) }
            return cancelledOutcome()
        }
        let execution = await processRunner(.init(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcodebuild"] + arguments,
            environment: env,
            timeoutSeconds: request.timeoutSeconds
        ))
        let stdoutStr = execution.stdout
        let stderrStr = execution.stderr
        if execution.cancelled || Task.isCancelled {
            if let customXCTestRunURL { try? fileManager.removeItem(at: customXCTestRunURL) }
            return cancelledOutcome(stdout: stdoutStr, stderr: stderrStr)
        }
        if !execution.launched {
            if let customXCTestRunURL { try? fileManager.removeItem(at: customXCTestRunURL) }
            return RawExecutionOutcome(
                exitCode: -1, xcresultPath: nil, transportFilePath: nil,
                exactTestPassed: nil, exactTestFound: false, runnerStarted: false,
                runnerFailureMessage: execution.launchError,
                rawStdout: stdoutStr, rawStderr: stderrStr, timedOut: false
            )
        }

        // Parse transport outcome if present
        let parsed = await parseOutcome(
            resultBundleURL: resultBundleURL,
            transportFileURL: transportFileURL,
            request: request,
            stdout: stdoutStr,
            stderr: stderrStr
        )

        // Clean up temporary xctestrun file
        if let customXCTestRunURL {
            try? fileManager.removeItem(at: customXCTestRunURL)
        }

        return RawExecutionOutcome(
            exitCode: execution.exitCode ?? -1,
            xcresultPath: fileManager.fileExists(atPath: resultBundleURL.path) ? resultBundleURL : nil,
            transportFilePath: fileManager.fileExists(atPath: transportFileURL.path) ? transportFileURL : nil,
            screenshotMetadataPath: (request.screenshotMetadataURL != nil && fileManager.fileExists(atPath: request.screenshotMetadataURL!.path)) ? request.screenshotMetadataURL : nil,
            screenshotDataPath: (request.screenshotDataURL != nil && fileManager.fileExists(atPath: request.screenshotDataURL!.path)) ? request.screenshotDataURL : nil,
            exactTestPassed: parsed.passed,
            exactTestFound: parsed.found,
            runnerStarted: parsed.runnerStarted,
            trustBoundaryRejected: parsed.trustBoundaryRejected,
            runnerFailureMessage: parsed.failureMessage,
            rawStdout: stdoutStr,
            rawStderr: stderrStr,
            timedOut: execution.timedOut,
            cancelled: Task.isCancelled
        )
    }

    private func cancelledOutcome(stdout: String = "", stderr: String = "") -> RawExecutionOutcome {
        RawExecutionOutcome(
            exitCode: -1, xcresultPath: nil, transportFilePath: nil,
            exactTestPassed: nil, exactTestFound: false, runnerStarted: false,
            runnerFailureMessage: nil, rawStdout: stdout, rawStderr: stderr,
            timedOut: false, cancelled: true
        )
    }

    // MARK: - Untrusted Outcome Parsing

    public func parseOutcome(
        resultBundleURL: URL,
        transportFileURL: URL,
        request: InvocationRequest,
        stdout: String,
        stderr: String
    ) async -> (passed: Bool?, found: Bool, runnerStarted: Bool, trustBoundaryRejected: Bool, failureMessage: String?) {
        let fileManager = FileManager.default

        var transportFound = false
        var transportPassed: Bool? = nil
        var correlationFailureMsg: String? = nil

        // 1. Check bounded transport file first
        if fileManager.fileExists(atPath: transportFileURL.path),
           let data = try? Data(contentsOf: transportFileURL),
           let payload = try? JSONDecoder().decode(TransportPayload.self, from: data) {

            // Validate cross-process correlation fields against request (§5 & §6)
            if payload.invocationID != request.invocationID {
                correlationFailureMsg = "Invocation ID mismatch: expected \(request.invocationID), got \(payload.invocationID)"
            } else if payload.taskID != request.taskID {
                correlationFailureMsg = "Task ID mismatch: expected \(request.taskID), got \(payload.taskID)"
            } else if payload.runID != request.runID.uuidString {
                correlationFailureMsg = "Run ID mismatch: expected \(request.runID.uuidString), got \(payload.runID)"
            } else if payload.requirementID != request.requirementID {
                correlationFailureMsg = "Requirement ID mismatch: expected \(request.requirementID), got \(payload.requirementID)"
            } else if payload.testID != request.concreteVerifierIdentity {
                correlationFailureMsg = "Test ID mismatch: expected \(request.concreteVerifierIdentity), got \(payload.testID)"
            } else {
                transportFound = true
                transportPassed = payload.passed
            }
        }

        if let correlationFailureMsg {
            // Mismatch: REJECT immediately. Untrusted / foreign payload MUST NOT create canonical outcome truth.
            return (passed: nil, found: false, runnerStarted: false, trustBoundaryRejected: true, failureMessage: correlationFailureMsg)
        }

        // 2. Parse .xcresult using xcresulttool
        var xcresultFound = false
        var xcresultPassed: Bool? = nil
        var xcresultRunnerStarted = false
        var xcresultFailureMsg: String? = nil

        if fileManager.fileExists(atPath: resultBundleURL.path) {
            let res = await parseXCResult(at: resultBundleURL, concreteIdentity: request.concreteVerifierIdentity)
            xcresultFound = res.found
            xcresultPassed = res.passed
            xcresultRunnerStarted = res.runnerStarted
            xcresultFailureMsg = res.failureMessage
        }

        // 3. Truth reconciliation between Transport and xcresult (§8 & ADV-B15)
        if transportFound && xcresultFound {
            if let tPassed = transportPassed, let xPassed = xcresultPassed {
                if tPassed != xPassed {
                    // Contradiction! (ADV-B15) Never canonical PASS.
                    return (passed: nil, found: false, runnerStarted: true, trustBoundaryRejected: false, failureMessage: "Contradiction between transport and xcresult verdicts")
                }
                return (passed: tPassed, found: true, runnerStarted: true, trustBoundaryRejected: false, failureMessage: nil)
            }
        }

        if transportFound {
            return (passed: transportPassed, found: true, runnerStarted: true, trustBoundaryRejected: false, failureMessage: nil)
        }

        if xcresultFound {
            return (passed: xcresultPassed, found: true, runnerStarted: true, trustBoundaryRejected: false, failureMessage: xcresultFailureMsg)
        }

        // 4. Infrastructure diagnostics: only used to detect runner-start / infrastructure failures (§14)
        let runnerStarted = xcresultRunnerStarted ||
                            stdout.contains("Running tests...") ||
                            stdout.contains("LimareUITests-Runner") ||
                            stderr.contains("LimareUITests-Runner") ||
                            stdout.contains("Testing started")

        var failureMsg: String? = xcresultFailureMsg
        if failureMsg == nil {
            if stdout.contains("Timed out while enabling automation mode") ||
               stderr.contains("Timed out while enabling automation mode") {
                failureMsg = "Timed out while enabling automation mode"
            } else if stdout.contains("The test runner failed to initialize") {
                failureMsg = "The test runner failed to initialize for UI testing"
            }
        }

        return (passed: nil, found: false, runnerStarted: runnerStarted, trustBoundaryRejected: false, failureMessage: failureMsg)
    }

    public func parseXCResult(
        at url: URL,
        concreteIdentity: String
    ) async -> (passed: Bool?, found: Bool, runnerStarted: Bool, failureMessage: String?) {
        guard !Task.isCancelled else { return (nil, false, false, nil) }
        let raw = await processRunner(.init(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", url.path],
            timeoutSeconds: 30,
            outputLimitBytes: 16 * 1024 * 1024
        ))
        guard !raw.cancelled, !Task.isCancelled, !raw.timedOut,
              raw.exitCode == 0, !raw.stdoutTruncated else { return (nil, false, false, nil) }
        if let json = try? JSONSerialization.jsonObject(with: Data(raw.stdout.utf8)) as? [String: Any],
           let testNodes = json["testNodes"] as? [[String: Any]] {
            return inspectTestNodes(testNodes, targetIdentity: concreteIdentity)
        }

        return (passed: nil, found: false, runnerStarted: false, failureMessage: nil)
    }

    public func inspectTestNodes(
        _ nodes: [[String: Any]],
        targetIdentity: String
    ) -> (passed: Bool?, found: Bool, runnerStarted: Bool, failureMessage: String?) {
        var exactPassed: Bool? = nil
        var exactFound = false
        var runnerStarted = false
        var failureMessage: String? = nil

        func recurse(_ items: [[String: Any]], bundle: String?, suite: String?) {
            for item in items {
                let name = item["name"] as? String ?? ""
                let result = item["result"] as? String ?? ""
                let nodeType = item["nodeType"] as? String ?? ""

                let currentBundle = (nodeType == "UI test bundle") ? name : bundle
                let currentSuite = (nodeType == "Test Suite") ? name : suite

                if nodeType == "UI test bundle" || name.contains("UITests") {
                    runnerStarted = true
                }

                if name.contains("encountered an error") || name.contains("Timed out while enabling automation mode") {
                    runnerStarted = true
                    failureMessage = name
                }

                if nodeType == "Test Case" {
                    // Exact test identity normalization (§7):
                    // Canonical shape: bundle/suite/method
                    let cleanMethod = name.hasSuffix("()") ? String(name.dropLast(2)) : name
                    let canonicalID: String
                    if let b = currentBundle, let s = currentSuite {
                        canonicalID = "\(b)/\(s)/\(cleanMethod)"
                    } else if let s = currentSuite {
                        canonicalID = "\(s)/\(cleanMethod)"
                    } else {
                        canonicalID = cleanMethod
                    }

                    // Strict equality comparison without substring guessing
                    if canonicalID == targetIdentity {
                        exactFound = true
                        if result == "Passed" {
                            exactPassed = true
                        } else if result == "Failed" {
                            exactPassed = false
                        }
                    }
                }

                if let children = item["children"] as? [[String: Any]] {
                    recurse(children, bundle: currentBundle, suite: currentSuite)
                }
            }
        }

        recurse(nodes, bundle: nil, suite: nil)
        return (passed: exactPassed, found: exactFound, runnerStarted: runnerStarted, failureMessage: failureMessage)
    }

    // MARK: - Validation & Admission (Trust Boundary Enforcement)

    @MainActor
    func validateAndAdmit(
        raw: RawExecutionOutcome,
        request: InvocationRequest,
        coordinator: ConversationRunCoordinator
    ) -> (admitted: Bool, result: VerificationResult?, receipt: EvidenceReceipt?) {
        guard !Task.isCancelled, !raw.cancelled else { return (false, nil, nil) }
        // 0. Trust-boundary correlation failure: payload is FOREIGN / UNTRUSTED.
        // It MUST NOT indirectly create a canonical requirement result or evidence receipt.
        if raw.trustBoundaryRejected {
            return (admitted: false, result: nil, receipt: nil)
        }

        // Evaluate terminal state conservatively:
        // 1. Exact test terminal PASS
        if raw.exactTestFound, raw.exactTestPassed == true {
            let (result, receipt) = makePair(isPassed: true, request: request)
            let admitted = coordinator.recordMechanicalVerification(
                runID: request.runID,
                verificationResult: result,
                evidenceReceipt: receipt
            )
            return (admitted, result, receipt)
        }

        // 2. Exact test terminal assertion FAIL
        if raw.exactTestFound, raw.exactTestPassed == false {
            let (result, receipt) = makePair(isPassed: false, request: request)
            let admitted = coordinator.recordMechanicalVerification(
                runID: request.runID,
                verificationResult: result,
                evidenceReceipt: receipt
            )
            return (admitted, result, receipt)
        }

        // 3. Runner started, but no authoritative terminal exact-test result -> indeterminate (GV-I06)
        if raw.runnerStarted || raw.timedOut {
            let indeterminateResult = VerificationResult(
                requirementID: request.requirementID,
                verifierIdentity: request.concreteVerifierIdentity,
                resultState: .indeterminate,
                evidenceReferences: VerificationEvidenceReferences(receiptIDs: []),
                correlation: VerificationCorrelation(runID: request.runID)
            )
            let admitted = coordinator.recordVerificationResult(
                runID: request.runID,
                result: indeterminateResult
            )
            return (admitted, indeterminateResult, nil)
        }

        // 4. Runner / infrastructure unavailable before execution -> unsupported
        let unsupportedResult = VerificationResult(
            requirementID: request.requirementID,
            verifierIdentity: request.concreteVerifierIdentity,
            resultState: .unsupported,
            evidenceReferences: VerificationEvidenceReferences(receiptIDs: []),
            correlation: VerificationCorrelation(runID: request.runID)
        )
        let admitted = coordinator.recordVerificationResult(
            runID: request.runID,
            result: unsupportedResult
        )
        return (admitted, unsupportedResult, nil)
    }

    // MARK: - Pair Construction

    public func makePair(
        isPassed: Bool,
        request: InvocationRequest
    ) -> (result: VerificationResult, receipt: EvidenceReceipt) {
        let receipt = EvidenceReceipt(
            taskID: request.taskID,
            runID: request.runID,
            turnID: "gui-verification-\(request.runID)",
            sourceCallID: request.concreteVerifierIdentity,
            observation: .deterministicTest(
                testID: request.concreteVerifierIdentity,
                targetArtifactID: nil,
                targetRevisionID: nil,
                passed: isPassed,
                exitCode: isPassed ? 0 : 1,
                detail: nil
            ),
            reportedCanonicalOwnerDomain: "gui_verifier"
        )

        let result = VerificationResult(
            requirementID: request.requirementID,
            verifierIdentity: request.concreteVerifierIdentity,
            resultState: isPassed ? .passed : .failed,
            evidenceReferences: VerificationEvidenceReferences(receiptIDs: [receipt.id]),
            correlation: VerificationCorrelation(runID: request.runID)
        )

        return (result, receipt)
    }
}
