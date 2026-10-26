import SwiftUI
import Combine
import Sparkle

/// The first release only checks for updates in response to the application menu.
/// Development builds never start the updater (see LimareBuild).
/// Keep this app-only integration out of standalone source-based test runners.
@MainActor
final class ManualUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController!
    private var availability: AnyCancellable?

    override init() {
        super.init()
        // XCTest hosts must not mutate the user's update preferences or start an updater.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard LimareBuild.current.takesPublicUpdates else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // Enforce the release policy even if old preferences enabled automatic behavior.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        availability = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updates else {
            throw NSError(domain: "app.limare.Limare.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Updates are checked only from the Limare application menu."])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    private var hasHandledAppLaunch = false
    private let terminationCoordinator = HookTerminationCoordinator()

    @MainActor
    func handleAppLaunch(with state: AppState) {
        guard !hasHandledAppLaunch else { return }
        hasHandledAppLaunch = true
        self.appState = state
        state.remoteAccess.start()
        state.backgroundNotifier.start(appState: state)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let saved = UserDefaults.standard.string(forKey: AppearancePreference.storageKey)
            .flatMap(AppearancePreference.init(rawValue:)) ?? .system
        saved.apply()
        LoginShellEnvironment.prefetch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else {
            return .terminateNow
        }

        Task { @MainActor in
            // App-level cleanup: Remote Access ALWAYS stops, independent of conversation state
            await appState.remoteAccess.stop()

            // Conversation-level cleanup: only if an active conversation exists
            if let activeID = appState.conversations.activeConversationID {
                let effectiveURL = appState.conversations.effectiveWorkingDirectory(for: activeID)
                await self.terminationCoordinator.terminateSession(
                    coordinator: appState.hookCoordinator,
                    conversationID: activeID,
                    workspaceURL: effectiveURL,
                    timeoutSeconds: 3.0
                )
            }

            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LimareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @StateObject private var updates = ManualUpdateController()

    init() {
        // A write to a pipe or socket whose reader is gone must fail with EPIPE, not kill
        // Limare, as Node and Rust programs (Claude Code, Codex) behave. A hook that exited
        // before reading a 62 KB tool payload from stdin terminated the app on 2026-10-22.
        signal(SIGPIPE, SIG_IGN)
        if let isolatedRoot = TestStorageBootstrap.resolveStorageRoot() {
            _appState = State(initialValue: AppState(storageRootURL: isolatedRoot))
        } else {
            _appState = State(initialValue: AppState())
        }
    }

    var body: some Scene {
        WindowGroup(id: WindowSession.sceneID) {
            WindowRootView()
                .environment(appState)
                .onAppear {
                    appDelegate.handleAppLaunch(with: appState)
                    appearance.apply()
                }
                .onChange(of: appearance) { _, newAppearance in
                    newAppearance.apply()
                }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                if LimareBuild.current.takesPublicUpdates {
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.focusedWindow.screen = .settingsGeneral
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            WindowCommands(appState: appState)
            CommandMenu("Conversation") {
                Button("Focus Composer") {
                    appState.focusedWindow.screen = .chat
                    appState.focusedWindow.composerFocusRequest += 1
                }
                .keyboardShortcut("l", modifiers: .command)
                Button(appState.focusedWindow.workSurface.isPresented ? "Hide Work Surface" : "Show Work Surface") {
                    appState.focusedWindow.workSurface.togglePresented()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Run Details…") {
                    appState.focusedWindow.screen = .chat
                    appState.focusedWindow.showsRunDetails = true
                }
                .disabled(appState.focusedWindow.conversationID.flatMap { appState.conversationRuns.run(for: $0) } == nil)
            }
        }
    }
}

/// File menu: ⌘N starts a conversation in the focused window; ⌥⌘N opens another window on
/// the same conversation, as Mail's New Viewer Window does.
private struct WindowCommands: Commands {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Conversation") {
                appState.focusedWindow.screen = .chat
                appState.newConversation(in: appState.focusedWindow)
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("New Window") {
                openWindow(id: WindowSession.sceneID)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}

// MARK: - Presentation UI Appearance Mapping

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
