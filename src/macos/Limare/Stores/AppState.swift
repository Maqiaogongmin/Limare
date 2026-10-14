import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var screen: AppScreen = .chat
    let logs: DebugLogStore
    let runtimeEvents: RuntimeEventStore
    let providers: ProviderStore
    let workspace: WorkspaceStore
    let permissions: PermissionStore
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
    let workSurface: WorkSurfaceStore
    let files: FilesSurfaceStore
    let hooks: HookStore
    let hookCoordinator: HookSessionCoordinator
    let subagents: SubagentCoordinator
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
        self.workSurface = WorkSurfaceStore()
        self.files = FilesSurfaceStore()
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
        self.conversationRuns = chat.runCoordinator
        browser.hasActiveRun = { [weak coordinator = chat.runCoordinator] conversationID in coordinator?.isActive(conversationID: conversationID) == true }
        conversations.onConversationDeleted = { [weak browser, weak chat, weak undoJournal, weak runtimeEvents, weak computerUseAppAuthorization] conversationID in
            browser?.releaseSession(ownedBy: conversationID)
            computerUseAppAuthorization?.forget(conversationID: conversationID)
            runtimeEvents?.removeEvents(conversationID: conversationID)
            chat?.discardArchivedDrafts(conversationID: conversationID)
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

        conversations.onSelectConversation = { [weak self] (conversation: ConversationRecord) in
            guard let self else { return }

            self.voiceInput.cancel()
            self.voiceOutput.stop()
            self.conversationRuns.resetForConversationBoundary()
            self.chat.loadConversation(conversation)
            self.syncEffectiveWorkspace()
            self.browser.displayedConversationID = conversation.id

            // Selection is presentation state. A background run owns its Hook
            // session and must not be ended or rebound merely by viewing B.
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

    /// Synchronizes the active conversation's effective working directory across FilesSurfaceStore and SkillStore.
    func addSurface(_ kind: WorkSurfaceKind) {
        if kind == .browser {
            if !workSurface.tabs.contains(where: { $0.kind == .browser }) {
                workSurface.openBrowser()
            } else {
                let key = UUID().uuidString
                let rt = BrowserRuntime(
                    websiteDataStore: browser.websiteDataStore,
                    attachmentStore: attachments,
                    artifactStore: artifacts,
                    logs: logs,
                    snapshotProvider: browser.snapshotProvider
                )
                let tab = BrowserTab(
                    conversationID: UUID(),
                    runtime: rt,
                    owner: .user
                )
                workSurface.additionalBrowsers[key] = tab
                workSurface.open(kind: .browser, contentID: key, title: "Browser")
            }
        } else {
            openFilesTree()
        }
    }

    /// Shows a Files tab with nothing previewed: one already open, else the navigator, else a new one.
    private func openFilesTree() {
        if let tab = workSurface.tabs.first(where: { $0.kind == .files && filesStore(for: $0)?.previewSource == nil }) {
            filesStore(for: tab)?.clearSelection()
            workSurface.focus(id: tab.id)
        } else if !workSurface.tabs.contains(where: { $0.matches(kind: .files, contentID: WorkSurfaceStore.filesNavigatorID) }) {
            workSurface.openFiles()
        } else {
            let key = UUID().uuidString
            workSurface.filePreviews[key] = FilesSurfaceStore(rootURL: files.rootURL)
            workSurface.open(kind: .files, contentID: key)
        }
    }

    // MARK: - File previews
    //
    // A Files tab shows the workspace tree and, once a file is chosen, that file's preview beside
    // it. A tab showing only the tree opens the first file chosen in place; from a tab that
    // already shows a file, the next one gets its own tab, so several files stay open at once.
    // The navigator is the Files tab backed by `files`; every other Files tab has its own store.
    // Opening a file a tab already shows focuses that tab.

    /// Previews a workspace file in its own tab.
    func previewWorkspaceFile(_ url: URL) {
        openPreviewTab { $0.selectFile(url: url) }
    }

    /// Previews a chat attachment in its own tab.
    func previewAttachment(_ attachment: ChatAttachment) {
        openPreviewTab { $0.selectAttachment(attachment: attachment, attachmentStore: attachments) }
    }

    /// Previews a conversation's artifact in its own tab.
    func previewArtifact(id: UUID, conversationID: UUID) {
        guard let artifacts else { return }
        if let source = workspaceSource(ofArtifact: id, conversationID: conversationID) {
            previewWorkspaceFile(source)
            return
        }
        openPreviewTab { $0.selectArtifact(id: id, conversationID: conversationID, artifactStore: artifacts) }
    }

    /// The workspace file an artifact was registered from, while it is still there. Such an
    /// artifact opens as that file, as a file link does in Codex: one tab with the tree's,
    /// showing the current content. The stored copy stands in once the file is gone.
    func workspaceSource(ofArtifact id: UUID, conversationID: UUID) -> URL? {
        guard let descriptor = try? artifacts?.resolveDescriptor(artifactID: id, conversationID: conversationID),
              descriptor.producerProvenance == .workspaceRegistration,
              let source = descriptor.workspaceProvenance,
              let root = files.rootURL,
              FileManager.default.fileExists(atPath: source.path),
              WorkspacePathResolver.isInsideWorkspace(source.standardizedFileURL.resolvingSymlinksInPath(), workspaceURL: root)
        else { return nil }
        return source
    }

    /// Closes a Work Surface tab. A Files tab forgets the file it showed, the navigator too,
    /// so Files opens on the tree next time.
    func closeWorkSurfaceTab(id: UUID) {
        if let tab = workSurface.tabs.first(where: { $0.id == id }) {
            filesStore(for: tab)?.clearSelection()
        }
        workSurface.close(id: id)
    }

    /// Opens `url`, chosen in the tree of the tab backed by `store`, the way every file click
    /// opens (`FileOpening`). A preview goes in that tab when it shows only the tree, otherwise
    /// in a tab of its own.
    func openTreeFile(_ url: URL, in store: FilesSurfaceStore) {
        FileOpening.open(url) {
            let source = FilePreviewSource.workspace(url.standardizedFileURL.resolvingSymlinksInPath())
            if let tab = filesTab(showing: source) {
                workSurface.focus(id: tab.id)
            } else if store.previewSource == nil {
                store.selectFile(url: url)
            } else {
                previewWorkspaceFile(url)
            }
        }
    }

    /// The store behind a Files tab.
    func filesStore(for tab: WorkSurfaceTab) -> FilesSurfaceStore? {
        guard tab.kind == .files else { return nil }
        return tab.contentID == WorkSurfaceStore.filesNavigatorID ? files : workSurface.filePreviews[tab.contentID]
    }

    /// A Files tab is named by the file it shows; a browser tab the user opened, by its page,
    /// as in a browser. The agent's own browser tab stays "Browser".
    func workSurfaceTitle(for tab: WorkSurfaceTab) -> String {
        switch tab.kind {
        case .files:
            return filesStore(for: tab)?.previewSource?.displayName ?? tab.kind.defaultTitle
        case .browser:
            let pageTitle = workSurface.additionalBrowsers[tab.contentID]?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return pageTitle.isEmpty ? tab.title : pageTitle
        }
    }

    func workSurfaceSystemImage(for tab: WorkSurfaceTab) -> String {
        guard tab.kind == .files, filesStore(for: tab)?.previewSource != nil else { return tab.systemImage }
        return "doc.text"
    }

    /// Lets `select` validate and load a file into a new store, then focuses a tab already
    /// showing that file or opens a tab for it. A file that fails validation opens nothing.
    private func openPreviewTab(_ select: (FilesSurfaceStore) -> Void) {
        let preview = FilesSurfaceStore(rootURL: files.rootURL)
        select(preview)
        guard let source = preview.previewSource else {
            logs.info("Files", "Nothing to preview: \(preview.previewState)")
            return
        }
        if let tab = filesTab(showing: source) {
            preview.clearSelection()
            workSurface.focus(id: tab.id)
            return
        }
        let key = UUID().uuidString
        workSurface.filePreviews[key] = preview
        workSurface.open(kind: .files, contentID: key, title: source.displayName)
    }

    private func filesTab(showing source: FilePreviewSource) -> WorkSurfaceTab? {
        workSurface.tabs.first { filesStore(for: $0)?.previewSource?.identity == source.identity }
    }

    func syncEffectiveWorkspace() {
        let effectiveRoot = conversations.activeConversationID.map { conversations.effectiveWorkingDirectory(for: $0) }
        // File tabs belong to a workspace: they close when it changes, and stay open when the
        // next conversation works in the same one.
        if effectiveRoot != files.rootURL {
            workSurface.clearFilePreviews()
        }
        files.setRootURL(effectiveRoot)
        skills.setWorkspaceURL(effectiveRoot ?? workspace.url)
    }
}
