import Foundation

/// Limare's own records as Remote shows them. No state, and no owner access but the `FileLookup` the hub hands in.
/// Leaves out what a remote viewer must not get or does not need (provider ids, reasoning
/// echoes, rejected provider turns, file locations: a file is named by its id) and bounds tool text.
enum RemoteProjection {
    static let toolInputLimit = 2_048
    static let toolOutputLimit = 4_096

    /// What projecting a message's file cards needs from the owners.
    struct FileLookup {
        let conversationID: UUID
        /// An artifact of the conversation that can still be read: its name and size.
        let artifact: (UUID) -> (filename: String, byteCount: Int)?
        /// The existing workspace file a file tool call names.
        let toolCallTarget: (ToolCallRecord) -> URL?
    }

    static func message(_ message: ChatMessage, files: FileLookup) -> RemoteMessage {
        RemoteMessage(
            id: message.id,
            role: message.role.rawValue,
            state: message.state.rawValue,
            content: message.content,
            reasoning: message.reasoningContent.flatMap { $0.isEmpty ? nil : $0 },
            isSystemNotice: message.isSystemNotice,
            sentWhileWorking: message.sentWhileWorking,
            model: message.resolvedModelID,
            attachments: message.attachments.map {
                file(.attachment, id: $0.id, filename: $0.filename, byteCount: $0.byteCount, in: files.conversationID)
            },
            toolCalls: message.toolCalls.map { toolCall($0, files: files) },
            files: TurnDeliverables.artifactIDs(in: [message]).compactMap { id in
                files.artifact(id).map { file(.artifact, id: id, filename: $0.filename, byteCount: $0.byteCount, in: files.conversationID) }
            }
        )
    }

    static func toolCall(_ record: ToolCallRecord, files: FileLookup) -> RemoteToolCall {
        let input = truncated(record.input, limit: toolInputLimit)
        let output = truncated(record.output, limit: toolOutputLimit)
        return RemoteToolCall(
            id: record.id,
            name: record.name,
            state: record.state.rawValue,
            approvalState: record.approvalState.rawValue,
            input: input.text,
            inputTruncated: input.truncated,
            output: output.text,
            outputTruncated: output.truncated,
            errorMessage: record.errorMessage,
            durationMs: record.durationMilliseconds,
            summary: ToolCallPresentationResolver.resolveSummary(name: record.name, input: record.input),
            file: files.toolCallTarget(record).map {
                let size = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                return file(.toolCall, id: record.id, filename: $0.lastPathComponent, byteCount: size, in: files.conversationID)
            }
        )
    }

    static func file(_ source: RemoteFile.Source, id: UUID, filename: String, byteCount: Int?, in conversationID: UUID) -> RemoteFile {
        let kind = preview(of: filename, byteCount: byteCount)
        return RemoteFile(source: source, id: id, conversationID: conversationID, filename: filename, byteCount: byteCount,
                          preview: kind.preview, language: kind.language)
    }

    /// How the Mac's Files surface previews a file named `filename`, as the page names it: none
    /// for a type it does not preview, or a file past its size limit for that kind.
    static func preview(of filename: String, byteCount: Int?) -> (preview: String?, language: String?) {
        let kind: (preview: String?, language: String?, limit: Int64)
        switch FilePreviewClassifier.classify(url: URL(fileURLWithPath: filename)) {
        case .markdown: kind = ("markdown", nil, FilesSurfaceStore.maximumTextPreviewBytes)
        case .text: kind = ("text", nil, FilesSurfaceStore.maximumTextPreviewBytes)
        case .code(let language): kind = ("code", language, FilesSurfaceStore.maximumTextPreviewBytes)
        case .html: kind = ("html", nil, FilesSurfaceStore.maximumTextPreviewBytes)
        case .image: kind = ("image", nil, FilesSurfaceStore.maximumImagePreviewBytes)
        case .pdf: kind = ("pdf", nil, FilesSurfaceStore.maximumPDFPreviewBytes)
        case .unsupported: return (nil, nil)
        }
        if let byteCount, Int64(byteCount) > kind.limit { return (nil, nil) }
        return (kind.preview, kind.language)
    }

    static let commands = ComposerCommand.all.map { RemoteComposerCommand(name: $0.name, summary: $0.summary) }

    /// What the Mac transcript shows of the Compact command: finished ones as lines after their
    /// message, and one running or just failed at the end (a finished one is in `markers`).
    static func compactions(_ markers: [CompactionMarker], current: ManualCompaction?) -> RemoteCompactions {
        let line: RemoteCompactions.Current? = switch current {
        case .running(let since): .init(state: .running, since: since, message: nil)
        case .failed(let message): .init(state: .failed, since: nil, message: message)
        case .finished, nil: nil
        }
        return RemoteCompactions(
            finished: markers.map { .init(afterMessageID: $0.afterMessageID, tokensBefore: $0.tokensBefore, tokensAfter: $0.tokensAfter) },
            current: line
        )
    }

    static func summary(
        _ record: ConversationRecord,
        projectName: String?,
        run: RemoteConversationSummary.RunBadge?,
        hasPendingApproval: Bool,
        hasPendingQuestion: Bool = false
    ) -> RemoteConversationSummary {
        RemoteConversationSummary(
            id: record.id,
            title: record.title,
            updatedAt: record.updatedAt,
            projectID: record.projectID,
            projectName: projectName,
            isPinned: record.isPinned,
            run: run,
            hasPendingApproval: hasPendingApproval,
            hasPendingQuestion: hasPendingQuestion
        )
    }

    static func runState(_ run: ConversationRun?, isPausing: Bool, statusText: String?, queuedCount: Int, queueHeld: Bool) -> RemoteRunState {
        RemoteRunState(
            run: run.map {
                RemoteRun(
                    id: $0.id,
                    status: $0.status.rawValue,
                    isPausing: isPausing,
                    startedAt: $0.startedAt,
                    error: $0.error,
                    statusText: $0.status.isTerminal ? nil : statusText
                )
            },
            queuedCount: queuedCount,
            queueHeld: queueHeld
        )
    }

    static func question(_ pending: PendingUserQuestion) -> RemoteQuestion {
        RemoteQuestion(
            id: pending.id,
            conversationID: pending.conversationID,
            conversationTitle: pending.conversationTitle,
            questions: pending.questions.map { item in
                RemoteQuestion.Item(header: item.header, question: item.question, multiSelect: item.multiSelect,
                                    options: item.options.map { .init(label: $0.label, description: $0.description) })
            }
        )
    }

    static func approval(_ pending: PendingApproval) -> RemoteApproval {
        RemoteApproval(
            kind: .tool,
            id: pending.id,
            conversationID: pending.conversationID,
            conversationTitle: pending.conversationTitle,
            toolName: pending.toolName,
            summary: pending.summary,
            reason: pending.reason,
            command: pending.command,
            affectedPaths: pending.affectedPaths,
            environmentKeys: pending.environmentKeys,
            requestsNetwork: pending.requestsNetwork,
            isHighRisk: pending.isHighRisk,
            appName: nil,
            bundleID: nil
        )
    }

    static func approval(_ pending: ComputerUseAppApprovalPending, conversationTitle: String?) -> RemoteApproval {
        RemoteApproval(
            kind: .app,
            id: pending.id,
            conversationID: pending.conversationID,
            conversationTitle: conversationTitle,
            toolName: nil,
            summary: nil,
            reason: nil,
            command: nil,
            affectedPaths: [],
            environmentKeys: [],
            requestsNetwork: false,
            isHighRisk: false,
            appName: pending.appLocalizedName,
            bundleID: pending.bundleID
        )
    }

    static func project(_ record: ProjectRecord) -> RemoteProjectSummary {
        RemoteProjectSummary(id: record.id, name: record.name, isPinned: record.isPinned)
    }

    static func modelRef(_ source: ConversationModelSource) -> RemoteModelRef {
        switch source {
        case .group(let groupID): .group(groupID)
        case .direct(let providerID, let modelID): .direct(providerID: providerID, modelID: modelID)
        }
    }

    static func modelSource(_ ref: RemoteModelRef) -> ConversationModelSource {
        switch ref {
        case .group(let groupID): .group(groupID: groupID)
        case .direct(let providerID, let modelID): .direct(providerID: providerID, modelID: modelID)
        }
    }

    /// The Mac composer's thinking menu (`ComposerThinkingControl`) for `state`; nil when it shows none.
    static func thinking(_ state: ComposerThinkingPresentationState) -> RemoteThinking? {
        guard state.isVisible else { return nil }
        var options: [RemoteThinking.Option] = []
        if state.isGroupSource {
            if let defaultLabel = state.menuGroupDefaultLabel {
                options.append(.init(level: nil, label: defaultLabel, isSelected: state.requestedOverride == nil))
            }
            options += ThinkingLevel.allCases.map { .init(level: $0.rawValue, label: $0.displayName, isSelected: state.requestedOverride == $0) }
        } else {
            let offSelected = state.requestedOverride == .off || (state.requestedOverride == nil && state.effectiveLevel == .off)
            options.append(.init(level: ThinkingLevel.off.rawValue, label: ThinkingLevel.off.displayName, isSelected: offSelected))
            options += state.availableLevels.filter { $0 != .off }
                .map { .init(level: $0.rawValue, label: $0.displayName, isSelected: state.requestedOverride == $0) }
        }
        return RemoteThinking(label: state.displayLabel, options: options)
    }

    /// Roughly how many bytes `message` adds to a frame: its text, which is nearly all of it.
    static func approximateSize(_ message: RemoteMessage) -> Int {
        message.content.utf8.count + (message.reasoning?.utf8.count ?? 0)
            + message.toolCalls.reduce(0) { $0 + $1.input.utf8.count + $1.output.utf8.count + ($1.errorMessage?.utf8.count ?? 0) }
    }

    /// `text` cut to at most `limit` UTF-8 bytes, on a character boundary.
    static func truncated(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var result = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= limit else { break }
            result.append(character)
            bytes += size
        }
        return (result, true)
    }
}
