import AppKit
import Observation

@MainActor
@Observable
final class AppState {
    /// The window the app opened with, also standing in while no window is open (tests, launch).
    /// Its stores are the ones `chat`, `workSurface` and `files` name outside a window.
    let primaryWindow: WindowSession
    /// Open windows, in the order they opened.
    private(set) var windows: [WindowSession] = []
    private(set) var focusedWindowID: UUID?
    /// The conversation the next window opens on, instead of the focused window's.
    @ObservationIgnored var pendingWindowConversationID: UUID?
    /// The window each pending request's sheet opened in.
    @ObservationIgnored private var sheetHosts: [String: UUID] = [:]

    /// The window menu commands and app-level actions act on: the key window, else the last opened.
    var focusedWindow: WindowSession {
        windows.first { $0.id == focusedWindowID } ?? windows.last ?? primaryWindow
    }

    var screen: AppScreen {
        get { focusedWindow.screen }
        set { focusedWindow.screen = newValue }
    }
    /// Presentation intent: bumped by the Focus Composer command.
    var composerFocusRequest: Int {
        get { focusedWindow.composerFocusRequest }
        set { focusedWindow.composerFocusRequest = newValue }
    }
    let logs: DebugLogStore
    let runtimeEvents: RuntimeEventStore
    let providers: ProviderStore
    let workspace: WorkspaceStore
    let permissions: PermissionStore
    let userQuestions: UserQuestionStore
    let backgroundNotifier = BackgroundActivityNotifier()
    let skills: SkillStore
    let mcp: MCPStore
    let memory: MemoryStore
    let soul: SoulStore
    let modelGroups: ModelGroupStore
    let persistence: ConversationPersistence
    let conversations: ConversationStore
    let toolExecutor: ToolExecutor
    let conversationRuns: ConversationRunCoordinator
    let recoveryStore: RuntimeRecoveryStore
    let attachments: AttachmentStore
    /// Files tools registered or produced for a conversation; nil when its storage failed to open.
    let artifacts: ArtifactStore?
    let chat: ChatStore
    let draftArchive: DraftArchiveStore
    let undo: UndoCoordinator
    let browser: BrowserSessionStore
    var workSurface: WorkSurfaceStore { focusedWindow.workSurface }
    var files: FilesSurfaceStore { focusedWindow.files }
    let hooks: HookStore
    let hookCoordinator: HookSessionCoordinator
    let subagents: SubagentCoordinator
    let scheduled: ScheduledScheduler
    let voiceInput: VoiceInputStore
    let voiceOutput: VoiceOutputStore
    let runtimeModelRegistry: RuntimeModelRegistry
    let typography: TypographyPreferences
    let remoteAccess: RemoteAccessCoordinator
    let screenRecordingPermission: ScreenRecordingPermissionAuthorizing
    let accessibilityPermission: AccessibilityPermissionAuthorizing
    let computerUseActivation: ComputerUseActivationStore
    let computerUseAppAuthorization: ComputerUseAppAuthorizationStore

    init(
        client inputClient: OpenAICompatibleClient = OpenAICompatibleClient(),
        storageRootURL: URL? = nil,
        screenRecordingPermission: ScreenRecordingPermissionAuthorizing = MacScreenRecordingPermissionAuthorizer(),
        accessibilityPermission: AccessibilityPermissionAuthorizing = MacAccessibilityPermissionAuthorizer()
    ) {
        let logs = DebugLogStore(storageRootURL: storageRootURL)
        let runtimeEvents = RuntimeEventStore(storageRootURL: storageRootURL)
        let recoveryStore = RuntimeRecoveryStore(storageRootURL: storageRootURL, logs: logs)
        let providers = ProviderStore(storageRootURL: storageRootURL, client: inputClient, logs: logs)
        let client = providers.networkClient
        let workspace = WorkspaceStore(storageRootURL: storageRootURL, logs: logs)
        let permissions = PermissionStore(logs: logs)
        let userQuestions = UserQuestionStore(logs: logs, runtimeEvents: runtimeEvents)
        let computerUseActivation = ComputerUseActivationStore(
            authorizer: screenRecordingPermission,
            accessibilityAuthorizer: accessibilityPermission,
            logs: logs,
            preferenceFileURL: (storageRootURL ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true))
                .appendingPathComponent(ComputerUseActivationStore.preferenceFileName)
        )
        let computerUseAppAuthorization = ComputerUseAppAuthorizationStore(logs: logs)
        permissions.onModeChanged = { [weak computerUseActivation, weak computerUseAppAuthorization] newMode in
            computerUseActivation?.onPermissionModeChanged(newMode: newMode)
            computerUseAppAuthorization?.onPermissionModeChanged(newMode: newMode)
        }
        let hookTrustStore = HookTrustStore(storageDirectory: storageRootURL)
        let hooks = HookStore(trustStore: hookTrustStore, logs: logs, storageDirectory: storageRootURL)
        let hookCoordinator = HookSessionCoordinator(hookStore: hooks, workspace: workspace, logs: logs)
        let autoReviewer = AutoPermissionReviewer(
            client: client,
            providerResolver: { [weak providers] in
                guard let p = providers?.selectedProvider,
                      let apiKey = try? providers?.apiKey(providerID: p.id),
                      let m = p.selectedModelID.isEmpty ? p.models.first?.id : p.selectedModelID else {
                    return nil
                }
                return (provider: p, apiKey: apiKey, modelID: m)
            },
            logs: logs
        )
        permissions.setAutoReviewer(autoReviewer)
        let skills = SkillStore(logs: logs, workspaceURL: workspace.url)
        let mcp = MCPStore(logs: logs, storageRootURL: storageRootURL, workspaceURLProvider: { [weak workspace] in workspace?.url })
        let memory = MemoryStore(
            storageRootURL: storageRootURL?.appendingPathComponent(
                "memory",
                isDirectory: true
            ),
            logs: logs
        )
        let soul = SoulStore(storageRootURL: memory.rootURL, logs: logs)
        let modelGroups = ModelGroupStore(storageRootURL: storageRootURL, logs: logs)
        let persistence = ConversationPersistence(storageRootURL: storageRootURL, logs: logs)
        let contextLifecycle = ContextLifecycle(
            store: ContextLifecycleStore(storageRootURL: storageRootURL, logs: logs),
            logs: logs
        )
        let attachments = AttachmentStore(storageRootURL: storageRootURL)
        // Single production construction point for built-in converters and for
        // the immutable `resource_convert` consumer-policy composition. The same
        // immutable values are handed to every consumer; no consumer builds its
        // own converter or policy topology.
        let representationResolver = RepresentationResolver(
            converters: [ChatImageNormalizationConverter(), PDFTextExtractionConverter(), VideoMetadataConverter(), VideoFrameSheetConverter()]
        )
        let resourceConversionPolicies = ResourceConversionConsumerPolicies.builtIn
        let artifactStore: ArtifactStore?
        do {
            artifactStore = try ArtifactStore(storageRootURL: storageRootURL)
        } catch {
            logs.error("AppState", "Authoritative ArtifactStore initialization failed: \(error.localizedDescription)")
            artifactStore = nil
        }
        let browser = BrowserSessionStore(attachmentStore: attachments, artifactStore: artifactStore, logs: logs)
        let runtimeModelRegistry = RuntimeModelRegistry(modelGroups: modelGroups, providers: providers)
        let runtimeModelUseService = RuntimeModelUseService(
            registry: runtimeModelRegistry,
            providers: providers,
            logs: logs
        )
        let runtimeImageGenerationService = RuntimeImageGenerationService(
            registry: runtimeModelRegistry,
            providers: providers,
            attachmentStore: attachments,
            artifactStore: artifactStore,
            logs: logs
        )
        // The draft archive loads before conversations: pruning empty conversations at load
        // must already know which ones still hold archived drafts.
        let draftArchive = DraftArchiveStore(rootURL: persistence.rootURL, logs: logs)
        for draft in draftArchive.draftsByConversation.values.joined() {
            for attachment in draft.attachments { attachments.registerAttachment(attachment) }
        }
        let conversations = ConversationStore(
            persistence: persistence,
            logs: logs,
            attachmentStore: attachments,
            defaultSubModelSource: { [weak modelGroups] in
                guard let groupID = modelGroups?.defaultSubGroupId,
                      modelGroups?.group(for: groupID) != nil else { return nil }
                return .group(groupID: groupID)
            },
            hasRetainedDrafts: { [weak draftArchive] id in draftArchive?.hasDrafts(for: id) == true }
        )

        let subModelResolver = SubModelResolver(modelGroups: modelGroups, providers: providers)

        self.logs = logs
        self.runtimeEvents = runtimeEvents
        self.recoveryStore = recoveryStore
        self.providers = providers
        self.workspace = workspace
        self.permissions = permissions
        self.userQuestions = userQuestions
        self.skills = skills
        self.mcp = mcp
        self.memory = memory
        self.soul = soul
        self.modelGroups = modelGroups
        self.runtimeModelRegistry = runtimeModelRegistry
        self.persistence = persistence
        self.conversations = conversations
        self.attachments = attachments
        self.artifacts = artifactStore
        self.browser = browser
        self.hooks = hooks
        self.hookCoordinator = hookCoordinator
        self.typography = TypographyPreferences.shared
        self.screenRecordingPermission = screenRecordingPermission
        self.accessibilityPermission = accessibilityPermission
        self.computerUseActivation = computerUseActivation
        self.computerUseAppAuthorization = computerUseAppAuthorization

        conversations.defaultWorkspaceConfiguration = { [weak workspace] in
            workspace?.configuration
        }


        let toolExecutor = ToolExecutor(
            workspace: workspace,
            permissions: permissions,
            userQuestions: userQuestions,
            logs: logs,
            allowedReadDirectories: { [weak skills] in
                skills?.enabledSkillDirectories ?? []
            },
            memoryLocations: { [memory.globalFileURL, memory.dailyDirectoryURL] },
            mcpStore: mcp,
            attachmentStore: attachments,
            artifactStore: artifactStore,
            hookCoordinator: hookCoordinator,
            runtimeModelRegistry: runtimeModelRegistry,
            runtimeModelUseService: runtimeModelUseService,
            runtimeImageGenerationService: runtimeImageGenerationService,
            browserSessionStore: browser,
            representationResolver: representationResolver,
            resourceConversionPolicies: resourceConversionPolicies
        )
        // Stage 10: Legacy v0.1 runtime is quarantined; ToolExecutor connects exclusively to ComputerUseV2Engine.

        let cuaDriverBackend = CuaDriverBackend()
        let computerUseV2Engine = ComputerUseV2Engine(
            driver: cuaDriverBackend,
            activationStore: computerUseActivation,
            appAuthorizationStore: computerUseAppAuthorization,
            logs: logs,
            runtimeEvents: runtimeEvents
        )
        computerUseActivation.onDeactivated = { [weak computerUseActivation] in
            if let conversationID = computerUseActivation?.activeConversationID {
                let cutoff = Date()
                Task { await cuaDriverBackend.finishConversationSessions(conversationID: conversationID, createdBefore: cutoff) }
            }
        }
        toolExecutor.setComputerUseV2Engine(computerUseV2Engine)
        toolExecutor.setComputerUseRoute(.v2Production)
        if ProcessInfo.processInfo.environment["LIMARE_CU2_DOGFOOD"] == "1" {
            toolExecutor.setComputerUseRoute(.v2Dogfood)
        }
        skills.computerUseAvailabilityProvider = { [weak computerUseActivation, weak toolExecutor] in
            guard let toolExecutor else { return false }
            return toolExecutor.computerUseV2Engine != nil && (toolExecutor.computerUseRoute == .v2Production || toolExecutor.computerUseRoute == .v2Dogfood || computerUseActivation?.isActivated == true)
        }
        toolExecutor.setConversationContext(
            activeConversationID: { [weak conversations] in
                conversations?.activeConversationID
            },
            modelSources: { [weak conversations] in
                (sub: conversations?.activeConversation?.subModelSource, primary: conversations?.activeConversation?.modelSource)
            }
        )
        self.toolExecutor = toolExecutor

        let titleGenerator = ConversationTitleGenerator(
            resolver: subModelResolver,
            providers: providers,
            logs: logs
        )
        let chat = ChatStore(
            providers: providers,
            workspace: workspace,
            toolExecutor: toolExecutor,
            client: client,
            logs: logs,
            skills: skills,
            mcp: mcp,
            memory: memory,
            soul: soul,
            modelGroups: modelGroups,
            attachmentStore: attachments,
            representationResolver: representationResolver,
            titleGenerator: titleGenerator,
            runtimeModelRegistry: runtimeModelRegistry,
            browserSessionStore: browser,
            hookCoordinator: hookCoordinator,
            recoveryStore: recoveryStore,
            contextLifecycle: contextLifecycle,
            runtimeEvents: runtimeEvents
        )
        chat.setConversationStore(conversations)
        chat.setDraftArchive(draftArchive)
        let undoJournal = UndoJournalStore(storageRootURL: persistence.rootURL, logs: logs)
        let undo = UndoCoordinator(journal: undoJournal, conversationStore: conversations, logs: logs)
        chat.setUndoCoordinator(undo)
        chat.runCoordinator.undoJournal = undoJournal
        // An open restore plan holds new runs: its banner stays
        // available too, so the conversation is never locked without an exit.
        chat.runCoordinator.admissionHolds.append { [weak undo] conversationID in
            undo?.admissionHoldReason(conversationID: conversationID)
        }
        self.undo = undo
        undo.onHoldCleared = { [weak coordinator = chat.runCoordinator] id in coordinator?.startQueuedAfterHold(conversationID: id) }
        self.draftArchive = draftArchive
        self.chat = chat
        self.primaryWindow = WindowSession(chat: chat)
        self.conversationRuns = chat.runCoordinator
        browser.hasActiveRun = { [weak coordinator = chat.runCoordinator] conversationID in coordinator?.isActive(conversationID: conversationID) == true }
        conversations.onConversationDeleted = { [weak browser, weak chat, weak undoJournal, weak runtimeEvents, weak computerUseAppAuthorization] conversationID in
            browser?.releaseSession(ownedBy: conversationID)
            computerUseAppAuthorization?.forget(conversationID: conversationID)
            runtimeEvents?.removeEvents(conversationID: conversationID)
            chat?.discardArchivedDrafts(conversationID: conversationID)
            chat?.runCoordinator.forgetContextUsage(conversationID: conversationID)
            undoJournal?.removeAll(conversationID: conversationID)
        }
        chat.runCoordinator.computerUseActivation = computerUseActivation
        chat.runCoordinator.computerUseAppAuthorization = computerUseAppAuthorization
        chat.runCoordinator.permissions = permissions

        // Native migration: formal delegate_task never falls back to legacy, even when
        // the Native backend below cannot be constructed.
        let subagents = SubagentCoordinator(store: SubagentStore(storageRootURL: storageRootURL, logs: logs),
            conversations: conversations, runs: chat.runCoordinator, logs: logs)
        self.subagents = subagents
        toolExecutor.setSubagentCoordinator(subagents)
        chat.runCoordinator.subagents = subagents
        conversations.onDelegationRelationshipDeletion = { [weak subagents] id in subagents?.conversationDeleted(id) }

        // Startup Reconciliation
        chat.runCoordinator.reconcileInterruptedRuns()
        for plan in undo.reconcileStartup() {
            chat.commitPendingUndoRetraction(plan)
        }
        subagents.reconcileRestart()

        // Scheduled tasks: the ledger reconciles and the run observer registers before the first
        // tick. Every human wait asks the coordinator whether its run is unattended.
        let scheduled = ScheduledScheduler(
            store: ScheduledStateStore(storageRootURL: storageRootURL, logs: logs),
            interaction: chat.interaction,
            runs: chat.runCoordinator,
            conversations: conversations,
            runtimeEvents: runtimeEvents,
            logs: logs
        )
        self.scheduled = scheduled
        toolExecutor.setScheduler(scheduled)
        permissions.isUnattendedRun = { [weak coordinator = chat.runCoordinator] runID in
            coordinator?.isUnattended(runID: runID) == true
        }
        userQuestions.isUnattendedRun = { [weak coordinator = chat.runCoordinator] runID in
            coordinator?.isUnattended(runID: runID) == true
        }
        mcp.isUnattendedRun = { [weak coordinator = chat.runCoordinator] runID in
            coordinator?.isUnattended(runID: runID) == true
        }
        computerUseAppAuthorization.isUnattendedConversation = { [weak coordinator = chat.runCoordinator] conversationID in
            guard let coordinator, let run = coordinator.run(for: conversationID), !run.status.isTerminal else { return false }
            return coordinator.isUnattended(runID: run.id)
        }
        // Only the Limare app ticks; test runners drive `tick(now:)` themselves.
        scheduled.start(startTimer: LimareStorage.isLimareApp)

        let voiceInputResolver = VoiceInputResolver(
            modelGroups: modelGroups,
            providers: providers,
            logs: logs
        )
        let voiceInput = VoiceInputStore(
            resolver: voiceInputResolver,
            chatStore: chat,
            logs: logs
        )
        self.voiceInput = voiceInput

        let voiceOutputResolver = VoiceOutputResolver(
            modelGroups: modelGroups,
            providers: providers,
            logs: logs
        )
        let voiceOutput = VoiceOutputStore(
            resolver: voiceOutputResolver,
            logs: logs
        )
        self.voiceOutput = voiceOutput
        let remoteHub = RemoteSessionHub(
            conversations: conversations,
            runs: chat.runCoordinator,
            interaction: chat.interaction,
            permissions: permissions,
            appAuthorization: computerUseAppAuthorization,
            userQuestions: userQuestions,
            runtimeEvents: runtimeEvents,
            providers: providers,
            modelGroups: modelGroups,
            attachments: attachments,
            artifacts: artifacts,
            importUpload: { [chat] url, conversationID in try await chat.importRemoteUpload(at: url, conversationID: conversationID) },
            logs: logs
        )
        self.remoteAccess = RemoteAccessCoordinator(
            hub: remoteHub,
            tunnel: CloudflareTunnelSupervisor(
                executableURL: CloudflareTunnelSupervisor.bundledExecutableURL,
                stateDirectory: (storageRootURL ?? LimareStorage.defaultRoot).appendingPathComponent("remote", isDirectory: true),
                logDirectory: logs.logDirectoryURL,
                logs: logs
            ),
            secrets: RemoteAccessSecrets(storageRootURL: storageRootURL ?? LimareStorage.defaultRoot),
            logs: logs,
            // Only the real app serves: never test runs or isolated storage roots.
            mayServe: storageRootURL == nil && LimareStorage.isLimareApp
        )

        primaryWindow.app = self
        let forgetDeleted = conversations.onConversationDeleted
        conversations.onConversationDeleted = { [weak self] conversationID in
            self?.windowsLost(conversationID: conversationID)
            forgetDeleted?(conversationID)
        }
        computerUseActivation.conversationIsRunning = { [weak coordinator = chat.runCoordinator] id in
            coordinator?.isActive(conversationID: id) == true
        }
        computerUseActivation.conversationTitle = { [weak conversations] id in
            conversations?.conversations.first(where: { $0.id == id })?.title
        }

        // Selecting a conversation shows it in the focused window; other windows keep theirs.
        conversations.onSelectConversation = { [weak self] (conversation: ConversationRecord) in
            guard let self else { return }
            self.focusedWindow.show(conversation)
            self.skills.setWorkspaceURL(self.conversations.effectiveWorkingDirectory(for: conversation.id))

            // Selection is presentation state. A background run owns its Hook
            // session and must not be ended or rebound merely by viewing B.
        }

        conversations.isConversationInUse = { [weak self] id in
            guard let self else { return true }
            return (self.windows.isEmpty ? [self.primaryWindow] : self.windows).contains {
                $0.conversationID == id || $0.chat.holdsUnarchivedComposer(for: id)
            }
        }

        conversations.onWorkspaceChanged = { [weak self] in
            self?.syncEffectiveWorkspace()
        }

        workspace.onWorkspaceChange = { [weak self] _ in
            self?.syncEffectiveWorkspace()
        }

        syncEffectiveWorkspace()

        if let initial = conversations.activeConversation {
            chat.loadConversation(initial)
            let effectiveRoot = conversations.effectiveWorkingDirectory(for: initial.id)
            Task {
                _ = await hookCoordinator.onSessionStart(conversationID: initial.id, source: "resume", workspaceURL: effectiveRoot)
            }
        } else if let activeID = conversations.activeConversationID {
            let effectiveRoot = conversations.effectiveWorkingDirectory(for: activeID)
            Task {
                _ = await hookCoordinator.onSessionStart(conversationID: activeID, source: "startup", workspaceURL: effectiveRoot)
            }
        }

        Task {
            await mcp.refreshAll()
        }
    }

    // MARK: - Windows

    /// A window opened: it gets the primary window's stores if no window holds them, else its
    /// own, and shows the requested conversation or the focused window's.
    /// Starts a conversation for the sidebar's New Conversation and ⌘N: in the project of the
    /// conversation the window shows, as working in a project carries on there; outside any
    /// project, under Conversations.
    func newConversation(in window: WindowSession) {
        let projectID = window.conversation?.projectID.flatMap { id in
            conversations.projects.contains { $0.id == id } ? id : nil
        }
        conversations.newConversation(projectID: projectID)
    }

    func openWindowSession() -> WindowSession {
        let session: WindowSession
        if windows.contains(where: { $0 === primaryWindow }) {
            session = WindowSession(chat: chat.makeWindowCompanion())
            session.app = self
        } else {
            session = primaryWindow
            session.chat.bindToWindow()
        }
        let conversationID = pendingWindowConversationID ?? focusedWindow.conversationID ?? conversations.activeConversationID
        pendingWindowConversationID = nil
        windows.append(session)
        if let record = conversationID.flatMap({ id in conversations.conversations.first(where: { $0.id == id }) }) {
            session.show(record)
        } else {
            windowContentChanged()
        }
        return session
    }

    /// The window became key: menu commands and app-wide selection now follow it.
    func windowBecameKey(_ session: WindowSession) {
        guard windows.contains(where: { $0 === session }) else { return }
        focusedWindowID = session.id
        if let id = session.conversationID, conversations.activeConversationID != id {
            conversations.activeConversationID = id
            skills.setWorkspaceURL(conversations.effectiveWorkingDirectory(for: id))
        }
    }

    func windowClosed(_ session: WindowSession) {
        guard let index = windows.firstIndex(where: { $0 === session }) else { return }
        windows.remove(at: index)
        session.chat.closeWindow(releasingRuns: session !== primaryWindow)
        if focusedWindowID == session.id {
            focusedWindowID = nil
        }
        windowContentChanged()
    }

    /// Makes `window` the one selection and menu commands act on, before a selection made in it:
    /// a context menu or a sheet can act in a window that is not key.
    func focus(_ window: WindowSession) {
        guard windows.contains(where: { $0 === window }) else { return }
        focusedWindowID = window.id
    }

    /// The sidebar opened or started a conversation: this window acts on conversations and
    /// shows the chat again if it was showing Schedules.
    func showChat(in window: WindowSession) {
        focus(window)
        if window.screen == .scheduled { window.screen = .chat }
    }

    /// Conversations whose run waits on the user's approval, Computer Use app control first.
    var conversationsAwaitingApproval: [UUID] {
        var ids: [UUID] = []
        for id in [computerUseAppAuthorization.pendingApproval?.conversationID, permissions.pendingApproval?.conversationID] {
            if let id, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Conversations whose run waits for the user's answer to a question card, oldest card first.
    var conversationsAwaitingAnswer: [UUID] {
        userQuestions.pending.values.sorted { $0.presentedAt < $1.presentedAt }.map(\.conversationID)
    }

    /// Brings a conversation in front of the user: the window already showing it, else the
    /// focused window, which switches to it. Settings give way to the chat.
    func reveal(conversationID: UUID?) {
        let window = conversationID.flatMap { id in windows.first { $0.conversationID == id } } ?? focusedWindow
        focus(window)
        window.screen = .chat
        if let conversationID, window.conversationID != conversationID {
            conversations.selectConversation(id: conversationID)
        }
        NSApp?.activate()
        window.hostWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens a conversation in a window of its own (the caller opens the window).
    func prepareWindow(for conversationID: UUID) {
        pendingWindowConversationID = conversationID
    }

    /// Recomputes what depends on the conversations windows show.
    func windowContentChanged() {
        let shown = windows.isEmpty ? [primaryWindow] : windows
        browser.displayedConversationIDs = Set(shown.compactMap(\.conversationID))
    }

    /// The window that presents the request `requestID` for `conversationID`: the focused window
    /// if it shows that conversation, else another window that does, else the focused window.
    /// Chosen once, so the sheet stays where it opened while focus moves; chosen again only if
    /// that window closes.
    func sheetWindowID(for requestID: String, conversationID: UUID?) -> UUID {
        if let host = sheetHosts[requestID], windows.contains(where: { $0.id == host }) {
            return host
        }
        let focused = focusedWindow
        var host = focused.id
        if let conversationID, focused.conversationID != conversationID,
           let showing = windows.first(where: { $0.conversationID == conversationID }) {
            host = showing.id
        }
        sheetHosts = sheetHosts.filter { $0.key == requestID }
        sheetHosts[requestID] = host
        return host
    }

    /// Windows that showed a deleted conversation move to the selected one.
    private func windowsLost(conversationID: UUID) {
        let fallback = conversations.activeConversation
            ?? conversations.conversations.first(where: { !$0.isArchived && !$0.isNativeDelegationChild })
        for window in windows where window.conversationID == conversationID {
            if let fallback { window.show(fallback) }
        }
    }

    // MARK: - Work Surface (focused window)

    func addSurface(_ kind: WorkSurfaceKind) { focusedWindow.addSurface(kind) }
    func previewWorkspaceFile(_ url: URL) { focusedWindow.previewWorkspaceFile(url) }
    func previewAttachment(_ attachment: ChatAttachment) { focusedWindow.previewAttachment(attachment) }
    func previewArtifact(id: UUID, conversationID: UUID) { focusedWindow.previewArtifact(id: id, conversationID: conversationID) }
    func workspaceSource(ofArtifact id: UUID, conversationID: UUID) -> URL? {
        focusedWindow.workspaceSource(ofArtifact: id, conversationID: conversationID)
    }
    func closeWorkSurfaceTab(id: UUID) { focusedWindow.closeWorkSurfaceTab(id: id) }
    func openTreeFile(_ url: URL, in store: FilesSurfaceStore) { focusedWindow.openTreeFile(url, in: store) }
    func filesStore(for tab: WorkSurfaceTab) -> FilesSurfaceStore? { focusedWindow.filesStore(for: tab) }
    func workSurfaceTitle(for tab: WorkSurfaceTab) -> String { focusedWindow.workSurfaceTitle(for: tab) }
    func workSurfaceSystemImage(for tab: WorkSurfaceTab) -> String { focusedWindow.workSurfaceSystemImage(for: tab) }

    /// Points each window's Files, and the skills, at the effective working directory of the
    /// conversation shown (for skills: the selected one).
    func syncEffectiveWorkspace() {
        for window in windows.isEmpty ? [primaryWindow] : windows {
            window.syncFilesRoot()
        }
        let effectiveRoot = conversations.activeConversationID.map { conversations.effectiveWorkingDirectory(for: $0) }
        skills.setWorkspaceURL(effectiveRoot ?? workspace.url)
    }
}
