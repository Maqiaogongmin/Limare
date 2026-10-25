import Foundation
import CryptoKit
import UniformTypeIdentifiers

enum ToolExecutorError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case workspaceRequired

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): "Tool '\(name)' is not recognized by Limare."
        case .invalidArguments(let reason): "Invalid arguments: \(reason)"
        case .workspaceRequired: "Choose a Project Folder or conversation before running tools."
        }
    }
}

enum AttachmentCopyError: LocalizedError, Equatable {
    case workspaceRequired
    case invalidSourceURI(String)
    case attachmentNotFound(String)
    case absoluteDestinationNotAllowed(String)
    case destinationOutsideWorkspace(String)
    case destinationAlreadyExists(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .workspaceRequired:
            return "Choose a Project Folder or start a conversation before copying attachments."
        case .invalidSourceURI(let uri):
            return "Invalid attachment source URI '\(uri)'. Must start with limare://attachments/."
        case .attachmentNotFound(let uri):
            return "Attachment file for '\(uri)' could not be found in local attachment storage."
        case .absoluteDestinationNotAllowed(let path):
            return "Absolute destination path '\(path)' is not allowed. Destination must be a relative path."
        case .destinationOutsideWorkspace(let path):
            return "Destination path '\(path)' escapes the working directory."
        case .destinationAlreadyExists(let path):
            return "Destination path '\(path)' already exists in working directory. Overwriting is not allowed."
        case .copyFailed(let reason):
            return "Failed to copy attachment: \(reason)"
        }
    }
}

@MainActor
final class ToolExecutor {
    /// Every name this executor runs; anything else is a name the model made up.
    nonisolated static let builtInToolNames: Set<String> = [
        "delegation_result", "shell_execute", "file_read", "file_list", "file_search", "file_write", "file_edit",
        "read_image", "model_use", "browser_use", "delegate_task", "delegation_control", "update_plan",
        "ask_user_question", "attachment_copy", "resource_convert", "artifact_acquire", "artifact_register", "tool_result_read", "computer_use",
        "mcp_manage", "schedule_manage"
    ]

    nonisolated static func recognizes(_ name: String) -> Bool {
        builtInToolNames.contains(name) || name == "tool_search" || MCPToolNamespace.parse(exposedName: name) != nil
    }

    typealias UpdateHandler = @MainActor (ToolExecutionUpdate) -> Void

    private struct HookExecutionScope {
        let conversationID: UUID
        let runID: UUID
        let conversationTitle: String?
    }

    /// Set when this executor runs a subagent's tools.
    private var subagentBinding: SubagentRunBinding?
    /// Journals project changes of this run's file tools for undo.
    private(set) var changeRecorder: UndoChangeRecorder?

    func setChangeRecorder(_ recorder: UndoChangeRecorder?) {
        changeRecorder = recorder
    }

    /// Runs a project write, journaled for undo when a recorder is installed.
    private func recordedWrite<T>(_ url: URL, call: ProviderToolCall, _ body: (AnchoredPath?) throws -> T) throws -> T {
        guard let changeRecorder else { return try body(nil) }
        return try changeRecorder.recording(path: url, source: call.function.name, toolCallID: call.id, workspaceRoot: workspace.url, body)
    }

    private weak var subagents: SubagentCoordinator?

    func setSubagent(_ binding: SubagentRunBinding, coordinator: SubagentCoordinator?) {
        subagentBinding = binding
        subagents = coordinator
    }

    func setSubagentCoordinator(_ coordinator: SubagentCoordinator) {
        subagents = coordinator
    }

    private weak var scheduler: ScheduledScheduler?

    func setScheduler(_ scheduler: ScheduledScheduler) {
        self.scheduler = scheduler
    }

    /// Scheduled tasks are managed from a conversation's own run, never from a subagent's.
    var supportsScheduling: Bool { subagentBinding == nil && scheduler != nil }

    private let workspace: WorkspaceStore
    private let permissions: PermissionStore
    /// The question cards `ask_user_question` waits on; nil leaves the tool without anyone to ask.
    let userQuestions: UserQuestionStore?
    private let logs: DebugLogStore
    private let shellRunner: ShellRunner
    private let files: FileToolService
    private let researchFiles: ResearchFileService
    private let memoryLocations: @MainActor () -> [URL]
    private let allowedReadDirectories: @MainActor () -> [URL]
    private let mcpStore: MCPStore?
    private var visionGroupResolver: VisionGroupResolver?
    private var hookCoordinator: HookSessionCoordinator?
    private var activeConversationIDProvider: (@MainActor () -> UUID?)?
    private var activeConversationModelSourcesProvider: (@MainActor () -> (sub: ConversationModelSource?, primary: ConversationModelSource?))?
    private let attachmentStore: AttachmentStore
    let artifactStore: ArtifactStore?
    private let runtimeModelRegistry: RuntimeModelRegistry?
    private let runtimeModelUseService: RuntimeModelUseService?
    private let runtimeImageGenerationService: RuntimeImageGenerationService?
    private let browserSessionStore: BrowserSessionStore
    /// Nil for legacy foreground callers. Conversation-run scoped executors set
    /// this so cancelling one run cannot tear down another queued browser action.
    private let browserActionConversationID: UUID?
    /// Immutable ownership for a background conversation run. Legacy callers
    /// intentionally leave this nil and retain the foreground compatibility API.
    private let hookExecutionScope: HookExecutionScope?
    private var canonicalMessageResolver: (@MainActor (UUID) -> [ChatMessage]?)?
    /// The single immutable production converter composition, injected from the
    /// composition root. Tools never build their own converter topology.
    private var representationResolver: RepresentationResolver?
    /// The single immutable `resource_convert` consumer-policy composition,
    /// injected from the same composition root. This tool never builds its own
    /// policy topology, and it knows no source or target format of its own.
    private var resourceConversionPolicies: ResourceConversionConsumerPolicies?
    var imageDataReader: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    private(set) var computerUseV2Engine: ComputerUseV2Engine?
    var computerUseRoute: ComputerUseExecutionRoute = .v2Production
    var runAuthorityResolver: (@Sendable () async -> Bool)?

    /// True only when the executor that will receive `delegate_task` has a subagent coordinator
    /// and is not itself a subagent's executor.
    var supportsDelegation: Bool { usesNativeDelegation }
    var usesNativeDelegation: Bool { subagentBinding == nil && subagents != nil }

    init(
        workspace: WorkspaceStore,
        permissions: PermissionStore,
        userQuestions: UserQuestionStore? = nil,
        logs: DebugLogStore,
        shellRunner: ShellRunner = ShellRunner(),
        files: FileToolService = FileToolService(),
        researchFiles: ResearchFileService = ResearchFileService(),
        allowedReadDirectories: @escaping @MainActor () -> [URL] = { [] },
        memoryLocations: @escaping @MainActor () -> [URL] = { [] },
        mcpStore: MCPStore? = nil,
        attachmentStore: AttachmentStore = AttachmentStore(),
        artifactStore: ArtifactStore? = nil,
        visionGroupResolver: VisionGroupResolver? = nil,
        hookCoordinator: HookSessionCoordinator? = nil,
        runtimeModelRegistry: RuntimeModelRegistry? = nil,
        runtimeModelUseService: RuntimeModelUseService? = nil,
        runtimeImageGenerationService: RuntimeImageGenerationService? = nil,
        browserSessionStore: BrowserSessionStore? = nil,
        browserActionConversationID: UUID? = nil,
        hookExecutionScope: (conversationID: UUID, runID: UUID, conversationTitle: String?)? = nil,
        canonicalMessageResolver: (@MainActor (UUID) -> [ChatMessage]?)? = nil,
        representationResolver: RepresentationResolver? = nil,
        resourceConversionPolicies: ResourceConversionConsumerPolicies? = nil,
        runAuthorityResolver: (@Sendable () async -> Bool)? = nil
    ) {
        self.workspace = workspace
        self.permissions = permissions
        self.userQuestions = userQuestions
        self.logs = logs
        self.shellRunner = shellRunner
        self.files = files
        self.researchFiles = researchFiles
        self.memoryLocations = memoryLocations
        self.allowedReadDirectories = allowedReadDirectories
        self.mcpStore = mcpStore
        self.attachmentStore = attachmentStore
        self.artifactStore = artifactStore
        self.visionGroupResolver = visionGroupResolver
        self.hookCoordinator = hookCoordinator
        self.runtimeModelRegistry = runtimeModelRegistry
        self.runtimeModelUseService = runtimeModelUseService
        self.runtimeImageGenerationService = runtimeImageGenerationService
        self.browserSessionStore = browserSessionStore ?? BrowserSessionStore(attachmentStore: attachmentStore, artifactStore: artifactStore, logs: logs)
        self.browserActionConversationID = browserActionConversationID
        self.hookExecutionScope = hookExecutionScope.map {
            HookExecutionScope(conversationID: $0.conversationID, runID: $0.runID, conversationTitle: $0.conversationTitle)
        }
        self.canonicalMessageResolver = canonicalMessageResolver
        self.representationResolver = representationResolver
        self.resourceConversionPolicies = resourceConversionPolicies
        self.runAuthorityResolver = runAuthorityResolver
    }

    func setComputerUseV2Engine(_ engine: ComputerUseV2Engine?) {
        self.computerUseV2Engine = engine
    }

    func setComputerUseRoute(_ route: ComputerUseExecutionRoute) {
        self.computerUseRoute = route
    }

    func setRunAuthorityResolver(_ resolver: (@Sendable () async -> Bool)?) {
        self.runAuthorityResolver = resolver
    }

    func setRepresentationResolver(_ resolver: RepresentationResolver) {
        self.representationResolver = resolver
    }

    func setResourceConversionPolicies(_ policies: ResourceConversionConsumerPolicies) {
        self.resourceConversionPolicies = policies
    }

    func setVisionGroupResolver(_ resolver: VisionGroupResolver) {
        self.visionGroupResolver = resolver
    }

    func setHookCoordinator(_ coordinator: HookSessionCoordinator) {
        self.hookCoordinator = coordinator
    }

    /// The conversation tools act for, and its model sources, for executors not scoped to a run.
    func setConversationContext(
        activeConversationID: @escaping @MainActor () -> UUID?,
        modelSources: @escaping @MainActor () -> (sub: ConversationModelSource?, primary: ConversationModelSource?)
    ) {
        self.activeConversationIDProvider = activeConversationID
        self.activeConversationModelSourcesProvider = modelSources
    }

    func scoped(
        for conversationID: UUID,
        runID: UUID,
        conversationTitle: String?,
        workspace: WorkspaceStore,
        modelSources: (sub: ConversationModelSource?, primary: ConversationModelSource?),
        allowedReadDirectories: [URL]? = nil
    ) -> ToolExecutor {
        let scoped = ToolExecutor(
            workspace: workspace,
            permissions: permissions,
            userQuestions: userQuestions,
            logs: logs,
            shellRunner: shellRunner,
            files: files,
            researchFiles: researchFiles,
            allowedReadDirectories: { allowedReadDirectories ?? self.allowedReadDirectories() },
            memoryLocations: self.memoryLocations,
            mcpStore: mcpStore,
            attachmentStore: attachmentStore,
            artifactStore: artifactStore,
            visionGroupResolver: visionGroupResolver,
            hookCoordinator: hookCoordinator,
            runtimeModelRegistry: runtimeModelRegistry,
            runtimeModelUseService: runtimeModelUseService,
            runtimeImageGenerationService: runtimeImageGenerationService,
            browserSessionStore: browserSessionStore,
            browserActionConversationID: conversationID,
            hookExecutionScope: (conversationID: conversationID, runID: runID, conversationTitle: conversationTitle),
            canonicalMessageResolver: self.canonicalMessageResolver,
            representationResolver: self.representationResolver,
            resourceConversionPolicies: self.resourceConversionPolicies,
            runAuthorityResolver: self.runAuthorityResolver
        )
        scoped.setConversationContext(activeConversationID: { conversationID }, modelSources: { modelSources })
        scoped.imageDataReader = imageDataReader
        scoped.subagents = subagents
        scoped.scheduler = scheduler
        scoped.setComputerUseV2Engine(self.computerUseV2Engine)
        scoped.setComputerUseRoute(self.computerUseRoute)
        return scoped
    }

    func scoped(for conversationID: UUID, runID: UUID) -> ToolExecutor {
        scoped(
            for: conversationID,
            runID: runID,
            conversationTitle: nil,
            workspace: self.workspace,
            modelSources: (nil, nil)
        )
    }

    func activeAllowedReadDirectories() -> [URL] {
        allowedReadDirectories()
    }

    func setCanonicalMessageResolver(_ resolver: @escaping @MainActor (UUID) -> [ChatMessage]?) {
        self.canonicalMessageResolver = resolver
    }

    func execute(
        _ call: ProviderToolCall,
        reviewer: (any PermissionReviewing)? = nil,
        onUpdate: @escaping UpdateHandler
    ) async -> ToolExecutionOutcome {
        if let reviewer {
            return await TurnReviewContext.$activeReviewer.withValue(reviewer) {
                await executeAdmitted(call, onUpdate: onUpdate)
            }
        } else {
            return await executeAdmitted(call, onUpdate: onUpdate)
        }
    }

    private func executeAdmitted(_ call: ProviderToolCall, onUpdate: @escaping UpdateHandler) async -> ToolExecutionOutcome {
        // A subagent's tool call counts against its allowance; past it the call is refused and
        // the subagent goes on to its final report.
        if let binding = subagentBinding {
            let refusal = subagents.map { $0.refusalForTool(runID: binding.runID, call: call) } ?? "Subagent unavailable."
            if let refusal {
                onUpdate(.init(state: .denied, approvalState: .notRequired, output: refusal))
                return .init(content: refusal, isError: true, approvalState: .notRequired, durationMilliseconds: 0)
            }
        }
        return await executeInternal(call, onUpdate: onUpdate)
    }

    private func executeInternal(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async -> ToolExecutionOutcome {
        let startedAt = ContinuousClock.now
        var latestApproval = ToolApprovalState.notRequired
        let trackedUpdate: UpdateHandler = { update in
            latestApproval = update.approvalState
            onUpdate(update)
        }

        // 1. PreToolUse lifecycle hook
        if let hookCoordinator {
            let preResult: HookAggregatedResult
            if let scope = hookExecutionScope {
                preResult = await hookCoordinator.onPreToolUse(
                    conversationID: scope.conversationID,
                    runID: scope.runID,
                    call: call,
                    model: nil
                )
            } else {
                preResult = await hookCoordinator.onPreToolUse(call: call, model: nil)
            }
            if preResult.shouldDeny {
                let duration = milliseconds(since: startedAt)
                let reason = preResult.denyReason ?? "Denied by hook"
                trackedUpdate(.init(state: .denied, approvalState: .denied, output: "Hook denied tool: \(reason)"))
                logs.info("Hooks", "Tool \(call.function.name) execution was denied by PreToolUse hook: \(reason)")
                let deniedOutcome = ToolExecutionOutcome(
                    content: jsonString(["error": "Hook denied tool: \(reason)", "hook_denied": true]),
                    isError: true,
                    approvalState: .denied,
                    durationMilliseconds: duration
                )
                return deniedOutcome
            }
        }

        do {
            let outcome: ToolExecutionOutcome
            if let (serverID, toolName) = MCPToolNamespace.parse(exposedName: call.function.name) {
                outcome = try await executeMCPTool(serverID: serverID, toolName: toolName, call: call, onUpdate: trackedUpdate)
            } else {
                switch call.function.name {
                case "delegation_result":
                    outcome = try executeSubagentResult(call, onUpdate: trackedUpdate)
                case "shell_execute":
                    outcome = try await executeShell(call, onUpdate: trackedUpdate)
                case "file_read":
                    outcome = try await executeFileRead(call, onUpdate: trackedUpdate)
                case "file_list":
                    outcome = try await executeFileList(call, onUpdate: trackedUpdate)
                case "file_search":
                    outcome = try await executeFileSearch(call, onUpdate: trackedUpdate)
                case "file_write":
                    outcome = try await executeFileWrite(call, onUpdate: trackedUpdate)
                case "file_edit":
                    outcome = try await executeFileEdit(call, onUpdate: trackedUpdate)
                case "read_image":
                    outcome = try await executeReadImage(call, onUpdate: trackedUpdate)
                case "model_use":
                    outcome = try await executeModelUse(call, onUpdate: trackedUpdate)
                case "browser_use":
                    outcome = try await executeBrowserUse(call, onUpdate: trackedUpdate)
                case "delegate_task":
                    outcome = try await executeDelegateTask(call, onUpdate: trackedUpdate)
                case "delegation_control":
                    outcome = try await executeDelegationControl(call, onUpdate: trackedUpdate)
                case "update_plan":
                    outcome = try executeUpdatePlan(call, onUpdate: trackedUpdate)
                case "ask_user_question":
                    outcome = try await executeAskUserQuestion(call, onUpdate: trackedUpdate)
                case "attachment_copy":
                    outcome = try await executeAttachmentCopy(call, onUpdate: trackedUpdate)
                case "resource_convert":
                    outcome = try await executeResourceConvert(call, onUpdate: trackedUpdate)
                case "artifact_acquire":
                    outcome = try await executeArtifactAcquire(call, onUpdate: trackedUpdate)
                case "artifact_register":
                    outcome = try await executeArtifactRegister(call, onUpdate: trackedUpdate)
                case "tool_result_read":
                    outcome = try await executeToolResultRead(call, onUpdate: trackedUpdate)
                case "computer_use":
                    outcome = try await executeComputerUse(call, onUpdate: trackedUpdate)
                case "mcp_manage":
                    outcome = try await executeMCPManage(call, onUpdate: trackedUpdate)
                case "schedule_manage":
                    outcome = try await executeScheduleManage(call, onUpdate: trackedUpdate)
                default:
                    throw ToolExecutorError.unknownTool(call.function.name)
                }
            }
            await recordPostToolHook(hookCoordinator, call: call, outcome: outcome)
            return outcome
        } catch is CancellationError {
            let duration = milliseconds(since: startedAt)
            let message = "Cancelled by user."
            onUpdate(.init(state: .cancelled, approvalState: latestApproval, output: message))
            logs.info("Tool", "\(call.function.name) cancelled by the user.")
            let outcome = ToolExecutionOutcome(
                content: jsonString(["error": message, "cancelled": true]),
                isError: true,
                approvalState: latestApproval,
                durationMilliseconds: duration
            )
            await recordPostToolHook(hookCoordinator, call: call, outcome: outcome)
            return outcome
        } catch {
            let duration = milliseconds(since: startedAt)
            let message = error.localizedDescription
            onUpdate(.init(state: .failed, approvalState: latestApproval, output: message))
            logs.error("Tool", "\(call.function.name) failed: \(message)")
            let outcome = ToolExecutionOutcome(
                content: jsonString(["error": message]),
                isError: true,
                approvalState: latestApproval,
                durationMilliseconds: duration
            )
            await recordPostToolHook(hookCoordinator, call: call, outcome: outcome)
            return outcome
        }
    }

    private func recordPostToolHook(
        _ hookCoordinator: HookSessionCoordinator?,
        call: ProviderToolCall,
        outcome: ToolExecutionOutcome
    ) async {
        guard let hookCoordinator else { return }
        if let scope = hookExecutionScope {
            _ = await hookCoordinator.onPostToolUse(
                conversationID: scope.conversationID,
                runID: scope.runID,
                call: call,
                outcome: outcome,
                model: nil
            )
        } else {
            _ = await hookCoordinator.onPostToolUse(call: call, outcome: outcome, model: nil)
        }
    }

    private struct SubagentResultArguments: Decodable {
        let summary: String
        let changed_files: [String]?
        let blockers: [String]?
        let partial: Bool?
    }

    private func executeSubagentResult(_ call: ProviderToolCall, onUpdate: UpdateHandler) throws -> ToolExecutionOutcome {
        guard let binding = subagentBinding, let subagents else { throw DelegationFailure.unsupportedCapability }
        let args: SubagentResultArguments = try decode(call)
        try subagents.stageResult(runID: binding.runID, result: .init(summary: args.summary, partial: args.partial ?? false,
            changedFiles: args.changed_files ?? [], openItems: args.blockers ?? []))
        let result = "Result recorded. It is returned to the parent when this run ends; finish now unless something is left to do."
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: result))
        return .init(content: result, isError: false, approvalState: .notRequired, durationMilliseconds: 0)
    }

    private func executeModelUse(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard let registry = runtimeModelRegistry else {
            throw ToolExecutorError.unknownTool(call.function.name)
        }
        let arguments: ModelUseArguments = try decode(call)
        switch arguments.action.lowercased() {
        case "list":
            let models = registry.executableEntries.map(\.publicObject)
            let payload = jsonString(["models": models, "count": models.count])
            onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
            return .init(content: payload, isError: false, approvalState: .notRequired, durationMilliseconds: 0)
        case "search":
            guard let query = arguments.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw ToolExecutorError.invalidArguments("query is required for search.")
            }
            let models = registry.searchExecutable(query).map(\.publicObject)
            let payload = jsonString(["models": models, "count": models.count, "query": query])
            onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
            return .init(content: payload, isError: false, approvalState: .notRequired, durationMilliseconds: 0)
        case "run":
            guard let service = runtimeModelUseService,
                  let entryID = arguments.entryID,
                  let prompt = arguments.prompt else {
                throw ToolExecutorError.invalidArguments("entry_id and prompt are required for run.")
            }
            let entry = try service.validatedEntry(entryID: entryID, prompt: prompt, systemPrompt: arguments.systemPrompt, maxTokens: arguments.maxTokens)

            var artifactParts: [ChatContentPart] = []
            var artifactDataMap: [UUID: (data: Data, mimeType: String)] = [:]
            if let idStrings = arguments.artifactIDs, !idStrings.isEmpty {
                let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID
                guard let convID else {
                    throw ToolExecutorError.invalidArguments("Active conversation required for artifact resolution.")
                }
                guard let store = artifactStore else {
                    throw ArtifactStoreError.storeUnavailable
                }
                for idStr in idStrings {
                    guard let uuid = UUID(uuidString: idStr) else {
                        throw ToolExecutorError.invalidArguments("Invalid artifact UUID: '\(idStr)'.")
                    }
                    let descriptor = try store.resolveDescriptor(artifactID: uuid, conversationID: convID)
                    let data = try store.loadData(artifactID: uuid, conversationID: convID)
                    artifactParts.append(.artifact(id: uuid, semanticRole: .image, mimeType: descriptor.mimeType))
                    artifactDataMap[uuid] = (data: data, mimeType: descriptor.mimeType)
                }
            }

            let permission = ToolPermissionRequest(
                toolName: "model_use",
                summary: "Send delegated text to \(entry.provider.name) / \(entry.model.displayName)",
                workspaceURL: workspace.url,
                affectedURLs: [],
                requestsNetwork: true,
                isHighRisk: false
            )
            let approval = await authorize(permission, onUpdate: onUpdate)
            guard approval != .denied else { return deniedOutcome() }
            try Task.checkCancellation()
            onUpdate(.init(state: .running, approvalState: approval, output: "Calling \(entry.provider.name) / \(entry.model.displayName)..."))
            let startedAt = ContinuousClock.now
            let capturedMap = artifactDataMap
            let resolver: (@Sendable (UUID) throws -> (data: Data, mimeType: String))? = capturedMap.isEmpty ? nil : { @Sendable id in
                if let found = capturedMap[id] {
                    return found
                }
                throw ArtifactStoreError.artifactNotFound(id)
            }
            let result = try await service.run(
                entryID: entryID,
                prompt: prompt,
                systemPrompt: arguments.systemPrompt,
                maxTokens: arguments.maxTokens,
                artifactParts: artifactParts,
                artifactResolver: resolver
            )
            let duration = milliseconds(since: startedAt)
            onUpdate(.init(state: .completed, approvalState: approval, output: result.content))
            return .init(content: result.content, isError: false, approvalState: approval, durationMilliseconds: duration)
        case "generate_image":
            guard let service = runtimeImageGenerationService,
                  let entryID = arguments.entryID,
                  let prompt = arguments.prompt else {
                throw ToolExecutorError.invalidArguments("entry_id and prompt are required for generate_image.")
            }
            guard let entry = registry.resolveAllowed(entryID: entryID) else {
                throw RuntimeModelUseError.unavailable
            }
            guard RuntimeModelRegistry.isImageGeneratable(entry.model) else {
                throw RuntimeModelUseError.unsupported
            }
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPrompt.isEmpty else { throw RuntimeModelUseError.emptyPrompt }
            guard prompt.count <= 50_000 else { throw RuntimeModelUseError.promptTooLarge }
            if let size = arguments.size {
                guard size.count <= 64, !size.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                    throw ToolExecutorError.invalidArguments("size must be <= 64 characters and contain no newlines.")
                }
            }
            if let quality = arguments.quality {
                guard quality.count <= 64, !quality.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                    throw ToolExecutorError.invalidArguments("quality must be <= 64 characters and contain no newlines.")
                }
            }
            let permission = ToolPermissionRequest(
                toolName: "model_use",
                summary: "Generate an image with \(entry.provider.name) / \(entry.model.displayName)",
                workspaceURL: nil,
                affectedURLs: [],
                requestsNetwork: true,
                isHighRisk: false
            )
            let approval = await authorize(permission, onUpdate: onUpdate)
            guard approval != .denied else { return deniedOutcome() }
            try Task.checkCancellation()
            onUpdate(.init(state: .running, approvalState: approval, output: "Generating image with \(entry.provider.name) / \(entry.model.displayName)..."))
            let startedAt = ContinuousClock.now
            let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID
            let result: RuntimeImageGenerationResult
            do {
                result = try await service.generate(
                    entryID: entryID,
                    prompt: prompt,
                    size: arguments.size,
                    quality: arguments.quality,
                    conversationID: convID
                )
            } catch {
                let duration = milliseconds(since: startedAt)
                let errorOutput = "Failed to generate image: \(error.localizedDescription)"
                onUpdate(.init(state: .failed, approvalState: approval, output: errorOutput))
                return .init(content: errorOutput, isError: true, approvalState: approval, durationMilliseconds: duration)
            }

            let duration = milliseconds(since: startedAt)
            var imageObjects: [[String: Any]] = []
            for att in result.attachments {
                let diskFilename = (att.relativePath as NSString).lastPathComponent
                let safeURI = "limare://attachments/\(diskFilename)"
                var item: [String: Any] = [
                    "path": safeURI,
                    "filename": att.filename,
                    "mime_type": att.mimeType,
                ]
                if let w = att.width { item["width"] = w }
                if let h = att.height { item["height"] = h }
                if let desc = result.artifactDescriptor {
                    item["artifact_id"] = desc.artifactID.uuidString
                }
                imageObjects.append(item)
            }
            var resultObj: [String: Any] = [
                "status": "generated",
                "provider": result.providerName,
                "model": result.modelName,
                "images": imageObjects
            ]
            if let rev = result.revisedPrompt {
                resultObj["revised_prompt"] = rev
            }
            let payload = jsonString(resultObj)
            onUpdate(.init(state: .completed, approvalState: approval, output: payload))

            let resultParts: [ToolResultPart]
            if let desc = result.artifactDescriptor {
                resultParts = [.text(payload), .artifact(id: desc.artifactID, semanticRole: .generatedImage, mimeType: desc.mimeType)]
            } else {
                resultParts = [.text(payload)]
            }

            return .init(
                content: payload,
                isError: false,
                approvalState: approval,
                durationMilliseconds: duration,
                attachments: result.attachments,
                resultParts: resultParts
            )
        default:
            throw ToolExecutorError.invalidArguments("action must be list, search, run, or generate_image.")
        }
    }

    private func executeBrowserUse(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let input: BrowserActionInput
        do {
            input = try BrowserActionInput.parse(from: call.function.arguments)
        } catch {
            if call.isTruncatedByOutputLimit {
                throw ToolExecutorError.invalidArguments(call.outputLimitTruncationMessage)
            }
            throw error
        }

        guard let convID = browserActionConversationID
            ?? hookExecutionScope?.conversationID
            ?? activeConversationIDProvider?() else {
            throw ToolExecutorError.invalidArguments("Browser action requires a conversation identity.")
        }
        if let refusal = browserSessionStore.preflight(conversationID: convID) {
            let result = browserSessionStore.evidence(refusal, conversationID: convID)
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: result.jsonContent))
            return .init(content: result.jsonContent, isError: true, approvalState: .notRequired,
                durationMilliseconds: 0, mechanicalTerminalFact: result.mechanicalTerminalFact)
        }

        // Determine network request requirement and privacy-safe summary
        let requestsNetwork: Bool
        let summary: String
        switch input.action {
        case .navigate:
            requestsNetwork = true
            let hostOnly = sanitizedBrowserHost(input.url ?? "")
            summary = "Open \(hostOnly)"
        case .click:
            requestsNetwork = true
            summary = "Click element: \(input.selector ?? "")"
        case .type:
            requestsNetwork = true
            summary = "Enter text into current page: \(input.selector ?? "")"
        case .scroll:
            requestsNetwork = true
            summary = "Scroll \(input.direction?.rawValue ?? "down")"
        case .getPageInfo, .getText, .getReadable, .findElements, .screenshot, .waitForDomStable:
            requestsNetwork = false
            summary = "Browser \(input.action.rawValue)"
        }

        let request = ToolPermissionRequest(
            toolName: "browser_use",
            summary: summary,
            workspaceURL: nil,
            affectedURLs: [],
            command: nil,
            environmentKeys: [],
            requestsNetwork: requestsNetwork,
            isHighRisk: false
        )

        let approval = await authorize(request, onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        try Task.checkCancellation()
        onUpdate(.init(state: .running, approvalState: approval, output: "Browser \(input.action.rawValue)..."))

        let startedAt = ContinuousClock.now
        let result = try await browserSessionStore.execute(
            input: input,
            conversationID: convID
        )
        let duration = milliseconds(since: startedAt)

        let terminalState: ToolExecutionState = result.isError ? .failed : .completed
        onUpdate(.init(state: terminalState, approvalState: approval, output: result.jsonContent))

        let resultParts: [ToolResultPart]?
        if let parts = result.resultParts {
            resultParts = [.text(result.jsonContent)] + parts
        } else {
            resultParts = nil
        }

        return .init(
            content: result.jsonContent,
            isError: result.isError,
            approvalState: approval,
            durationMilliseconds: duration,
            attachments: result.attachments,
            resultParts: resultParts,
            mechanicalTerminalFact: result.mechanicalTerminalFact
        )
    }

    private func sanitizedBrowserHost(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !str.contains("://") {
            str = "https://\(str)"
        }
        guard let url = URL(string: str), let host = url.host else {
            return urlString
        }
        return host
    }

    private func executeShell(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: ShellArguments = try decode(call)
        let workspaceURL = workspace.url ?? FileManager.default.temporaryDirectory
        var cwd: URL
        if let explicitCwd = arguments.cwd, !explicitCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cwd = try WorkspacePathResolver.resolve(explicitCwd, relativeTo: workspaceURL, mustExist: true)
        } else {
            cwd = workspaceURL
        }
        let command = arguments.command
        let envSecrets = Array(arguments.environment?.values ?? Dictionary<String, String>().values).filter { !$0.isEmpty }
        let reviewerSafeCommand = SecretMasker.redact(arguments.command, secrets: envSecrets)
        let justification = arguments.justification?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = ToolPermissionRequest(
            toolName: call.function.name,
            summary: arguments.requiresEscalation
                ? "Run a shell command in \(cwd.path) outside the sandbox"
                    + (justification.isEmpty ? "" : ": \(justification)")
                : "Run a shell command in \(cwd.path)",
            workspaceURL: workspace.url,
            affectedURLs: [cwd],
            command: arguments.command,
            reviewerSafeCommand: reviewerSafeCommand,
            environmentKeys: arguments.environment?.keys.sorted() ?? [],
            isHighRisk: arguments.requiresEscalation,
            leavesSandbox: arguments.requiresEscalation
        )
        let approval = await authorize(request, onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }
        // Full access runs outside the sandbox; otherwise only an escalation someone approved does.
        let unconfined = permissions.mode == .fullAccess || (arguments.requiresEscalation && approval == .approved)

        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        logs.info("Tool", "Starting shell_execute in \(cwd.path)\(unconfined ? " (outside the sandbox)" : "").")
        var environment = arguments.environment ?? [:]
        if environment["PATH"] == nil, let path = await LoginShellEnvironment.path() {
            environment["PATH"] = path
        }
        let secretValues = envSecrets
        var rawDisplayOutput = ""
        var finalResult: ShellExecutionResult?
        var observedShellEvent = false
        let streamShell: @MainActor () async throws -> Void = { [self] in
            do {
            for try await event in shellRunner.stream(
                ShellExecutionRequest(
                    command: command,
                    cwd: cwd,
                    environment: environment,
                    timeoutSeconds: min(max(arguments.timeoutSeconds ?? 120, 0.1), 3_600),
                    boundary: .primaryInteractive,
                    unconfined: unconfined,
                    writableRoot: workspaceURL
                )
            ) {
                observedShellEvent = true
                switch event {
                case .output(let stream, _, _, let text):
                    rawDisplayOutput = bounded(
                        rawDisplayOutput + (stream == .stderr ? "[stderr] " : "") + text,
                        maximumBytes: 131_072
                    )
                    let displayOutput = sanitizedShellText(rawDisplayOutput, masking: secretValues)
                    onUpdate(.init(state: .running, approvalState: approval, output: displayOutput))
                case .finished(let result):
                    finalResult = result
                }
            }
            } catch where !observedShellEvent && error is ShellRunnerError {
                throw error
            }
        }
        try await streamShell()
        try Task.checkCancellation()
        guard let result = finalResult else {
            throw ShellRunnerError.spawnFailed("Shell stream ended without a result.")
        }

        var payloadObject: [String: Any] = [
            "stdout": bounded(sanitizedShellText(result.stdout, masking: secretValues), maximumBytes: 65_536),
            "stderr": bounded(sanitizedShellText(result.stderr, masking: secretValues), maximumBytes: 65_536),
            "stdout_original_bytes": result.stdoutOriginalByteCount,
            "stderr_original_bytes": result.stderrOriginalByteCount,
            "duration_ms": result.durationMilliseconds,
            "timed_out": result.timedOut,
            "cancelled": result.cancelled,
            "truncated": result.truncated,
        ]
        payloadObject["exit_code"] = result.exitCode.map(Int.init) ?? NSNull()
        let payload = jsonString(payloadObject)
        let terminalState: ToolExecutionState
        if result.timedOut {
            terminalState = .timedOut
        } else if result.cancelled {
            terminalState = .cancelled
        } else if result.exitCode != 0 {
            terminalState = .failed
        } else {
            terminalState = .completed
        }
        let displayOutput = sanitizedShellText(rawDisplayOutput, masking: secretValues)
        onUpdate(.init(state: terminalState, approvalState: approval, output: displayOutput))
        logs.info("Tool", "shell_execute finished with exit code \(result.exitCode.map(String.init) ?? "none").")
        return .init(
            content: payload,
            isError: terminalState != .completed,
            approvalState: approval,
            durationMilliseconds: result.durationMilliseconds,
            mechanicalTerminalFact: .shell(exitCode: result.exitCode, timedOut: result.timedOut, cancelled: result.cancelled)
        )
    }

    private func executeFileRead(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: ReadArguments = try decode(call)
        if arguments.path.hasPrefix("limare://attachments/") {
            return try executeAttachmentFileRead(path: arguments.path, onUpdate: onUpdate)
        }
        let context = try fileContext(path: arguments.path, mustExist: true)
        let approval = await authorize(
            context.request(toolName: call.function.name, action: "Read"),
            allowedReadDirectories: allowedReadDirectories(),
            onUpdate: onUpdate
        )
        guard approval != .denied else { return deniedOutcome() }
        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        let startedAt = ContinuousClock.now
        if UTType(filenameExtension: context.url.pathExtension)?.conforms(to: .image) == true {
            return try readImageFile(context.url, approval: approval, startedAt: startedAt, onUpdate: onUpdate)
        }
        let content = try files.read(url: context.url)
        let boundedContent: String
        switch FileReadWindow.apply(content, offset: arguments.offset, limit: arguments.limit, maximumBytes: 65_536) {
        case .success(let window): boundedContent = window
        case .failure(let failure): throw ToolExecutorError.invalidArguments(failure.message)
        }
        onUpdate(.init(state: .completed, approvalState: approval, output: boundedContent))
        logs.info("Tool", "Read file \(context.url.path).")
        return .init(content: boundedContent, isError: false, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
    }

    /// Reads an image file the way Claude Code's Read does: the image itself, not its bytes as
    /// text. It is scaled like a chat attachment and handed over as an image artifact, which the
    /// request projection shows a vision model inline and points any other model to read_image.
    private func readImageFile(
        _ url: URL,
        approval: ToolApprovalState,
        startedAt: ContinuousClock.Instant,
        onUpdate: @escaping UpdateHandler
    ) throws -> ToolExecutionOutcome {
        guard let store = artifactStore,
              let conversationID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID else {
            throw ToolExecutorError.invalidArguments("'\(url.lastPathComponent)' is an image and no conversation is available to attach it to.")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size <= AttachmentStore.maxSourceImageBytes else {
            throw ToolExecutorError.invalidArguments("'\(url.lastPathComponent)' is \(size) bytes; images over \(AttachmentStore.maxSourceImageBytes) bytes cannot be read.")
        }
        let original = try Data(contentsOf: url)
        let probe = try ImageNormalizationKernel.probe(original)
        let image = try ImageNormalizationKernel.normalize(original)
        let descriptor = try store.save(
            data: image.data,
            conversationID: conversationID,
            filename: url.deletingPathExtension().lastPathComponent + (image.isPNG ? ".png" : ".jpg"),
            mimeType: image.mimeType,
            producerProvenance: .hostAcquisition,
            workspaceProvenance: nil,
            authorizationProvenance: "file_read",
            retentionClass: .conversationRetained
        )
        let scaled = (image.width, image.height) != (probe.width, probe.height) ? ", shown at \(image.width)×\(image.height)" : ""
        let payload = "Image \(url.path) (\(probe.width)×\(probe.height)\(scaled)) is attached to this result."
        onUpdate(.init(state: .completed, approvalState: approval, output: payload))
        logs.info("Tool", "Read image \(url.path) as artifact \(descriptor.artifactID.uuidString).")
        return ToolExecutionOutcome(
            content: payload,
            isError: false,
            approvalState: approval,
            durationMilliseconds: milliseconds(since: startedAt),
            resultParts: [.text(payload), .artifact(id: descriptor.artifactID, semanticRole: .image, mimeType: descriptor.mimeType)]
        )
    }

    private func executeAttachmentFileRead(path: String, onUpdate: @escaping UpdateHandler) throws -> ToolExecutionOutcome {
        let startedAt = ContinuousClock.now
        let url = try attachmentStore.fileURL(forAttachmentURI: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let output = "attachment_missing\nPath: \(path)"
            return .init(content: output, isError: true, approvalState: .notRequired, durationMilliseconds: milliseconds(since: startedAt))
        }
        let classification = AttachmentClassifier.classify(url: url)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let attachment = ChatAttachment(
            kind: classification.kind,
            filename: url.lastPathComponent,
            relativePath: "attachments/\(url.lastPathComponent)",
            mimeType: classification.mimeType,
            byteCount: size,
            contentTypeIdentifier: classification.contentTypeIdentifier
        )
        onUpdate(.init(state: .running, approvalState: .notRequired, output: ""))
        let output: String
        if classification.kind == .text {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard let decoded = String(data: data.prefix(65_536), encoding: .utf8) else {
                output = AttachmentReferenceFormatter.unsupportedInspection(for: attachment)
                onUpdate(.init(state: .completed, approvalState: .notRequired, output: output))
                return .init(content: output, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: startedAt))
            }
            output = decoded + (data.count > 65_536 ? "\n… output truncated for model context …" : "")
        } else {
            output = AttachmentReferenceFormatter.unsupportedInspection(for: attachment)
        }
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: output))
        logs.info("Tool", "Read attached \(classification.kind.rawValue) file \(url.lastPathComponent) (\(size) bytes).")
        return .init(content: output, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: startedAt))
    }

    private func executeFileList(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let workspaceURL = workspace.url ?? FileManager.default.temporaryDirectory
        let args: FileListArguments = try decode(call)
        let subpath = args.path ?? "."
        let targetURL = try WorkspacePathResolver.resolve(subpath, relativeTo: workspaceURL, mustExist: true)
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: targetURL)
        let allowedDirs = allowedReadDirectories()
        let approval = await authorize(
            ToolPermissionRequest(
                toolName: call.function.name,
                summary: "List directory contents in \(targetURL.path)",
                workspaceURL: workspace.url,
                affectedURLs: [targetURL],
                command: nil,
                environmentKeys: [],
                requestsNetwork: false,
                isHighRisk: false
            ),
            allowedReadDirectories: allowedDirs,
            onUpdate: onUpdate
        )
        guard approval != .denied else { return deniedOutcome() }
        onUpdate(.init(state: .running, approvalState: approval, output: ""))

        let containmentRoot: URL
        let containmentSubpath: String
        if let wsURL = workspace.url, WorkspacePathResolver.isInsideWorkspace(targetURL, workspaceURL: wsURL) {
            containmentRoot = wsURL
            containmentSubpath = subpath
        } else if let matchingAllowed = allowedDirs.first(where: { WorkspacePathResolver.isInsideWorkspace(targetURL, workspaceURL: $0) }) {
            containmentRoot = matchingAllowed
            containmentSubpath = relativePath(from: matchingAllowed, to: targetURL)
        } else {
            containmentRoot = targetURL
            containmentSubpath = "."
        }

        let startedAt = ContinuousClock.now
        let entries = try researchFiles.listFiles(
            in: containmentRoot,
            subpath: containmentSubpath,
            recursive: args.recursive ?? true,
            maxDepth: args.max_depth ?? ResearchFileService.defaultMaxDepth,
            maxEntries: args.max_entries ?? ResearchFileService.defaultMaxEntries
        )
        let duration = milliseconds(since: startedAt)
        let payload = jsonString([
            "count": entries.count,
            "entries": entries
        ])
        onUpdate(.init(state: .completed, approvalState: approval, output: payload))
        return ToolExecutionOutcome(content: payload, isError: false, approvalState: approval, durationMilliseconds: duration)
    }

    private func executeFileSearch(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let workspaceURL = workspace.url ?? FileManager.default.temporaryDirectory
        let args: FileSearchArguments = try decode(call)
        let subpath = args.path ?? "."
        let targetURL = try WorkspacePathResolver.resolve(subpath, relativeTo: workspaceURL, mustExist: true)
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: targetURL)
        let allowedDirs = allowedReadDirectories()
        let approval = await authorize(
            ToolPermissionRequest(
                toolName: call.function.name,
                summary: "Search for '\(args.query)' in \(targetURL.path)",
                workspaceURL: workspace.url,
                affectedURLs: [targetURL],
                command: nil,
                environmentKeys: [],
                requestsNetwork: false,
                isHighRisk: false
            ),
            allowedReadDirectories: allowedDirs,
            onUpdate: onUpdate
        )
        guard approval != .denied else { return deniedOutcome() }
        onUpdate(.init(state: .running, approvalState: approval, output: ""))

        let containmentRoot: URL
        let containmentSubpath: String
        if let wsURL = workspace.url, WorkspacePathResolver.isInsideWorkspace(targetURL, workspaceURL: wsURL) {
            containmentRoot = wsURL
            containmentSubpath = subpath
        } else if let matchingAllowed = allowedDirs.first(where: { WorkspacePathResolver.isInsideWorkspace(targetURL, workspaceURL: $0) }) {
            containmentRoot = matchingAllowed
            containmentSubpath = relativePath(from: matchingAllowed, to: targetURL)
        } else {
            // A file is searched from its folder, so results name it.
            var isDirectory: ObjCBool = false
            let isFile = FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            containmentRoot = isFile ? targetURL.deletingLastPathComponent() : targetURL
            containmentSubpath = isFile ? targetURL.lastPathComponent : "."
        }

        let startedAt = ContinuousClock.now
        let results = try researchFiles.searchFiles(
            in: containmentRoot,
            query: args.query,
            subpath: containmentSubpath,
            mode: args.mode ?? "content",
            isRegex: args.regex ?? false,
            maxResults: args.max_results ?? ResearchFileService.defaultMaxSearchResults
        )
        let duration = milliseconds(since: startedAt)
        let payload = jsonString([
            "query": args.query,
            "count": results.count,
            "results": results
        ])
        onUpdate(.init(state: .completed, approvalState: approval, output: payload))
        return ToolExecutionOutcome(content: payload, isError: false, approvalState: approval, durationMilliseconds: duration)
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        if targetPath.hasPrefix(basePath) {
            let relative = targetPath.dropFirst(basePath.count)
            let trimmed = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "." : trimmed
        }
        return targetPath
    }

    private static func delegationIdentity(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// delegate_task: start 1–3 subagents, then wait like Codex's wait_agent: until one finishes
    /// or `wait_seconds` pass (0 returns at once), with the others' progress in the result.
    private func executeNativeDelegateTask(_ call: ProviderToolCall, onUpdate: @escaping UpdateHandler) async throws -> ToolExecutionOutcome {
        guard subagentBinding == nil, let subagents, let scope = hookExecutionScope,
              let parentWorkspace = workspace.url,
              let source = activeConversationModelSourcesProvider?().sub ?? activeConversationModelSourcesProvider?().primary else {
            throw DelegationFailure.admissionRejected
        }
        let started = ContinuousClock.now
        let args: DelegateTaskArguments = try decode(call)
        guard (1...3).contains(args.tasks.count) else { throw ToolExecutorError.invalidArguments("Give 1 to 3 tasks.") }
        var specs: [SubagentSpec] = []
        for (index, raw) in args.tasks.enumerated() {
            let validated = AgentTask(title: raw.title, goal: raw.goal, context: raw.context ?? "", scope: raw.scope ?? "",
                constraints: raw.constraints, expectedOutput: raw.expected_output, allowWebResearch: raw.allow_web ?? false,
                workspaceScope: raw.workspace_scope, taskEffort: raw.task_effort)
            try validated.validate()
            let role: SubagentRole = raw.role == "coding" ? .coding : .research
            // workspace_scope only says where to start: every subagent works in the parent's workspace.
            let focus = raw.workspace_scope.flatMap { (try? WorkspacePathResolver.resolve($0, relativeTo: parentWorkspace, mustExist: true))?.path }
                .map { "Start in: \($0)" }
            let goal = [raw.goal, raw.context, raw.scope.map { "Scope: " + $0 }, focus, raw.constraints.map { "Constraints: " + $0 },
                raw.expected_output.map { "Expected output: " + $0 }].compactMap { $0 }.joined(separator: "\n\n")
            let taskID = Self.delegationIdentity("subagent-v2:\(scope.conversationID):\(scope.runID):\(call.id):\(index)")
            // Registered before the child can start, so its first write is attributed for undo.
            changeRecorder?.registerDelegation(taskID: taskID)
            specs.append(.init(id: taskID, title: raw.title, goal: goal, role: role, allowWeb: raw.allow_web ?? false,
                allowance: .init(effort: AgentTaskEffortProfile.resolve(from: raw.task_effort))))
        }
        let waitSeconds = args.background == true ? 0 : (args.wait_seconds ?? SubagentCoordinator.defaultWaitSeconds)
        let tasks = try subagents.start(specs, parentConversationID: scope.conversationID, modelSource: source,
                                         background: waitSeconds <= 0)
        let content: String
        if waitSeconds <= 0 {
            content = subagents.resultsText(tasks.compactMap { subagents.store.tasks[$0.id] },
                header: "Started \(tasks.count) subagent task(s). Their results are delivered to you when they finish; meanwhile do other work, or wait with delegation_control (action wait).")
        } else {
            content = try await subagents.wait(taskIDs: tasks.map(\.id), timeout: SubagentCoordinator.clampedWait(waitSeconds)) { progress in
                onUpdate(.init(state: .running, approvalState: .notRequired, output: progress))
            }
        }
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: content))
        return .init(content: content, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: started))
    }

    private struct PlanArguments: Decodable {
        struct Item: Decodable { let step: String; let status: String }
        let explanation: String?
        let plan: [Item]
    }

    /// update_plan as Codex has it: the plan is shown to the user; the model gets "Plan updated".
    private func executeUpdatePlan(_ call: ProviderToolCall, onUpdate: @escaping UpdateHandler) throws -> ToolExecutionOutcome {
        let args: PlanArguments = try decode(call)
        guard args.plan.allSatisfy({ ["pending", "in_progress", "completed"].contains($0.status) }) else {
            throw ToolExecutorError.invalidArguments("Each step's status is pending, in_progress or completed.")
        }
        guard args.plan.filter({ $0.status == "in_progress" }).count <= 1 else {
            throw ToolExecutorError.invalidArguments("At most one step can be in_progress at a time.")
        }
        var shown = args.plan.map { item -> String in
            switch item.status {
            case "completed": return "- [x] " + item.step
            case "in_progress": return "- [ ] **" + item.step + "**"
            default: return "- [ ] " + item.step
            }
        }.joined(separator: "\n")
        if let explanation = args.explanation, !explanation.isEmpty { shown = explanation + "\n\n" + shown }
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: shown))
        return .init(content: "Plan updated", isError: false, approvalState: .notRequired, durationMilliseconds: 0)
    }

    private struct AskUserQuestionArguments: Decodable {
        struct Question: Decodable {
            struct Option: Decodable { let label: String; let description: String }
            let question: String
            let header: String
            let options: [Option]
            let multiSelect: Bool?
        }
        let questions: [Question]
    }

    /// ask_user_question as Claude Code's AskUserQuestion: a card this run waits on until the user
    /// answers, skips or sends a new message. Only a conversation's own attended run has someone to ask.
    private func executeAskUserQuestion(_ call: ProviderToolCall, onUpdate: @escaping UpdateHandler) async throws -> ToolExecutionOutcome {
        let started = ContinuousClock.now
        let args: AskUserQuestionArguments = try decode(call)
        let questions = args.questions.map { question in
            UserQuestion(question: question.question, header: question.header,
                         options: question.options.map { UserQuestion.Option(label: $0.label, description: $0.description) },
                         multiSelect: question.multiSelect ?? false)
        }
        if let problem = UserQuestion.validationProblem(questions) {
            throw ToolExecutorError.invalidArguments(problem)
        }
        guard let userQuestions, let scope = hookExecutionScope, userQuestions.isUnattendedRun?(scope.runID) != true else {
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: UserQuestionText.refusal))
            return .init(content: UserQuestionText.refusal, isError: true, approvalState: .notRequired, durationMilliseconds: milliseconds(since: started))
        }
        onUpdate(.init(state: .running, approvalState: .notRequired, output: UserQuestionText.pendingOutput(questions: questions)))
        let resolution = await userQuestions.ask(PendingUserQuestion(
            conversationID: scope.conversationID, runID: scope.runID, providerCallID: call.id,
            conversationTitle: scope.conversationTitle, questions: questions))
        // A stopped run takes the shared cancellation path.
        guard let content = UserQuestionText.modelContent(questions: questions, resolution: resolution) else {
            throw CancellationError()
        }
        // The record's output is what later requests send the model, so it holds the same text.
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: content))
        return .init(content: content, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: started))
    }

    private struct NativeControlArguments: Decodable {
        let action: String
        let task_id: UUID?
        let instruction: String?
        let timeout_seconds: Double?
    }

    /// delegation_control: wait for, check on, redirect or stop a subagent this conversation started.
    private func executeDelegationControl(_ call: ProviderToolCall, onUpdate: @escaping UpdateHandler) async throws -> ToolExecutionOutcome {
        guard let subagents, let owner = hookExecutionScope else { throw DelegationFailure.unsupportedCapability }
        let started = ContinuousClock.now
        let args: NativeControlArguments = try decode(call)
        let content: String
        if args.action == "wait" {
            // No task_id waits for every unfinished task of this conversation.
            let targets: [UUID]
            if let id = args.task_id {
                guard subagents.store.tasks[id]?.parentConversationID == owner.conversationID else {
                    throw ToolExecutorError.invalidArguments("No subagent task \(id) belongs to this conversation.")
                }
                targets = [id]
            } else {
                targets = subagents.store.tasks(for: owner.conversationID).filter { !$0.status.isFinished }.map(\.id)
                guard !targets.isEmpty else { throw ToolExecutorError.invalidArguments("No subagent task of this conversation is running.") }
            }
            content = try await subagents.wait(taskIDs: targets, timeout: SubagentCoordinator.clampedWait(args.timeout_seconds)) { progress in
                onUpdate(.init(state: .running, approvalState: .notRequired, output: progress))
            }
        } else {
            guard let id = args.task_id else { throw ToolExecutorError.invalidArguments("\(args.action) needs a task_id.") }
            guard let task = subagents.store.tasks[id], task.parentConversationID == owner.conversationID else {
                throw ToolExecutorError.invalidArguments("No subagent task \(id) belongs to this conversation.")
            }
            let payload: [String: Any]
            switch args.action {
            case "status", "collect":
                payload = subagents.projection(task)
            case "cancel":
                subagents.cancel(taskID: task.id)
                payload = subagents.projection(subagents.store.tasks[task.id]!)
            case "continue":
                guard let instruction = args.instruction, !instruction.isEmpty else {
                    throw ToolExecutorError.invalidArguments("continue needs an instruction.")
                }
                payload = subagents.projection(try subagents.continueTask(taskID: task.id, instruction: instruction))
            default:
                throw ToolExecutorError.invalidArguments("Unknown delegation_control action '\(args.action)'. Use wait, status, continue or cancel.")
            }
            content = jsonString(payload)
        }
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: content))
        return .init(content: content, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: started))
    }

    private func executeDelegateTask(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard usesNativeDelegation else { throw DelegationFailure.unsupportedCapability }
        return try await executeNativeDelegateTask(call, onUpdate: onUpdate)
    }

    private func executeFileWrite(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: WriteArguments = try decode(call)
        let context = try fileContext(path: arguments.path, mustExist: false)
        let approval = await authorize(context.request(toolName: call.function.name, action: "Write"), allowedReadDirectories: allowedReadDirectories(), onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }
        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        let startedAt = ContinuousClock.now
        let count = try recordedWrite(context.url, call: call) { location in
            if let location { return try files.write(content: arguments.content, at: location) }
            return try files.write(url: context.url, content: arguments.content)
        }
        let output = "Wrote \(count) bytes to \(context.url.path)."
        onUpdate(.init(state: .completed, approvalState: approval, output: output))
        logs.info("Tool", output)
        return .init(content: output, isError: false, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
    }

    private func executeFileEdit(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: EditArguments = try decode(call)
        let context = try fileContext(path: arguments.path, mustExist: true)
        let approval = await authorize(context.request(toolName: call.function.name, action: "Edit"), allowedReadDirectories: allowedReadDirectories(), onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }
        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        let startedAt = ContinuousClock.now
        let count = try recordedWrite(context.url, call: call) { location in
            try files.edit(url: context.url, oldText: arguments.oldText, newText: arguments.newText, writingTo: location)
        }
        let output = "Edited \(context.url.path); resulting file is \(count) bytes."
        onUpdate(.init(state: .completed, approvalState: approval, output: output))
        logs.info("Tool", output)
        return .init(content: output, isError: false, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
    }

    private static func artifactUUID(from source: String) -> UUID? {
        if source.hasPrefix("limare://artifacts/") {
            return UUID(uuidString: String(source.dropFirst("limare://artifacts/".count)))
        }
        if source.hasPrefix("artifact://") {
            return UUID(uuidString: String(source.dropFirst("artifact://".count)))
        }
        return source.count == 36 ? UUID(uuidString: source) : nil
    }

    private func executeReadImage(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: ReadImageArguments = try decode(call)
        let trimmedPath = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ToolExecutorError.invalidArguments("Path must not be empty.")
        }

        let fileURL: URL
        let isAttachment = trimmedPath.hasPrefix("limare://attachments/")
        let artifactUUID = Self.artifactUUID(from: trimmedPath)

        if let artifactUUID {
            let convID = hookExecutionScope?.conversationID
                ?? activeConversationIDProvider?()
                ?? browserActionConversationID
            guard let convID else {
                throw ToolExecutorError.invalidArguments("Active conversation required for artifact resolution.")
            }
            guard let store = artifactStore else {
                throw ArtifactStoreError.storeUnavailable
            }
            fileURL = try store.resolveFileURL(artifactID: artifactUUID, conversationID: convID)
        } else if isAttachment {
            fileURL = try attachmentStore.fileURL(forAttachmentURI: trimmedPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ToolExecutorError.invalidArguments("Attachment file not found: \(trimmedPath)")
            }
        } else {
            if let workspaceURL = workspace.url {
                fileURL = try WorkspacePathResolver.resolve(trimmedPath, relativeTo: workspaceURL, mustExist: true)
            } else if trimmedPath.hasPrefix("/") {
                fileURL = URL(fileURLWithPath: trimmedPath)
            } else {
                throw ToolExecutorError.invalidArguments("No workspace selected. Choose a Workspace to inspect workspace-relative images.")
            }
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ToolExecutorError.invalidArguments("Image file not found at \(fileURL.path)")
            }
            try MCPInfrastructureBoundary.requireAgentFileAccess(to: fileURL)
        }

        // Check file size limit before reading bytes into memory
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= AttachmentStore.maxSourceImageBytes else {
            throw ToolExecutorError.invalidArguments("Image file exceeds 25MB limit (\(fileSize) bytes).")
        }

        let request = ToolPermissionRequest(
            toolName: call.function.name,
            summary: "Inspect image at \(fileURL.path)",
            workspaceURL: workspace.url,
            affectedURLs: [fileURL],
            command: nil,
            environmentKeys: [],
            requestsNetwork: true,
            isHighRisk: PermissionEvaluator.isSensitivePath(fileURL)
        )
        let approval = await authorize(request, allowedReadDirectories: allowedReadDirectories(), onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        guard let resolver = visionGroupResolver, resolver.hasExecutableCandidate else {
            let fail = VisionGroupResolver.failureText("No usable Vision Group is currently available.")
            onUpdate(.init(state: .failed, approvalState: approval, output: fail))
            return .init(content: fail, isError: true, approvalState: approval, durationMilliseconds: 0)
        }

        let startedAt = ContinuousClock.now
        do {
            let rawData = try imageDataReader(fileURL)
            let (normalizedData, mimeType, _, _, _) = try attachmentStore.normalizeImageData(rawData)

            onUpdate(.init(state: .running, approvalState: approval, output: "Analyzing image with Vision Group..."))

            let outcome = try await resolver.describe(
                imageData: normalizedData,
                mimeType: mimeType,
                customPrompt: arguments.prompt,
                onAttempt: { attempt in
                    onUpdate(.init(
                        state: .running,
                        approvalState: approval,
                        output: "Analyzing with \(attempt.modelName) (\(attempt.index)/\(attempt.total))..."
                    ))
                }
            )
            let framed = VisionGroupResolver.framedDescription(
                outcome,
                groupName: resolver.groupName(),
                question: arguments.prompt
            )
            let duration = milliseconds(since: startedAt)
            onUpdate(.init(state: .completed, approvalState: approval, output: framed))
            logs.info("Tool", "read_image completed via \(outcome.modelName) in \(duration)ms.")
            return .init(content: framed, isError: false, approvalState: approval, durationMilliseconds: duration)
        } catch let visionError as VisionError {
            let duration = milliseconds(since: startedAt)
            let fail = VisionGroupResolver.failureText(visionError.errorDescription ?? visionError.localizedDescription)
            onUpdate(.init(state: .failed, approvalState: approval, output: fail))
            logs.error("Tool", "read_image failed: \(visionError.localizedDescription)")
            return .init(content: fail, isError: true, approvalState: approval, durationMilliseconds: duration)
        } catch {
            let duration = milliseconds(since: startedAt)
            let fail = VisionGroupResolver.failureText(error.localizedDescription)
            onUpdate(.init(state: .failed, approvalState: approval, output: fail))
            logs.error("Tool", "read_image failed: \(error.localizedDescription)")
            return .init(content: fail, isError: true, approvalState: approval, durationMilliseconds: duration)
        }
    }

    private func executeMCPTool(
        serverID: String,
        toolName: String,
        call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard let mcpStore else {
            throw ToolExecutorError.unknownTool("MCP is not configured.")
        }
        let startedAt = ContinuousClock.now

        let argData = call.function.arguments.data(using: .utf8) ?? Data()
        let arguments: [String: AnyCodable]
        do {
            if argData.isEmpty {
                arguments = [:]
            } else {
                arguments = try JSONDecoder().decode([String: AnyCodable].self, from: argData)
            }
        } catch {
            if call.isTruncatedByOutputLimit {
                throw ToolExecutorError.invalidArguments(call.outputLimitTruncationMessage)
            }
            throw ToolExecutorError.invalidArguments("Tool call arguments are malformed or incomplete JSON: \(error.localizedDescription)")
        }

        let isHTTP = mcpStore.servers.first(where: { $0.id == serverID })?.isHTTP ?? false
        let request = ToolPermissionRequest(
            toolName: call.function.name,
            summary: "Call MCP tool '\(toolName)' on '\(serverID)'",
            workspaceURL: workspace.url,
            affectedURLs: [],
            command: nil,
            environmentKeys: [],
            requestsNetwork: isHTTP,
            isHighRisk: false
        )
        let approval = await authorize(request, onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID
        let result = try await mcpStore.callTool(
            serverID: serverID,
            toolName: toolName,
            arguments: arguments,
            conversationID: convID,
            artifactStore: artifactStore
        )
        let duration = milliseconds(since: startedAt)

        let state: ToolExecutionState = result.isError ? .failed : .completed
        onUpdate(.init(state: state, approvalState: approval, output: result.content))
        logs.info("MCP", "Finished tool '\(toolName)' on '\(serverID)' in \(duration)ms.")

        return ToolExecutionOutcome(
            content: result.content,
            isError: result.isError,
            approvalState: approval,
            durationMilliseconds: duration,
            attachments: result.attachments,
            resultParts: result.resultParts
        )
    }

    private struct MCPManageArguments: Decodable {
        let action: String
        let server_id: String?
        let transport: String?
        let url: String?
        let command: String?
        let args: [String]?
        let profile: String?
        let expected_revision: UInt64?
        let request_id: UUID?
        let set: [String: AnyCodable]?
        let remove: [String]?
    }

    private func executeMCPManage(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard let mcpStore else {
            throw ToolExecutorError.unknownTool("MCP is not configured.")
        }
        let startedAt = ContinuousClock.now

        // Credentials never travel through this tool: Limare collects them in its own protected prompt.
        let argData = call.function.arguments.data(using: .utf8) ?? Data()
        if let rawDict = (try? JSONSerialization.jsonObject(with: argData)) as? [String: Any] {
            let allowedKeys = Set(HarnessToolDefinitions.mcpManageProperties.keys)
            for key in rawDict.keys where !allowedKeys.contains(key) {
                throw ToolExecutorError.invalidArguments("Unsupported field on mcp_manage. Credentials are never passed through this tool; use authenticate to request native Human interaction.")
            }
        }
        let args: MCPManageArguments = try decode(call)
        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let serverID = args.server_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        func failure(_ message: String, approval: ToolApprovalState = .notRequired) -> ToolExecutionOutcome {
            let payload = jsonString(["error": message])
            onUpdate(.init(state: .failed, approvalState: approval, output: payload))
            return .init(content: payload, isError: true, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
        }
        func requireServer() throws -> MCPServerConfig? {
            guard !serverID.isEmpty else { throw ToolExecutorError.invalidArguments("server_id is required for \(action).") }
            return mcpStore.servers.first(where: { $0.id == serverID })
        }
        func permission(_ summary: String, network: Bool) async -> ToolApprovalState {
            await authorize(ToolPermissionRequest(
                toolName: "mcp_manage",
                summary: summary,
                workspaceURL: workspace.url,
                affectedURLs: [],
                command: nil,
                environmentKeys: [],
                requestsNetwork: network,
                isHighRisk: false
            ), onUpdate: onUpdate)
        }

        func mutationIdentity() throws -> (UInt64, UUID) {
            guard let revision = args.expected_revision, let id = args.request_id else {
                throw ToolExecutorError.invalidArguments("Mutating MCP actions require expected_revision and a UUID request_id.")
            }
            return (revision, id)
        }
        func mutationOutcome(_ receipt: MCPHostOperationReceipt, approval: ToolApprovalState) -> ToolExecutionOutcome {
            var item: [String: Any] = ["operation_id": receipt.id.uuidString, "server_id": serverID,
                "configuration_revision": mcpStore.configurationRevision, "outcome": receipt.outcome.rawValue,
                "authority_state": mcpStore.authorityState.rawValue,
                "runtime_admitted": MCPStore.productionSDKAdmitted,
                "status": mcpStore.status(for: serverID).displayText]
            if let action = receipt.action { item["action"] = action }
            if receipt.recoveryPending == true { item["recovery_pending"] = true }
            if let safeError = receipt.safeError { item["error"] = safeError }
            switch receipt.outcome {
            case .pending: item["next_action"] = "Limare is waiting for the user in its own window; read status with this operation_id later. Do not repeat the request."
            case .notCommitted: item["next_action"] = "Nothing changed. A new attempt needs a new request_id."
            case .outcomeUnknown: item["next_action"] = "The result is unknown; read status before deciding."
            case .committed: item["next_action"] = mcpStore.authorityState != .ready ? mcpStore.authorityState.message
                : (receipt.action == nil && !mcpStore.servers.contains(where: { $0.id == serverID }) ? "Removed." : mcpStore.nextAction(for: serverID))
            }
            let payload = jsonString(item)
            let isError = receipt.outcome == .notCommitted
            onUpdate(.init(state: isError ? .failed : .completed, approvalState: approval, output: payload))
            return .init(content: payload, isError: isError, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
        }
        guard !SecretMasker.containsCredential(serverID) else {
            throw ToolExecutorError.invalidArguments("MCP server IDs must not contain credentials.")
        }

        switch action {
        case "list":
            let list = mcpStore.servers.map { s in
                [
                    "server_id": s.id,
                    "transport": s.transportType.rawValue,
                    "enabled": s.enabled,
                    "status": mcpStore.status(for: s.id).displayText,
                    "tool_count": mcpStore.tools(for: s.id).count,
                    "next_action": mcpStore.nextAction(for: s.id)
                ]
            }
            let payload = jsonString(["servers": list, "count": list.count, "authority_state": mcpStore.authorityState.rawValue,
                                      "configuration_revision": mcpStore.configurationRevision,
                                      "next_action": mcpStore.authorityState == .ready ? "none" : mcpStore.authorityState.message])
            onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
            return .init(content: payload, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: startedAt))

        case "status":
            guard let server = try requireServer() else { return failure("MCP server '\(serverID)' not found.") }
            let stat = mcpStore.status(for: serverID)
            let tools = mcpStore.tools(for: serverID).map(\.name)
            var item: [String: Any] = [
                "server_id": server.id,
                "transport": server.transportType.rawValue,
                "enabled": server.enabled,
                "status": stat.displayText,
                "tool_count": tools.count,
                "tools": tools
            ]
            if case .failed(let msg, _) = stat {
                item["error"] = msg
            }
            let projection = mcpStore.runtimeProjection(for: serverID)
            item["transport_state"] = projection.transport
            item["auth_state"] = projection.auth
            item["identity_state"] = projection.identity
            if let missing = mcpStore.missingCredentials[serverID], !missing.isEmpty { item["missing_credentials"] = missing }
            item["next_action"] = mcpStore.nextAction(for: serverID)
            if server.requiresReview { item["quarantined_fields"] = server.quarantinedFields ?? [] }
            item["configuration_revision"] = mcpStore.configurationRevision
            item["authority_state"] = mcpStore.authorityState.rawValue
            // Host receipts let a later turn learn the outcome without repeating an action.
            item["operations"] = mcpStore.operationReceipts.filter { $0.serverID == serverID }.suffix(5).compactMap { receipt in
                mcpStore.reportedReceipt(receipt.id).map { r -> [String: Any] in
                    var entry: [String: Any] = ["operation_id": r.id.uuidString, "action": r.action ?? "configuration", "outcome": r.outcome.rawValue]
                    if let safeError = r.safeError { entry["error"] = safeError }
                    return entry
                }
            }
            let payload = jsonString(item)
            onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
            return .init(content: payload, isError: false, approvalState: .notRequired, durationMilliseconds: milliseconds(since: startedAt))

        case "create":
            guard !serverID.isEmpty else { throw ToolExecutorError.invalidArguments("server_id is required for create.") }
            let (revision, id) = try mutationIdentity()
            var config: MCPServerConfig
            if let name = args.profile {
                guard let profile = MCPServerProfile(rawValue: name) else {
                    throw ToolExecutorError.invalidArguments("Unknown MCP profile. Supported: \(MCPServerProfile.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                guard args.transport == nil, args.url == nil, args.command == nil, args.args == nil else {
                    throw ToolExecutorError.invalidArguments("A profile fixes the transport and endpoint; omit transport, url, command and args.")
                }
                config = profile.configuration(id: serverID)
            } else {
                switch args.transport {
                case "http":
                    guard let url = args.url, args.command == nil, args.args == nil else {
                        throw ToolExecutorError.invalidArguments("create with transport http requires url and no command.")
                    }
                    config = MCPServerConfig(id: serverID, url: url)
                case "stdio":
                    guard let command = args.command, args.url == nil else {
                        throw ToolExecutorError.invalidArguments("create with transport stdio requires command and no url.")
                    }
                    config = MCPServerConfig(id: serverID, command: command, args: args.args)
                default:
                    throw ToolExecutorError.invalidArguments("create requires transport http or stdio, or a profile.")
                }
            }
            config.enabled = true
            // A local server is a program Limare will run, so its creation is approved like a command.
            let approval = await authorize(ToolPermissionRequest(
                toolName: "mcp_manage",
                summary: "Create MCP server '\(serverID)': \(config.transportSummary)",
                workspaceURL: workspace.url,
                affectedURLs: [],
                command: config.isSTDIO ? config.transportSummary : nil,
                environmentKeys: [],
                requestsNetwork: config.isHTTP,
                isHighRisk: config.isSTDIO
            ), onUpdate: onUpdate)
            guard approval != .denied else { return deniedOutcome() }
            let receipt = try mcpStore.applyManagementMutation(action: "create", serverID: serverID,
                expectedRevision: revision, requestID: id, config: config)
            return mutationOutcome(receipt, approval: approval)

        case "patch":
            guard !serverID.isEmpty else { throw ToolExecutorError.invalidArguments("server_id is required for patch.") }
            let (revision, id) = try mutationIdentity()
            let patch = MCPConfigurationPatch(set: args.set ?? [:], remove: args.remove ?? [])
            guard !patch.set.isEmpty || !patch.remove.isEmpty else {
                throw ToolExecutorError.invalidArguments("patch requires set or remove.")
            }
            let touchesExecution = patch.set.keys.contains { ["command", "args", "env"].contains($0) }
            let approval = await authorize(ToolPermissionRequest(
                toolName: "mcp_manage",
                summary: "Change MCP server '\(serverID)': \((Array(patch.set.keys) + patch.remove.map { "remove \($0)" }).sorted().joined(separator: ", "))",
                workspaceURL: workspace.url,
                affectedURLs: [],
                command: nil,
                environmentKeys: [],
                requestsNetwork: patch.set.keys.contains("url"),
                isHighRisk: touchesExecution
            ), onUpdate: onUpdate)
            guard approval != .denied else { return deniedOutcome() }
            let receipt = try mcpStore.applyManagementMutation(action: "patch", serverID: serverID,
                expectedRevision: revision, requestID: id, patch: patch)
            return mutationOutcome(receipt, approval: approval)

        case "remove", "enable", "disable":
            guard !serverID.isEmpty else { throw ToolExecutorError.invalidArguments("server_id is required.") }
            let (revision, id) = try mutationIdentity()
            let approval = await permission("\(action.capitalized) MCP configuration", network: false)
            guard approval != .denied else { return deniedOutcome() }
            let receipt = try mcpStore.applyManagementMutation(action: action, serverID: serverID,
                expectedRevision: revision, requestID: id)
            return mutationOutcome(receipt, approval: approval)

        case "reconnect", "authenticate", "logout":
            let (revision, id) = try mutationIdentity()
            guard let server = try requireServer() else { return failure("MCP server '\(serverID)' not found.") }
            do { try mcpStore.validateRuntimeAction(action, serverID: serverID) }
            catch { return failure(error.localizedDescription) }
            let summary = ["reconnect": "Reconnect", "authenticate": "Sign in to", "logout": "Sign out of"][action]!
            let approval = await permission("\(summary) MCP server '\(serverID)'", network: server.isHTTP)
            guard approval != .denied else { return deniedOutcome() }
            // Authentication runs as a Host-owned operation; the receipt survives a provider failure.
            let receipt = try await mcpStore.performRuntimeAction(action, serverID: serverID,
                expectedRevision: revision, requestID: id)
            return mutationOutcome(receipt, approval: approval)

        default:
            throw ToolExecutorError.invalidArguments("Supported actions: \(HarnessToolDefinitions.mcpManageActions.joined(separator: ", ")).")
        }
    }

    // MARK: - schedule_manage

    private struct ScheduleManageArguments: Decodable {
        let action: String
        let task_id: String?
        let name: String?
        let prompt: String?
        let `repeat`: String?
        let time: String?
        let weekdays: String?
        let interval_hours: Int?
        let day_of_month: Int?
        let fire_at: String?
        let target: String?
        let enabled: Bool?
        let notify: String?

        var changesSchedule: Bool {
            `repeat` != nil || time != nil || weekdays != nil || interval_hours != nil || day_of_month != nil || fire_at != nil
        }
    }

    /// The model's side of the Schedules page: the same tasks, rules and scheduler calls as the editor.
    private func executeScheduleManage(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard let scheduler, subagentBinding == nil else { throw ToolExecutorError.unknownTool("schedule_manage") }
        let startedAt = ContinuousClock.now
        if let raw = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] {
            let unknown = Set(raw.keys).subtracting(HarnessToolDefinitions.scheduleManageProperties.keys).sorted()
            guard unknown.isEmpty else {
                throw ToolExecutorError.invalidArguments("Unsupported field on schedule_manage: \(unknown.joined(separator: ", ")).")
            }
        }
        let args: ScheduleManageArguments = try decode(call)
        let action = args.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let conversationID = activeConversationIDProvider?()

        func completed(_ payload: [String: Any], approval: ToolApprovalState) -> ToolExecutionOutcome {
            let content = jsonString(payload)
            onUpdate(.init(state: .completed, approvalState: approval, output: content))
            return .init(content: content, isError: false, approvalState: approval, durationMilliseconds: milliseconds(since: startedAt))
        }
        func approve(_ summary: String) async -> ToolApprovalState {
            await authorize(ToolPermissionRequest(
                toolName: "schedule_manage",
                summary: summary,
                workspaceURL: workspace.url,
                affectedURLs: [],
                command: nil,
                environmentKeys: [],
                requestsNetwork: false,
                isHighRisk: false
            ), onUpdate: onUpdate)
        }
        func existingTask() throws -> ScheduledTask {
            guard let raw = args.task_id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                throw ToolExecutorError.invalidArguments("task_id is required for \(action); read it with list.")
            }
            guard let id = UUID(uuidString: raw), let task = scheduler.store.task(id: id) else {
                throw ToolExecutorError.invalidArguments("No scheduled task has id \(raw); read the ids with list.")
            }
            return task
        }
        func target(_ raw: String) throws -> ScheduledTask.Target {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "new_conversation":
                return .newConversation(projectID: conversationID.flatMap { scheduler.projectID(ofConversation: $0) })
            case "this_conversation":
                guard let conversationID else { throw ToolExecutorError.invalidArguments("this_conversation needs a conversation; use new_conversation.") }
                return .conversation(id: conversationID)
            default:
                throw ToolExecutorError.invalidArguments("target must be new_conversation or this_conversation.")
            }
        }
        func notify(_ raw: String) throws -> ScheduledTask.NotifyOn {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "completion_and_failure": return .completionAndFailure
            case "failure_only": return .failureOnly
            default: throw ToolExecutorError.invalidArguments("notify must be completion_and_failure or failure_only.")
            }
        }

        switch action {
        case "list":
            let tasks = scheduler.store.tasks.map { scheduleDescription($0, scheduler: scheduler, conversationID: conversationID) }
            return completed(["tasks": tasks, "count": tasks.count], approval: .notRequired)

        case "create":
            guard let prompt = args.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolExecutorError.invalidArguments("prompt is required for create.")
            }
            guard args.repeat != nil else {
                throw ToolExecutorError.invalidArguments("repeat is required for create: once, daily, weekdays, weekly, every_n_hours or monthly.")
            }
            let timeZoneID = TimeZone.current.identifier
            var task = ScheduledTask(
                name: args.name ?? "",
                prompt: prompt,
                schedule: try Self.schedule(args, base: ScheduledRuleDraft(), timeZoneID: timeZoneID),
                timeZoneID: timeZoneID,
                target: try target(args.target ?? "new_conversation")
            )
            if let raw = args.notify { task.notifyOn = try notify(raw) }
            if let enabled = args.enabled { task.isEnabled = enabled }
            let approval = await approve("Create scheduled task '\(task.name.isEmpty ? String(prompt.prefix(40)) : task.name)'")
            guard approval != .denied else { return deniedOutcome() }
            let created = try scheduler.create(task)
            return completed(["task": scheduleDescription(created, scheduler: scheduler, conversationID: conversationID)], approval: approval)

        case "update":
            var task = try existingTask()
            if let name = args.name { task.name = name }
            if let prompt = args.prompt { task.prompt = prompt }
            if args.changesSchedule {
                task.schedule = try Self.schedule(args, base: ScheduledRuleDraft(schedule: task.schedule), timeZoneID: task.timeZoneID)
            }
            if let raw = args.target { task.target = try target(raw) }
            if let raw = args.notify { task.notifyOn = try notify(raw) }
            if let enabled = args.enabled { task.isEnabled = enabled }
            let approval = await approve("Change scheduled task '\(task.name)'")
            guard approval != .denied else { return deniedOutcome() }
            let updated = try scheduler.update(task)
            return completed(["task": scheduleDescription(updated, scheduler: scheduler, conversationID: conversationID)], approval: approval)

        case "delete":
            let task = try existingTask()
            let approval = await approve("Delete scheduled task '\(task.name)'")
            guard approval != .denied else { return deniedOutcome() }
            try scheduler.delete(taskID: task.id)
            return completed(["deleted": task.id.uuidString, "name": task.name], approval: approval)

        case "run_now":
            let task = try existingTask()
            let approval = await approve("Run scheduled task '\(task.name)' now")
            guard approval != .denied else { return deniedOutcome() }
            do {
                try scheduler.runNow(taskID: task.id)
            } catch let refusal as ScheduledScheduler.ManualRunRefusal {
                switch refusal {
                case .anotherRunActive: throw ToolExecutorError.invalidArguments("Another scheduled run is in progress; try again after it ends.")
                case .taskNotFound: throw ToolExecutorError.invalidArguments("No scheduled task has id \(task.id.uuidString).")
                case .notReadable: throw ToolExecutorError.invalidArguments("Scheduling is paused because the schedules file could not be read; the user can see why in Schedules.")
                }
            }
            return completed(["task": scheduleDescription(task, scheduler: scheduler, conversationID: conversationID)], approval: approval)

        default:
            throw ToolExecutorError.invalidArguments("action must be one of: list, create, update, delete, run_now.")
        }
    }

    /// What the model reads about a task: the rule in the words the Schedules page shows, and times
    /// in the task's own time zone.
    private func scheduleDescription(_ task: ScheduledTask, scheduler: ScheduledScheduler, conversationID: UUID?) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: task.timeZoneID) ?? .current
        var item: [String: Any] = [
            "task_id": task.id.uuidString,
            "name": task.name,
            "prompt": task.prompt,
            "rule": ScheduledRuleDraft(schedule: task.schedule).summary(timeZoneID: task.timeZoneID),
            "enabled": task.isEnabled,
            "notify": task.notifyOn == .failureOnly ? "failure_only" : "completion_and_failure",
            "next_run": task.nextNominalAt.map { formatter.string(from: $0) } ?? "none",
        ]
        switch task.target {
        case .newConversation: item["target"] = "new_conversation"
        case .conversation(let id): item["target"] = id == conversationID ? "this_conversation" : "conversation \(id.uuidString)"
        }
        if let run = scheduler.store.runs(for: task.id).first {
            var last: [String: Any] = ["status": run.status.rawValue, "at": formatter.string(from: run.finishedAt ?? run.claimedAt)]
            if let reason = run.skipReason { last["skip_reason"] = reason.rawValue }
            item["last_run"] = last
        }
        return item
    }

    /// Builds a rule the editor can show and edit: the given fields over `base`.
    private static func schedule(_ args: ScheduleManageArguments, base: ScheduledRuleDraft, timeZoneID: String) throws -> ScheduledTask.Schedule {
        var draft = base
        if let raw = args.repeat {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "once": draft.kind = .once
            case "daily": draft.kind = .daily
            case "weekdays": draft.kind = .weekdays
            case "weekly": draft.kind = .weekly
            case "every_n_hours": draft.kind = .everyNHours
            case "monthly": draft.kind = .monthly
            default: throw ToolExecutorError.invalidArguments("repeat must be once, daily, weekdays, weekly, every_n_hours or monthly.")
            }
        }
        if let raw = args.time {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour), (0...59).contains(minute) else {
                throw ToolExecutorError.invalidArguments("time must be HH:mm, e.g. 09:00.")
            }
            draft.hour = hour
            draft.minute = minute
        }
        if let raw = args.weekdays {
            let numbers: [String: Int] = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
            let days = try raw.split(separator: ",").map { token -> Int in
                guard let day = numbers[String(token.trimmingCharacters(in: .whitespaces).lowercased().prefix(3))] else {
                    throw ToolExecutorError.invalidArguments("weekdays takes mon, tue, wed, thu, fri, sat, sun.")
                }
                return day
            }
            guard !days.isEmpty else { throw ToolExecutorError.invalidArguments("weekdays is empty.") }
            draft.weekdays = Set(days)
        } else if draft.kind == .weekly, base.kind != .weekly {
            throw ToolExecutorError.invalidArguments("weekly needs weekdays, e.g. \"mon,wed,fri\".")
        }
        if let hours = args.interval_hours {
            guard (1...24).contains(hours) else { throw ToolExecutorError.invalidArguments("interval_hours must be 1 to 24.") }
            draft.intervalHours = hours
        }
        if let day = args.day_of_month {
            guard (1...31).contains(day) else { throw ToolExecutorError.invalidArguments("day_of_month must be 1 to 31.") }
            draft.dayOfMonth = day
        }
        if let raw = args.fire_at {
            guard let date = scheduleDate(raw, timeZoneID: timeZoneID) else {
                throw ToolExecutorError.invalidArguments("fire_at must be ISO 8601, e.g. 2026-10-24T15:30:00+08:00.")
            }
            draft.fireAt = date
        } else if draft.kind == .once, base.kind != .once {
            throw ToolExecutorError.invalidArguments("once needs fire_at.")
        }
        return draft.schedule(timeZoneID: timeZoneID)
    }

    /// ISO 8601 with an offset; a time without one is read in the task's time zone.
    private static func scheduleDate(_ raw: String, timeZoneID: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    private func authorize(
        _ request: ToolPermissionRequest,
        allowedReadDirectories: [URL] = [],
        onUpdate: @escaping UpdateHandler
    ) async -> ToolApprovalState {
        let scopedRequest: ToolPermissionRequest
        if let scope = hookExecutionScope {
            scopedRequest = request.attributed(
                conversationID: scope.conversationID,
                runID: scope.runID,
                conversationTitle: scope.conversationTitle
            )
        } else {
            scopedRequest = request
        }
        if permissions.mode != .fullAccess, case .requiresApproval = PermissionEvaluator.evaluate(scopedRequest, allowedReadDirectories: allowedReadDirectories, memoryLocations: memoryLocations()) {
            onUpdate(.init(state: .awaitingApproval, approvalState: .awaitingApproval, output: ""))
        }
        let turnReviewer = TurnReviewContext.activeReviewer
        let result = await permissions.authorize(scopedRequest, allowedReadDirectories: allowedReadDirectories, memoryLocations: memoryLocations(), reviewer: turnReviewer)
        if result == .denied {
            // Read by deniedOutcome() right after this returns, with no suspension in between.
            lastDenialReason = permissions.takeDenialReason(requestID: scopedRequest.requestID)
            onUpdate(.init(state: .denied, approvalState: .denied, output: lastDenialReason ?? "Permission denied."))
        }
        return result
    }

    func cancelPendingApprovalsForScope() {
        guard let scope = hookExecutionScope else { return }
        permissions.cancelQueuedApprovals(conversationID: scope.conversationID, runID: scope.runID)
        userQuestions?.cancel(conversationID: scope.conversationID, runID: scope.runID)
    }

    private var lastDenialReason: String?

    private func deniedOutcome() -> ToolExecutionOutcome {
        let reason = lastDenialReason ?? "Permission denied."
        lastDenialReason = nil
        return .init(content: jsonString(["error": reason]), isError: true, approvalState: .denied, durationMilliseconds: 0)
    }

    private func fileContext(path: String, mustExist: Bool) throws -> FileContext {
        let workspaceURL = workspace.url ?? FileManager.default.temporaryDirectory
        let url = try WorkspacePathResolver.resolve(path, relativeTo: workspaceURL, mustExist: mustExist)
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: url)
        return FileContext(url: url, workspaceURL: workspace.url ?? workspaceURL, displayPath: url.path)
    }

    private func decode<T: Decodable>(_ call: ProviderToolCall) throws -> T {
        guard let data = call.function.arguments.data(using: .utf8) else {
            throw ToolExecutorError.invalidArguments("Arguments are not UTF-8.")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if call.isTruncatedByOutputLimit {
                throw ToolExecutorError.invalidArguments(call.outputLimitTruncationMessage)
            }
            throw ToolExecutorError.invalidArguments(Self.argumentDecodingFailure(error, data: data))
        }
    }

    /// Well-formed JSON that does not fit the tool's schema names the field, as Claude Code's
    /// input validation does; only a syntax failure is reported as malformed JSON.
    nonisolated static func argumentDecodingFailure(_ error: Error, data: Data) -> String {
        func path(_ codingPath: [CodingKey], appending key: CodingKey? = nil) -> String {
            let keys = codingPath + (key.map { [$0] } ?? [])
            return keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                .joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
        }
        func received() -> String {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
            let keys = object.keys.sorted()
            return keys.isEmpty ? " No arguments were received." : " Received arguments: \(keys.joined(separator: ", "))."
        }
        guard let decodingError = error as? DecodingError else {
            return "Tool call arguments are malformed or incomplete JSON: \(error.localizedDescription)"
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "Missing required argument '\(path(context.codingPath, appending: key))'." + received()
        case .typeMismatch(_, let context) where context.codingPath.isEmpty,
             .valueNotFound(_, let context) where context.codingPath.isEmpty:
            return "Tool call arguments must be a JSON object."
        case .typeMismatch(let type, let context):
            return "Argument '\(path(context.codingPath))' must be of type \(type)." + received()
        case .valueNotFound(let type, let context):
            return "Argument '\(path(context.codingPath))' must be a non-null \(type)." + received()
        case .dataCorrupted(let context):
            if context.codingPath.isEmpty {
                return "Tool call arguments are malformed or incomplete JSON: \(error.localizedDescription)"
            }
            return "Argument '\(path(context.codingPath))' is invalid: \(context.debugDescription)"
        @unknown default:
            return "Tool call arguments are malformed or incomplete JSON: \(error.localizedDescription)"
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1_000) + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }

    private func bounded(_ text: String, maximumBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maximumBytes else { return text }
        let half = maximumBytes / 2
        return String(decoding: data.prefix(half), as: UTF8.self)
            + "\n… output truncated for model context …\n"
            + String(decoding: data.suffix(half), as: UTF8.self)
    }

    private func sanitizedShellText(_ text: String, masking secrets: [String]) -> String {
        let withoutControls = stripTerminalControls(text)
        let normalized = withoutControls.replacingOccurrences(of: "\r\n", with: "\n")
        let folded = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            }
            .joined(separator: "\n")
        return SecretMasker.redact(folded, secrets: secrets)
    }

    private func stripTerminalControls(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result: [UnicodeScalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let introducer = scalars[index + 1].value
                if introducer == 0x5B {
                    index += 2
                    while index < scalars.count {
                        let candidate = scalars[index].value
                        index += 1
                        if (0x40...0x7E).contains(candidate) { break }
                    }
                    continue
                }
                if introducer == 0x5D {
                    index += 2
                    while index < scalars.count {
                        if scalars[index].value == 0x07 {
                            index += 1
                            break
                        }
                        if scalars[index].value == 0x1B,
                           index + 1 < scalars.count,
                           scalars[index + 1].value == 0x5C {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
                index += 2
                continue
            }
            if value < 0x20, value != 0x09, value != 0x0A, value != 0x0D {
                index += 1
                continue
            }
            result.append(scalars[index])
            index += 1
        }
        return String(String.UnicodeScalarView(result))
    }

    private func executeAttachmentCopy(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let workspaceURL = workspace.url ?? FileManager.default.temporaryDirectory

        let arguments: AttachmentCopyArguments = try decode(call)
        let sourceURI = arguments.source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceURI.hasPrefix("limare://attachments/") else {
            throw AttachmentCopyError.invalidSourceURI(sourceURI)
        }

        // 1. Resolve and validate attachment source URL
        let sourceURL: URL
        do {
            sourceURL = try attachmentStore.fileURL(forAttachmentURI: sourceURI)
        } catch {
            throw AttachmentCopyError.invalidSourceURI(sourceURI)
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw AttachmentCopyError.attachmentNotFound(sourceURI)
        }
        let sourceValues = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard sourceValues?.isRegularFile == true else {
            throw AttachmentCopyError.attachmentNotFound(sourceURI)
        }

        // 2. Resolve destination path
        let rawDest = arguments.destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeFilename: String
        if let original = attachmentStore.originalFilename(forURI: sourceURI) {
            safeFilename = sanitizeFilename(original)
        } else {
            let diskName = String(sourceURI.dropFirst("limare://attachments/".count))
            safeFilename = sanitizeFilename(diskName)
        }

        let relativeDestination: String
        if let rawDest, !rawDest.isEmpty {
            guard !rawDest.hasPrefix("/"), !rawDest.hasPrefix("~") else {
                throw AttachmentCopyError.absoluteDestinationNotAllowed(rawDest)
            }
            if rawDest.hasSuffix("/") {
                relativeDestination = (rawDest as NSString).appendingPathComponent(safeFilename)
            } else {
                relativeDestination = rawDest
            }
        } else {
            relativeDestination = ".limare-input/\(safeFilename)"
        }

        // 3. Workspace containment & symlink escape checks for destination
        let candidateURL = workspaceURL.appendingPathComponent(relativeDestination).standardizedFileURL
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: candidateURL)
        guard WorkspacePathResolver.isInsideWorkspace(candidateURL, workspaceURL: workspaceURL) else {
            throw AttachmentCopyError.destinationOutsideWorkspace(relativeDestination)
        }

        var ancestor = candidateURL.deletingLastPathComponent()
        let workspaceRoot = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: ancestor.path) && ancestor.path != workspaceRoot.path && ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
        guard WorkspacePathResolver.isInsideWorkspace(resolvedAncestor, workspaceURL: workspaceURL) else {
            throw AttachmentCopyError.destinationOutsideWorkspace(relativeDestination)
        }

        if FileManager.default.fileExists(atPath: candidateURL.path) {
            let resolvedTarget = candidateURL.resolvingSymlinksInPath().standardizedFileURL
            guard WorkspacePathResolver.isInsideWorkspace(resolvedTarget, workspaceURL: workspaceURL) else {
                throw AttachmentCopyError.destinationOutsideWorkspace(relativeDestination)
            }
            throw AttachmentCopyError.destinationAlreadyExists(relativeDestination)
        }

        // 4. Authorize via permission system
        let request = ToolPermissionRequest(
            toolName: call.function.name,
            summary: "Copy attachment to \(candidateURL.path)",
            workspaceURL: workspace.url,
            affectedURLs: [candidateURL],
            command: nil,
            environmentKeys: [],
            requestsNetwork: false,
            isHighRisk: PermissionEvaluator.isSensitivePath(candidateURL)
        )
        let approval = await authorize(request, onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        onUpdate(.init(state: .running, approvalState: approval, output: ""))
        let startedAt = ContinuousClock.now

        // 5. Create intermediate directories and copy item
        try recordedWrite(candidateURL, call: call) { location in
            if let location {
                let source = open(sourceURL.path, O_RDONLY | O_CLOEXEC)
                guard source >= 0 else { throw AttachmentCopyError.copyFailed(String(cString: strerror(errno))) }
                defer { close(source) }
                if (try? AnchoredFileSystem.status(location)) != nil {
                    throw AttachmentCopyError.destinationAlreadyExists(relativeDestination)
                }
                try AnchoredFileSystem.copyFile(from: source, to: location, mode: 0o644)
                return
            }
            let parentDir = candidateURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try FileManager.default.copyItem(at: sourceURL, to: candidateURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: candidateURL.path)
        }

        // 6. Gather metadata and return
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: candidateURL.path)
        let size = (fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
        let classification = AttachmentClassifier.classify(url: candidateURL)

        let targetResolvedPath = candidateURL.standardizedFileURL.resolvingSymlinksInPath().path
        let finalRelativePath: String
        if targetResolvedPath.hasPrefix(workspaceRoot.path + "/") {
            finalRelativePath = String(targetResolvedPath.dropFirst(workspaceRoot.path.count + 1))
        } else {
            finalRelativePath = relativeDestination
        }

        let payload: [String: Any] = [
            "path": finalRelativePath,
            "size": size,
            "mime_type": classification.mimeType,
            "source": sourceURI
        ]
        let output = jsonString(payload)
        onUpdate(.init(state: .completed, approvalState: approval, output: output))
        logs.info("Tool", "Copied attachment \(sourceURI) to \(finalRelativePath) (\(size) bytes).")

        return ToolExecutionOutcome(
            content: output,
            isError: false,
            approvalState: approval,
            durationMilliseconds: milliseconds(since: startedAt)
        )
    }

    /// Provider-neutral, representation-based conversion consumer.
    ///
    /// The model expresses only *which conversation resource* it wants and *which
    /// representation* it wants back. Converter identity, route priority,
    /// retention class, representation profile, and attempt control stay inside
    /// the single immutable resolver composition the executor was built with.
    ///
    /// The result must be a genuinely materialized derived artifact that was
    /// reopened from canonical Artifact Authority; a source that already
    /// satisfies the request is reported truthfully as requiring no conversion
    /// rather than being turned into a meaningless artifact.
    private func executeResourceConvert(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let startedAt = ContinuousClock.now
        let arguments: ResourceConvertArguments = try decode(call)
        let sourceURI = arguments.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetMIME = arguments.targetMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID else {
            throw ToolExecutorError.invalidArguments("No active conversation scope available for resource conversion.")
        }
        guard let resolver = representationResolver, let store = artifactStore else {
            throw ToolExecutorError.invalidArguments("Representation conversion is not configured in this runtime.")
        }
        guard let policies = resourceConversionPolicies else {
            throw ToolExecutorError.invalidArguments("Resource conversion consumer policies are not configured in this runtime.")
        }
        let ref: ResourceRef
        let admission: AttachmentResourceAdmission?
        if sourceURI.hasPrefix("limare://attachments/") {
            guard let canonicalMessages = canonicalMessageResolver?(convID),
                  let admitted = AttachmentResourceAdmission.admit(
                    sourceURI: sourceURI, conversationID: convID, canonicalMessages: canonicalMessages
                  ) else {
                let payload = jsonString(["status": "denied", "source": sourceURI,
                                          "reason": "Attachment is not owned by this conversation's canonical history.", "is_error": true] as [String: Any])
                onUpdate(.init(state: .denied, approvalState: .notRequired, output: payload))
                return ToolExecutionOutcome(content: payload, isError: true, approvalState: .notRequired,
                                            durationMilliseconds: milliseconds(since: startedAt))
            }
            admission = admitted
            ref = ResourceRef.attachment(admitted.attachment, conversationID: convID)
        } else if let artifactID = Self.artifactUUID(from: sourceURI) {
            // Descriptor lookup is an Artifact Authority scope/retention check;
            // ResourceResolver performs the canonical integrity-checked byte read.
            let descriptor: ArtifactDescriptor
            do {
                descriptor = try store.resolveDescriptor(artifactID: artifactID, conversationID: convID)
            } catch {
                let status: String
                switch error {
                case ArtifactStoreError.artifactNotFound, ArtifactStoreError.fileMissing: status = "missing"
                case ArtifactStoreError.fileExpired: status = "expired"
                case ArtifactStoreError.unauthorizedAccess: status = "denied"
                case ArtifactStoreError.integrityMismatch: status = "integrity_mismatch"
                default: status = "failed"
                }
                let payload = jsonString(["status": status, "source": sourceURI,
                                          "reason": error.localizedDescription, "is_error": true] as [String: Any])
                onUpdate(.init(state: status == "denied" ? .denied : .failed, approvalState: .notRequired, output: payload))
                return ToolExecutionOutcome(content: payload, isError: true, approvalState: .notRequired,
                                            durationMilliseconds: milliseconds(since: startedAt))
            }
            admission = nil
            ref = ResourceRef.artifact(
                artifactRef: ArtifactRef(artifactID: artifactID, conversationID: convID),
                mimeType: descriptor.mimeType, filename: descriptor.filename
            )
        } else {
            return unsupportedResourceConversion(
                reason: "Source is not a supported conversation resource URI.", source: sourceURI,
                targetMIME: targetMIME, onUpdate: onUpdate, startedAt: startedAt
            )
        }

        // The source representation comes from canonical attachment identity or
        // an Artifact Authority descriptor. The injected policy composition answers
        // the one question this tool is allowed to ask: which immutable
        // requirement applies to this exact source/target pair. Zero matches is
        // truthfully unsupported, and more than one match fails closed. Converter
        // identity, route priority and profile semantics stay generic, and this
        // executor still knows no concrete format.
        let sourceMIME = ref.representationHint?.mimeType ?? "application/octet-stream"
        let policy: ResourceConversionConsumerPolicy
        switch policies.select(sourceMIME: sourceMIME, targetMIME: targetMIME) {
        case .matched(let selectedPolicy):
            policy = selectedPolicy
        case .unsupported(let reason):
            return unsupportedResourceConversion(
                reason: "\(reason) This operation requires a real materialized conversion and does not create an artifact for a source that needs no conversion.",
                source: sourceURI,
                targetMIME: targetMIME,
                onUpdate: onUpdate,
                startedAt: startedAt
            )
        case .ambiguous(let reason):
            return ambiguousResourceConversion(
                reason: reason,
                source: sourceURI,
                targetMIME: targetMIME,
                onUpdate: onUpdate,
                startedAt: startedAt
            )
        }

        let requirement = policy.requirement

        onUpdate(.init(state: .running, approvalState: .notRequired, output: "Converting \(sourceURI) to \(targetMIME)..."))

        let result = await resolver.resolve(
            ref: ref,
            requirement: requirement,
            in: workspace.url,
            artifactStore: store,
            requestingConversationID: convID,
            targetConversationID: convID,
            retentionClass: policy.retentionClass,
            retentionIntent: .materialized(retentionClass: policy.retentionClass),
            attachmentStore: attachmentStore,
            attachmentAdmission: admission
        )

        let attempt = result.attempt

        if case .cancelled = result {
            throw CancellationError()
        }

        guard case .converted(let artifactRef, let descriptor, let convertedAttempt) = result else {
            let reason = attempt.failureReason ?? "Representation conversion did not produce a derived artifact."
            let payload = jsonString([
                "status": attempt.terminalState.rawValue,
                "source": sourceURI,
                "target_mime": targetMIME,
                "reason": reason,
                "is_error": true
            ])
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
            logs.info("Tool", "resource_convert \(attempt.terminalState.rawValue) for '\(sourceURI)': \(reason)")
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: milliseconds(since: startedAt)
            )
        }

        // Canonical reopen: the derived artifact is reopened from Artifact
        // Authority with integrity verification. Converter-local memory is never
        // projected to the model directly.
        var reopenedData: Data?
        do {
            reopenedData = try store.loadData(
                artifactID: artifactRef.artifactID,
                conversationID: convID,
                verifyIntegrity: true
            )
        } catch {
            reopenedData = nil
        }
        let reopened = reopenedData != nil
        let reopenedByteCount = reopenedData?.count ?? 0

        let fact = ToolMechanicalTerminalFact.representationArtifact(
            sourceRef: ref,
            artifactRef: artifactRef,
            attemptID: convertedAttempt.attemptID,
            materialized: true,
            reopened: reopened
        )

        guard let reopenedData else {
            let payload = jsonString([
                "status": "reopen_failed",
                "source": sourceURI,
                "artifact_id": artifactRef.artifactID.uuidString,
                "reason": "The derived artifact was materialized but could not be reopened from canonical Artifact Authority.",
                "is_error": true
            ])
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
            logs.error("Tool", "resource_convert materialized artifact '\(artifactRef.artifactID)' but canonical reopen failed.")
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: milliseconds(since: startedAt),
                mechanicalTerminalFact: fact
            )
        }

        // Bounded, mechanical result: artifact identity and real conversion
        // metadata. Text policies add reopened text; Artifact policies add only
        // a typed result part. No base64, interpretation or duplicated payload.
        var payloadFields: [String: Any] = [
            "status": "converted",
            "source": sourceURI,
            "artifact_id": artifactRef.artifactID.uuidString,
            "mime_type": descriptor.mimeType,
            "byte_count": reopenedByteCount,
            "converter_id": attempt.selectedConverterID ?? "",
            "selected_route": attempt.selectedRoute?.routeID ?? "",
            "attempt_id": convertedAttempt.attemptID.uuidString
        ]
        let resultParts: [ToolResultPart]
        switch policy.resultProjection {
        case .text:
            guard let reopenedText = String(data: reopenedData, encoding: .utf8) else {
                let failure = jsonString(["status": "projection_failed", "source": sourceURI,
                                          "artifact_id": artifactRef.artifactID.uuidString,
                                          "reason": "Derived text is not valid UTF-8.", "is_error": true] as [String: Any])
                onUpdate(.init(state: .failed, approvalState: .notRequired, output: failure))
                return ToolExecutionOutcome(content: failure, isError: true, approvalState: .notRequired,
                                            durationMilliseconds: milliseconds(since: startedAt), mechanicalTerminalFact: fact)
            }
            payloadFields["text"] = reopenedText
            resultParts = [.text(reopenedText), .artifact(id: artifactRef.artifactID,
                                                          semanticRole: .unspecified, mimeType: descriptor.mimeType)]
        case .artifact(let role):
            resultParts = [.artifact(id: artifactRef.artifactID, semanticRole: role, mimeType: descriptor.mimeType)]
        }
        let payload = jsonString(payloadFields)
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
        logs.info("Tool", "resource_convert produced artifact '\(artifactRef.artifactID)' (\(reopenedByteCount) bytes) from '\(sourceURI)'.")

        return ToolExecutionOutcome(
            content: payload,
            isError: false,
            approvalState: .notRequired,
            durationMilliseconds: milliseconds(since: startedAt),
            resultParts: resultParts,
            mechanicalTerminalFact: fact
        )
    }

    private func unsupportedResourceConversion(
        reason: String,
        source: String,
        targetMIME: String,
        onUpdate: @escaping UpdateHandler,
        startedAt: ContinuousClock.Instant
    ) -> ToolExecutionOutcome {
        let payload = jsonString([
            "status": "unsupported",
            "source": source,
            "target_mime": targetMIME,
            "reason": reason,
            "is_error": true
        ])
        onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
        return ToolExecutionOutcome(
            content: payload,
            isError: true,
            approvalState: .notRequired,
            durationMilliseconds: milliseconds(since: startedAt)
        )
    }

    /// Fail closed when the immutable consumer-policy composition cannot name
    /// exactly one requirement for a source/target pair. Array order is never
    /// allowed to decide behavior.
    private func ambiguousResourceConversion(
        reason: String,
        source: String,
        targetMIME: String,
        onUpdate: @escaping UpdateHandler,
        startedAt: ContinuousClock.Instant
    ) -> ToolExecutionOutcome {
        let payload = jsonString([
            "status": "ambiguous",
            "source": source,
            "target_mime": targetMIME,
            "reason": reason,
            "is_error": true
        ])
        onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
        logs.error("Tool", "resource_convert ambiguous for '\(source)' -> '\(targetMIME)': \(reason)")
        return ToolExecutionOutcome(
            content: payload,
            isError: true,
            approvalState: .notRequired,
            durationMilliseconds: milliseconds(since: startedAt)
        )
    }

    private func executeArtifactAcquire(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: ArtifactAcquireArguments = try decode(call)
        let trimmedPath = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw ToolExecutorError.invalidArguments("path must not be empty.")
        }

        let resolvedPath = (trimmedPath as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ToolExecutorError.invalidArguments("File not found or is a directory at '\(fileURL.path)'.")
        }

        guard let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID else {
            throw ToolExecutorError.invalidArguments("No active conversation found for artifact acquisition.")
        }

        guard let store = artifactStore else {
            throw ToolExecutorError.invalidArguments("Artifact store is not available.")
        }

        let request = ToolPermissionRequest(
            toolName: "artifact_acquire",
            summary: "Acquire host file at \(fileURL.path) into conversation artifacts",
            workspaceURL: workspace.url,
            affectedURLs: [fileURL],
            command: nil,
            environmentKeys: [],
            requestsNetwork: false,
            isHighRisk: PermissionEvaluator.isSensitivePath(fileURL)
        )

        let approval = await authorize(request, allowedReadDirectories: allowedReadDirectories(), onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        try Task.checkCancellation()
        onUpdate(.init(state: .running, approvalState: approval, output: "Acquiring artifact from \(fileURL.path)..."))

        let startedAt = ContinuousClock.now
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ToolExecutorError.invalidArguments("Failed to read file at '\(fileURL.path)': \(error.localizedDescription)")
        }

        let mimeType = MIMETypeHelper.mimeType(for: fileURL.lastPathComponent)
        let semanticRole: ArtifactSemanticRole = mimeType.hasPrefix("image/") ? .image : .deliverable

        let desc = try store.save(
            data: data,
            conversationID: convID,
            filename: fileURL.lastPathComponent,
            mimeType: mimeType,
            producerProvenance: .hostAcquisition,
            workspaceProvenance: nil,
            authorizationProvenance: "user_acquire",
            retentionClass: .conversationRetained
        )

        let duration = milliseconds(since: startedAt)
        let payloadDict: [String: Any] = [
            "status": "acquired",
            "artifact_id": desc.artifactID.uuidString,
            "filename": desc.filename,
            "byte_count": desc.byteCount,
            "mime_type": desc.mimeType,
            "sha256": desc.sha256
        ]
        let payload = jsonString(payloadDict)

        onUpdate(.init(state: .completed, approvalState: approval, output: payload))
        logs.info("Tool", "artifact_acquire acquired '\(desc.filename)' (\(desc.byteCount) bytes) -> \(desc.artifactID.uuidString)")

        return ToolExecutionOutcome(
            content: payload,
            isError: false,
            approvalState: approval,
            durationMilliseconds: duration,
            resultParts: [.text(payload), .artifact(id: desc.artifactID, semanticRole: semanticRole, mimeType: desc.mimeType)]
        )
    }

    private func executeArtifactRegister(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let arguments: ArtifactRegisterArguments = try decode(call)
        let trimmedPath = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspaceURL = workspace.url else {
            throw ToolExecutorError.invalidArguments("Workspace must be selected before registering workspace artifacts.")
        }

        let resolvedURL = try WorkspacePathResolver.resolve(trimmedPath, relativeTo: workspaceURL, mustExist: true)
        guard WorkspacePathResolver.isInsideWorkspace(resolvedURL, workspaceURL: workspaceURL) else {
            throw ToolExecutorError.invalidArguments("Path '\(trimmedPath)' escapes the workspace boundaries.")
        }
        let fileURL = resolvedURL
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: fileURL)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw ToolExecutorError.invalidArguments("File not found or is a directory at '\(fileURL.path)'.")
        }

        guard let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID else {
            throw ToolExecutorError.invalidArguments("No active conversation found for artifact registration.")
        }

        guard let store = artifactStore else {
            throw ToolExecutorError.invalidArguments("Artifact store is not available.")
        }

        let request = ToolPermissionRequest(
            toolName: "artifact_register",
            summary: "Register workspace artifact: \(fileURL.lastPathComponent)",
            workspaceURL: workspace.url,
            affectedURLs: [fileURL],
            command: nil,
            environmentKeys: [],
            requestsNetwork: false,
            isHighRisk: false
        )

        let approval = await authorize(request, onUpdate: onUpdate)
        guard approval != .denied else { return deniedOutcome() }

        try Task.checkCancellation()
        onUpdate(.init(state: .running, approvalState: approval, output: "Registering artifact \(fileURL.lastPathComponent)..."))

        let startedAt = ContinuousClock.now

        let resourceRef = ResourceRef.workspaceFile(
            path: trimmedPath,
            workspaceURL: workspaceURL,
            conversationScope: convID
        )

        let artifactRef: ArtifactRef
        do {
            artifactRef = try ResourceResolver.materialize(
                ref: resourceRef,
                to: convID,
                in: workspaceURL,
                artifactStore: store,
                authorizationProvenance: "artifact_register"
            )
        } catch {
            throw ToolExecutorError.invalidArguments("Failed to materialize workspace resource '\(trimmedPath)': \(error.localizedDescription)")
        }

        let desc = try store.resolveDescriptor(artifactID: artifactRef.artifactID, conversationID: convID)
        let mimeType = desc.mimeType
        let semanticRole: ArtifactSemanticRole = mimeType.hasPrefix("image/") ? .image : .deliverable

        let duration = milliseconds(since: startedAt)
        var payloadDict: [String: Any] = [
            "status": "registered",
            "artifact_id": desc.artifactID.uuidString,
            "filename": desc.filename,
            "byte_count": desc.byteCount,
            "mime_type": desc.mimeType,
            "sha256": desc.sha256
        ]
        if let userDesc = arguments.description {
            payloadDict["description"] = userDesc
        }
        let payload = jsonString(payloadDict)

        onUpdate(.init(state: .completed, approvalState: approval, output: payload))
        logs.info("Tool", "artifact_register registered '\(desc.filename)' (\(desc.byteCount) bytes) -> \(desc.artifactID.uuidString)")

        return ToolExecutionOutcome(
            content: payload,
            isError: false,
            approvalState: approval,
            durationMilliseconds: duration,
            resultParts: [.text(payload), .artifact(id: desc.artifactID, semanticRole: semanticRole, mimeType: desc.mimeType)]
        )
    }

    private func executeToolResultRead(
        _ call: ProviderToolCall,
        onUpdate: UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        let startedAt = ContinuousClock.now
        if call.isTruncatedByOutputLimit {
            let data = Data(call.function.arguments.utf8)
            if (try? JSONDecoder().decode(ToolResultReadArguments.self, from: data)) == nil {
                let duration = milliseconds(since: startedAt)
                let reason = call.finishReason ?? "length"
                let payload = jsonString([
                    "error": "Tool call arguments were truncated due to provider token output limit (finish_reason: \(reason)). The payload is incomplete JSON and cannot be executed.",
                    "is_error": true
                ])
                return ToolExecutionOutcome(
                    content: payload,
                    isError: true,
                    approvalState: .notRequired,
                    durationMilliseconds: duration
                )
            }
        }

        guard let args = try? JSONDecoder().decode(ToolResultReadArguments.self, from: Data(call.function.arguments.utf8)),
              !args.callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let duration = milliseconds(since: startedAt)
            let payload = jsonString(["error": "Missing or invalid required parameter 'call_id'", "is_error": true])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        let targetCallID = args.callID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let convID = hookExecutionScope?.conversationID ?? activeConversationIDProvider?() ?? browserActionConversationID else {
            let duration = milliseconds(since: startedAt)
            let payload = jsonString(["error": "No active conversation scope available to resolve tool results.", "is_error": true])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        guard let resolver = canonicalMessageResolver,
              let messages = resolver(convID) else {
            let duration = milliseconds(since: startedAt)
            let payload = jsonString(["error": "Canonical conversation history is unavailable for conversation '\(convID)'.", "is_error": true])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        // Search canonical messages in active conversation scope
        var matches: [ToolCallRecord] = []
        for msg in messages {
            for tCall in msg.toolCalls {
                if tCall.providerCallID == targetCallID || tCall.id.uuidString == targetCallID {
                    matches.append(tCall)
                }
            }
        }

        let duration = milliseconds(since: startedAt)

        if matches.count > 1 {
            let errorMsg = "Multiple historical tool calls match call_id '\(targetCallID)' in conversation '\(convID)'. Ambiguous retrieval is rejected."
            let payload = jsonString([
                "error": errorMsg,
                "call_id": targetCallID,
                "is_error": true,
                "ambiguous_count": matches.count
            ])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        guard let record = matches.first else {
            let errorMsg = "Tool call '\(targetCallID)' was not found in the current conversation."
            let payload = jsonString([
                "error": errorMsg,
                "call_id": targetCallID,
                "is_error": true
            ])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        // Terminal state check
        if record.state == .running || record.state == .queued || record.state == .awaitingApproval {
            let errorMsg = "Tool call '\(targetCallID)' is in non-terminal state '\(record.state.rawValue)' and cannot be read as final evidence."
            let payload = jsonString([
                "error": errorMsg,
                "call_id": targetCallID,
                "tool_name": record.name,
                "state": record.state.rawValue,
                "is_error": true
            ])
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: duration
            )
        }

        // Build canonical retrieved output preserving failure and epistemic truth
        var resultDict: [String: Any] = [
            "call_id": record.providerCallID.isEmpty ? record.id.uuidString : record.providerCallID,
            "tool_name": record.name,
            "state": record.state.rawValue,
            "output": record.output
        ]
        let isHistoricalError: Bool
        switch record.state {
        case .completed:
            isHistoricalError = false
        case .failed, .timedOut, .cancelled, .denied, .interrupted:
            isHistoricalError = true
        case .queued, .awaitingApproval, .running:
            isHistoricalError = false
        }
        resultDict["is_error"] = isHistoricalError
        if let err = record.errorMessage {
            resultDict["error_message"] = err
        }
        if let parts = record.resultParts, !parts.isEmpty {
            resultDict["result_parts_count"] = parts.count
        }

        let payload = jsonString(resultDict)
        onUpdate(.init(state: .completed, approvalState: .notRequired, output: payload))
        logs.info("Tool", "tool_result_read retrieved call '\(targetCallID)' (\(record.name)) -> state: \(record.state.rawValue)")

        return ToolExecutionOutcome(
            content: payload,
            isError: false,
            approvalState: .notRequired,
            durationMilliseconds: duration,
            resultParts: record.resultParts
        )
    }

    private func executeComputerUse(
        _ call: ProviderToolCall,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        // Stage 10: Sole active production route: v0.2 ComputerUseV2Engine (C2 Direct MCP)
        guard let v2Engine = computerUseV2Engine else {
            throw ToolExecutorError.unknownTool("computer_use: v0.2 production engine unavailable")
        }
        return try await executeComputerUseV2(call, engine: v2Engine, onUpdate: onUpdate)
    }

    private func executeComputerUseV2(
        _ call: ProviderToolCall,
        engine: ComputerUseV2Engine,
        onUpdate: @escaping UpdateHandler
    ) async throws -> ToolExecutionOutcome {
        guard let scope = hookExecutionScope,
              let authorityResolver = self.runAuthorityResolver else {
            let message = "Computer Use requires an authoritative scoped Run with active conversationID, runID, and runAuthorityResolver."
            let payload = jsonString([
                "status": "failed",
                "detail": message,
                "error": message
            ])
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: 0,
                mechanicalTerminalFact: nil
            )
        }
        let conversationID = scope.conversationID
        let runID = scope.runID

        let input: ComputerUseV2ActionInput
        do {
            input = try ComputerUseV2ActionInput.parse(from: call.function.arguments)
        } catch {
            let message = error.localizedDescription
            let payload = jsonString([
                "status": "unsupported",
                "detail": message,
                "error": message
            ])
            onUpdate(.init(state: .failed, approvalState: .notRequired, output: payload))
            return ToolExecutionOutcome(
                content: payload,
                isError: true,
                approvalState: .notRequired,
                durationMilliseconds: 0,
                mechanicalTerminalFact: nil
            )
        }

        onUpdate(.init(state: .running, approvalState: .notRequired, output: "Executing \(input.action.rawValue)..."))
        let startedAt = ContinuousClock.now

        let result = await engine.dispatchAction(
            input: input,
            conversationID: conversationID,
            runID: runID,
            isAuthoritative: authorityResolver
        )

        let duration = milliseconds(since: startedAt)
        let payload = result.jsonContent
        let approvalState = result.admissionState

        let terminalState: ToolExecutionState
        switch result.status {
        case .dispatched:
            terminalState = .completed
        case .denied, .blocked:
            terminalState = .denied
        case .cancelled:
            terminalState = .cancelled
        case .timedOut:
            terminalState = .timedOut
        case .staleObservation, .targetChanged, .unsupported, .failed:
            terminalState = .failed
        }

        let legacyStatus: ComputerUseActionResultStatus
        switch result.status {
        case .dispatched: legacyStatus = .dispatched
        case .denied: legacyStatus = .denied
        case .blocked: legacyStatus = .blocked
        case .cancelled: legacyStatus = .cancelled
        case .timedOut: legacyStatus = .timedOut
        case .staleObservation: legacyStatus = .staleObservation
        case .targetChanged: legacyStatus = .targetChanged
        case .unsupported: legacyStatus = .unsupported
        case .failed: legacyStatus = .failed
        }

        let legacyActionKind: ComputerUseActionKind
        switch result.actionKind {
        case .click, .doubleClick, .rightClick: legacyActionKind = .click
        case .type, .typeText: legacyActionKind = .typeText
        case .key, .hotkey: legacyActionKind = .hotkey
        case .drag: legacyActionKind = .drag
        case .scroll: legacyActionKind = .scroll
        case .wait: legacyActionKind = .wait
        default: legacyActionKind = .moveCursor
        }

        let mechanicalFact = ToolMechanicalTerminalFact.computerUse(
            status: legacyStatus,
            actionKind: legacyActionKind,
            osEventStarted: result.osEventStarted,
            transientReleaseOutcome: result.transientInputReleased ? .released : (result.releaseFailure != nil ? .failed(result.releaseFailure!) : .notApplicable)
        )


        onUpdate(.init(state: terminalState, approvalState: approvalState, output: payload))
        return ToolExecutionOutcome(
            content: payload,
            isError: !result.isSuccess,
            approvalState: approvalState,
            durationMilliseconds: duration,
            mechanicalTerminalFact: mechanicalFact
        )
    }

    private struct ToolResultReadArguments: Decodable {
        let callID: String

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
        }
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:;\0")
        var sanitized = name.components(separatedBy: invalidCharacters).joined(separator: "_")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        if sanitized.isEmpty {
            return "attachment"
        }
        return sanitized
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Could not encode tool result.\"}"
        }
        return result
    }

    private struct ShellArguments: Decodable {
        let command: String
        let cwd: String?
        let environment: [String: String]?
        let timeoutSeconds: TimeInterval?
        let sandboxPermissions: String?
        let justification: String?

        /// Codex's escalation request: write outside the working folder and temp, once approved.
        var requiresEscalation: Bool { sandboxPermissions == "require_escalated" }

        enum CodingKeys: String, CodingKey {
            case command
            case cwd
            case environment
            case timeoutSeconds = "timeout_seconds"
            case sandboxPermissions = "sandbox_permissions"
            case justification
        }
    }

    private struct AttachmentCopyArguments: Decodable {
        let source: String
        let destination: String?
    }

    private struct ResourceConvertArguments: Decodable {
        let source: String
        let targetMIME: String

        enum CodingKeys: String, CodingKey {
            case source
            case targetMIME = "target_mime"
        }
    }

    private struct ArtifactAcquireArguments: Decodable {
        let path: String
    }

    private struct ArtifactRegisterArguments: Decodable {
        let path: String
        let description: String?
    }

    private struct PathArguments: Decodable { let path: String }
    /// Numbers decode as `Double`, so a model's `10.0` reads as 10; `FileReadWindow` checks them.
    private struct ReadArguments: Decodable { let path: String; let offset: Double?; let limit: Double? }
    private struct WriteArguments: Decodable { let path: String; let content: String }
    private struct EditArguments: Decodable {
        let path: String
        let oldText: String
        let newText: String

        enum CodingKeys: String, CodingKey {
            case path
            case oldText = "old_text"
            case newText = "new_text"
        }
    }

    private struct FileListArguments: Decodable {
        let path: String?
        let recursive: Bool?
        let max_depth: Int?
        let max_entries: Int?
    }

    private struct FileSearchArguments: Decodable {
        let query: String
        let path: String?
        let mode: String?
        let regex: Bool?
        let max_results: Int?
    }

    private struct DelegateTaskArguments: Decodable {
        let tasks: [RawTaskItem]
        let background: Bool?
        let wait_seconds: Double?
    }

    private struct RawTaskItem: Decodable {
        let title: String
        let goal: String
        let context: String?
        let scope: String?
        let constraints: String?
        let expected_output: String?
        let allow_web: Bool?
        let workspace_scope: String?
        let task_effort: String?
        let role: String?
    }

    private struct ReadImageArguments: Decodable {
        let path: String
        let prompt: String?
    }

    private struct ModelUseArguments: Decodable {
        let action: String
        let query: String?
        let entryID: String?
        let prompt: String?
        let systemPrompt: String?
        let maxTokens: Int?
        let artifactIDs: [String]?
        let size: String?
        let quality: String?

        enum CodingKeys: String, CodingKey {
            case action, query, prompt, size, quality
            case entryID = "entry_id"
            case systemPrompt = "system_prompt"
            case maxTokens = "max_tokens"
            case artifactIDs = "artifact_ids"
        }
    }

    private struct FileContext {
        let url: URL
        let workspaceURL: URL
        var displayPath: String

        func request(toolName: String, action: String) -> ToolPermissionRequest {
            ToolPermissionRequest(
                toolName: toolName,
                summary: "\(action) \(displayPath)",
                workspaceURL: workspaceURL,
                affectedURLs: [url],
                command: nil,
                environmentKeys: [],
                requestsNetwork: false,
                isHighRisk: PermissionEvaluator.isSensitivePath(url)
            )
        }
    }
}
