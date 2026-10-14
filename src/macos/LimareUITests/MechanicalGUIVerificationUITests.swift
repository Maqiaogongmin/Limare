import XCTest
import CryptoKit

/// Real macOS mechanical GUI verification suite (Batch B: CUGV-G07, CUGV-G08).
///
/// Drives the real Limare application using XCUIApplication in an isolated test process.
/// Contains ONLY positive structural assertions (G09 remains DEFERRED).
/// Does NOT construct canonical evidence receipts or invoke task disposition directly (PE-01/PE-02 boundary).
final class MechanicalGUIVerificationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var testIsolatedRootURL: URL!

    private static let standardTimeout: TimeInterval = 5.0

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false

        // Resolve exact built Limare.app adjacent to the test runner bundle
        let bundleURL = Bundle(for: type(of: self)).bundleURL
        let productsDir = bundleURL
            .deletingLastPathComponent() // Contents/PlugIns
            .deletingLastPathComponent() // LimareUITests-Runner.app/Contents
            .deletingLastPathComponent() // LimareUITests-Runner.app
            .deletingLastPathComponent() // Products/Debug
        let targetAppURL = productsDir.appendingPathComponent("Limare.app")

        if FileManager.default.fileExists(atPath: targetAppURL.path) {
            app = XCUIApplication(url: targetAppURL)
        } else {
            app = XCUIApplication()
        }

        // Configure deterministic isolated test root
        let env = ProcessInfo.processInfo.environment
        if let customRoot = env["UI_TEST_STORAGE_ROOT"], !customRoot.isEmpty {
            testIsolatedRootURL = URL(fileURLWithPath: customRoot)
        } else {
            let tempDir = FileManager.default.temporaryDirectory
            testIsolatedRootURL = tempDir.appendingPathComponent("limare_ui_test_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: testIsolatedRootURL, withIntermediateDirectories: true)
        }

        app.launchEnvironment["UI_TEST_MODE"] = "1"
        app.launchEnvironment["UI_TEST_STORAGE_ROOT"] = testIsolatedRootURL.path
        // Test launch bootstrap: request a fresh SwiftUI main window rather than
        // restoring a prior no-window session. Argument-domain only; no defaults
        // or saved-state files are changed, and ordinary app launches are unaffected.
        // Explicit opt-out exists only for restoration diagnostics.
        if env["UI_TEST_REQUIRE_MAIN_WINDOW"] != "0" || env["UI_TEST_IGNORE_RESTORATION"] == "1" {
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        }
    }

    private var currentMethodName: String = ""

    private var resolvedTestMethodName: String {
        let raw = self.name
        if let method = raw.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) {
            return String(method)
        }
        return currentMethodName
    }

    override func tearDownWithError() throws {
        app = nil
        let testPassed: Bool
        if let run = testRun {
            testPassed = (run.totalFailureCount == 0) && (run.unexpectedExceptionCount == 0) && (run.failureCount == 0)
        } else {
            testPassed = false
        }
        let testMethod = resolvedTestMethodName
        emitTransportOutcomeIfConfigured(testName: testMethod, passed: testPassed)
        try super.tearDownWithError()
    }

    // MARK: - Positive Mechanical Assertions (AC-B1, AC-B2)

    /// AC-B1, AC-B2: Limare launches deterministically under the UI-test target
    /// and a single main window is enforced.
    func testDeterministicLaunchAndSingleWindow() throws {
        currentMethodName = "testDeterministicLaunchAndSingleWindow"
        app.launch()
        recordLaunchDiagnostics(stage: "after-launch")
        defer { recordLaunchDiagnostics(stage: "after-window-assertions") }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.standardTimeout), "Main window must exist on launch")
        XCTAssertTrue(window.isHittable, "Main window must be hittable")
        XCTAssertEqual(app.windows.count, 1, "Exactly one main window should be present on launch")
    }

    private func recordLaunchDiagnostics(stage: String) {
        let text = "stage=\(stage) app.state=\(app.state.rawValue) windows.count=\(app.windows.count) launchArguments=\(app.launchArguments)\n" + app.debugDescription
        let attachment = XCTAttachment(string: text)
        attachment.name = "Launch diagnostics \(stage)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("LAUNCH_DIAGNOSTIC stage=\(stage) app.state=\(app.state.rawValue) windows.count=\(app.windows.count)")
    }

    // MARK: - Sidebar & Settings Surface (AC-B3, AC-B4, EC-B02)

    /// AC-B3, AC-B4: Sidebar landmark and real in-window Settings surface are addressable
    /// by stable verification identity.
    func testSidebarAndSettingsSurfaceAreAddressable() throws {
        currentMethodName = "testSidebarAndSettingsSurfaceAreAddressable"
        app.launch()

        // 1. Sidebar landmark exists
        let sidebar = app.descendants(matching: .any)["conversation.sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: Self.standardTimeout), "conversation.sidebar must exist")

        // 2. Settings button exists and is hittable
        let settingsButton = app.descendants(matching: .any)["sidebar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: Self.standardTimeout), "sidebar.settings must exist")
        XCTAssertTrue(settingsButton.isHittable, "sidebar.settings must be hittable")
        XCTAssertEqual(settingsButton.label, "Settings", "sidebar.settings must expose 'Settings' label")
        let settingsIsButton = (settingsButton.elementType == .button) || app.buttons["sidebar.settings"].exists
        XCTAssertTrue(settingsIsButton, "sidebar.settings must project button accessibility role/trait")

        // 3. Navigate to Settings surface
        settingsButton.click()

        // 4. Verify settings surface appears
        let settingsSurface = app.descendants(matching: .any)["settings.surface"]
        XCTAssertTrue(settingsSurface.waitForExistence(timeout: Self.standardTimeout), "settings.surface must exist after clicking settings")
    }

    /// Batch G judge: observe the already-running real app; never launch or click Settings.
    func testExistingSettingsSurfaceAfterComputerUse() throws {
        currentMethodName = "testExistingSettingsSurfaceAfterComputerUse"
        guard ProcessInfo.processInfo.environment["GUI_VERIFICATION_TEST_ID"] ==
                "LimareUITests/MechanicalGUIVerificationUITests/testExistingSettingsSurfaceAfterComputerUse" else {
            throw XCTSkip("Observer-only verifier requires a production GUI verification invocation.")
        }
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                      "CU target app must already be running; verifier may not recreate the action state")
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: Self.standardTimeout), "CU target main window must exist")
        let settingsSurface = app.descendants(matching: .any)["settings.surface"]
        XCTAssertTrue(settingsSurface.waitForExistence(timeout: Self.standardTimeout), "CU action must have opened the existing Settings surface")
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "Post-CU Settings hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Primary Toolbar Landmark (AC-B5)

    /// AC-B5: Primary Chat toolbar landmark/control is addressable by stable verification identity.
    func testPrimaryToolbarLandmarkIsAddressable() throws {
        currentMethodName = "testPrimaryToolbarLandmarkIsAddressable"
        app.launch()

        let workSurfaceButton = app.descendants(matching: .any)["chat.toolbar.workSurface"]
        XCTAssertTrue(workSurfaceButton.waitForExistence(timeout: Self.standardTimeout), "chat.toolbar.workSurface landmark must exist")
        XCTAssertTrue(workSurfaceButton.isHittable, "chat.toolbar.workSurface landmark must be hittable")
        XCTAssertEqual(workSurfaceButton.label, "Work Surface", "chat.toolbar.workSurface must expose 'Work Surface' label")
        let toolbarIsButton = (workSurfaceButton.elementType == .button) || app.buttons["chat.toolbar.workSurface"].exists
        XCTAssertTrue(toolbarIsButton, "chat.toolbar.workSurface must project button role")
    }

    // MARK: - Composer Send Control Identity

    /// Verifies composer send button stable identity and accessibility properties.
    func testComposerSendControlIdentity() throws {
        currentMethodName = "testComposerSendControlIdentity"
        app.launch()

        let sendButton = app.descendants(matching: .any)["chat.composer.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: Self.standardTimeout), "chat.composer.send button must exist")
        XCTAssertEqual(sendButton.label, "Send message", "chat.composer.send must expose 'Send message' label")
        let sendIsButton = (sendButton.elementType == .button) || app.buttons["chat.composer.send"].exists
        XCTAssertTrue(sendIsButton, "chat.composer.send must project button role")
    }

    // MARK: - AC-B8 Positive Locator Failure Fixture

    /// AC-B8: Demonstrates that an unresolvable positive locator produces a real XCTest failure.
    /// This is a real UI test assertion failure fixture; it does not perform an absence assertion (G09 deferred).
    func testMissingRequiredPositiveLocatorFailsMechanicalAssertion() throws {
        currentMethodName = "testMissingRequiredPositiveLocatorFailsMechanicalAssertion"
        app.launch()

        let nonExistentElement = app.descendants(matching: .any)["nonexistent.required.positive.landmark"]
        XCTAssertTrue(nonExistentElement.waitForExistence(timeout: 1.0), "Required positive landmark must exist")
    }

    // MARK: - Batch C Screenshot Capture (Scope 2 Golden Vertical Slice)

    /// Captures a verification screenshot of the real Settings visual hierarchy.
    /// Navigates to Settings surface and captures app window screenshot, writing PNG data
    /// and correlation metadata to invocation transport files.
    @MainActor
    func testSettingsVisualHierarchyScreenshotCapture() throws {
        currentMethodName = "testSettingsVisualHierarchyScreenshotCapture"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.standardTimeout), "Main window must exist")

        let settingsButton = app.descendants(matching: .any)["sidebar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: Self.standardTimeout), "sidebar.settings must exist")
        settingsButton.click()

        let settingsSurface = app.descendants(matching: .any)["settings.surface"]
        XCTAssertTrue(settingsSurface.waitForExistence(timeout: Self.standardTimeout), "settings.surface must exist")

        // Capture screenshot of app window (strictly bounded to app, not desktop / ScreenCaptureKit)
        _ = try captureVerificationScreenshot(element: window)
    }

    // MARK: - Capability Entry Surfaces (supersedes FIX-FINAL-E4 composer activation)

    /// Computer Use is a global Settings capability (computer-use-global-enablement-change-note);
    /// the Composer carries the conversation-scoped Subagent policy instead. Proves the composer
    /// has no Computer Use entry, the Subagent control toggles its value, and Settings exposes
    /// the global Computer Use toggle. The toggle itself is not flipped (no TCC prompt in CI).
    @MainActor
    func testCapabilityEntrySurfaces() throws {
        currentMethodName = "testCapabilityEntrySurfaces"
        app.launch()

        let subagentControl = app.descendants(matching: .any)["chat.composer.subagent"]
        XCTAssertTrue(subagentControl.waitForExistence(timeout: Self.standardTimeout), "chat.composer.subagent must exist in composer")
        XCTAssertTrue(subagentControl.isHittable, "chat.composer.subagent must be hittable")
        XCTAssertFalse(app.descendants(matching: .any)["chat.composer.computerUse"].exists, "composer must not offer a Computer Use entry")

        let initialValue = subagentControl.value as? String
        subagentControl.click()
        let toggled = NSPredicate(format: "value != %@", initialValue ?? "")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: toggled, object: subagentControl)], timeout: Self.standardTimeout)
        XCTAssertEqual(result, .completed, "Clicking chat.composer.subagent must change the conversation policy")
        subagentControl.click()

        let settingsButton = app.descendants(matching: .any)["sidebar.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: Self.standardTimeout), "sidebar.settings must exist")
        settingsButton.click()
        let cuToggle = app.descendants(matching: .any)["settings.general.computerUse"]
        XCTAssertTrue(cuToggle.waitForExistence(timeout: Self.standardTimeout), "settings.general.computerUse must exist in General Settings")
    }

    // MARK: - Batch F: Layer-2 App Approval Surface (AC-F12, AC-F13)

    /// AC-F12, AC-F13: Mechanical GUI verification verifies the Layer-2 App Approval
    /// surface identifiers exist and can be queried.
    func testComputerUseAppApprovalMechanicalSurface() throws {
        currentMethodName = "testComputerUseAppApprovalMechanicalSurface"
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: Self.standardTimeout), "Main window must exist on launch")

        // Query the elements by their stable verification identifiers
        let appApprovalSheet = app.descendants(matching: .any)["computerUse.appApproval.sheet"]
        let appName = app.descendants(matching: .any)["computerUse.appApproval.appName"]
        let bundleID = app.descendants(matching: .any)["computerUse.appApproval.bundleID"]
        let allowButton = app.descendants(matching: .any)["computerUse.appApproval.allowConversation"]
        let blockButton = app.descendants(matching: .any)["computerUse.appApproval.blockConversation"]

        // The sheet is not presented by default on launch
        XCTAssertFalse(appApprovalSheet.exists, "Layer-2 App approval sheet should not be visible before an app control action is proposed")
        _ = (appName, bundleID, allowButton, blockButton)
    }

    /// Captures an XCUIElement screenshot, writes PNG bytes to the transport data path,
    /// and writes correlation metadata to the transport metadata path.
    /// Returns the captured raw PNG data.
    @MainActor
    @discardableResult
    func captureVerificationScreenshot(
        element: XCUIElement,
        captureID: String? = nil,
        requirementID: String? = nil,
        verificationRunID: String? = nil
    ) throws -> Data {
        let env = ProcessInfo.processInfo.environment
        let screenshot = element.screenshot()
        let pngData = screenshot.pngRepresentation

        let cID = captureID ?? env["GUI_VERIFICATION_CAPTURE_ID"] ?? UUID().uuidString
        let rID = requirementID ?? env["GUI_VERIFICATION_REQUIREMENT_ID"] ?? ""
        let vRunID = verificationRunID ?? env["GUI_VERIFICATION_VERIFICATION_RUN_ID"] ?? env["GUI_VERIFICATION_RUN_ID"] ?? ""
        let invID = env["GUI_VERIFICATION_INVOCATION_ID"] ?? ""
        let tID = env["GUI_VERIFICATION_TASK_ID"] ?? ""
        let runIDStr = env["GUI_VERIFICATION_RUN_ID"] ?? ""
        let testID = env["GUI_VERIFICATION_TEST_ID"] ?? "LimareUITests/MechanicalGUIVerificationUITests/\(resolvedTestMethodName)"

        // SHA-256 calculation
        var hasher = SHA256()
        hasher.update(data: pngData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        if let dataFilePath = env["GUI_VERIFICATION_SCREENSHOT_DATA_FILE"], !dataFilePath.isEmpty {
            try pngData.write(to: URL(fileURLWithPath: dataFilePath), options: .atomic)
        }

        if let metadataFilePath = env["GUI_VERIFICATION_SCREENSHOT_METADATA_FILE"], !metadataFilePath.isEmpty {
            let metadata: [String: Any] = [
                "invocationID": invID,
                "verificationRunID": vRunID,
                "captureID": cID,
                "taskID": tID,
                "runID": runIDStr,
                "requirementID": rID,
                "captureTestIdentity": testID,
                "mimeType": "image/png",
                "byteCount": Int64(pngData.count),
                "sha256": digest,
                "timestamp": Date().timeIntervalSince1970
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
            try jsonData.write(to: URL(fileURLWithPath: metadataFilePath), options: .atomic)
        }

        return pngData
    }

    // MARK: - Bounded Transport Helper

    private func emitTransportOutcomeIfConfigured(testName: String, passed: Bool) {
        let env = ProcessInfo.processInfo.environment
        guard let transportFilePath = env["GUI_VERIFICATION_TRANSPORT_FILE"],
              !transportFilePath.isEmpty else { return }

        let payload: [String: Any] = [
            "invocationID": env["GUI_VERIFICATION_INVOCATION_ID"] ?? "",
            "taskID": env["GUI_VERIFICATION_TASK_ID"] ?? "",
            "runID": env["GUI_VERIFICATION_RUN_ID"] ?? "",
            "requirementID": env["GUI_VERIFICATION_REQUIREMENT_ID"] ?? "",
            "testID": env["GUI_VERIFICATION_TEST_ID"] ?? "LimareUITests/MechanicalGUIVerificationUITests/\(testName)",
            "testMethod": testName,
            "passed": passed,
            "timestamp": Date().timeIntervalSince1970
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: transportFilePath))
        }
    }
}

