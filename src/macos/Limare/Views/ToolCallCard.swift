import SwiftUI
import AppKit

struct ToolCallCard: View {
    let toolCall: ToolCallRecord
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var isManuallyExpanded: Bool

    @State private var pendingUndo: UndoRequest?

    init(toolCall: ToolCallRecord, isInitiallyExpanded: Bool = false) {
        self.toolCall = toolCall
        _isManuallyExpanded = State(initialValue: isInitiallyExpanded)
    }

    private var isExpanded: Bool {
        isManuallyExpanded
    }

    private var presentation: ToolCallPresentationModel {
        ToolCallPresentationResolver.resolve(toolCall: toolCall)
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .neutral: return .secondary
        case .active: return .blue
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    private var resolvedFileTargetURL: URL? {
        let workspaceURL = window.conversationID.map {
            appState.conversations.effectiveWorkingDirectory(for: $0)
        } ?? appState.workspace.url
        return ToolCallFileTargetResolver.resolveTargetURL(for: toolCall, in: workspaceURL)
    }

    private var changeNotice: ToolCallChangeNotice? {
        Self.changeNotice(for: toolCall, appState: appState, window: window)
    }

    /// The files a call changed although it did not succeed, from its conversation's undo journal.
    static func changeNotice(for toolCall: ToolCallRecord, appState: AppState, window: WindowSession) -> ToolCallChangeNotice? {
        guard let conversationID = toolCall.owningRunID.flatMap({
            appState.conversationRuns.conversationID(forRunID: $0)
        }) ?? window.conversationID else { return nil }
        return ToolCallChangeTruth.notice(
            toolState: toolCall.state,
            providerCallID: toolCall.providerCallID,
            records: appState.undo.journal.records(for: conversationID)
        )
    }

    private static let chevronWidth: CGFloat = 10
    private static let statusWidth: CGFloat = 14
    /// Where the row's text starts, so its notices and details line up under the tool name.
    private static let contentIndent = chevronWidth + AppSpacing.small + statusWidth + AppSpacing.small

    /// A call that went well needs no mark; one that is running, waiting or did not succeed shows it.
    private var showsStatus: Bool { presentation.tone != .success }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                    isManuallyExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.chevronWidth)

                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .opacity(showsStatus ? 1 : 0)
                        .frame(width: Self.statusWidth)
                        .accessibilityHidden(!showsStatus)

                    // What the call does, in words, leads; the tool's own name follows, quieter.
                    // The summary is the one part that gives way when the row is narrow: every
                    // other label keeps its natural size, or it would wrap a letter per line.
                    if let summary = presentation.summary {
                        Text(summary)
                            .font(AppTypography.interfaceSubheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(presentation.summaryHelp ?? "")

                        Text(presentation.displayToolName)
                            .font(AppTypography.interfaceCaption)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    } else {
                        Text(presentation.displayToolName)
                            .font(AppTypography.interfaceSubheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let label = presentation.namespaceLabel {
                        Text(label)
                            .font(AppTypography.interfaceCaption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, AppSemanticSpacing.badgePaddingHorizontal)
                            .padding(.vertical, AppSemanticSpacing.badgePaddingVertical)
                            .background(AppColors.surfaceInteractive)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                            .fixedSize()
                    }

                    Spacer()

                    if let duration = ToolCallDurationFormat.compact(milliseconds: toolCall.durationMilliseconds) {
                        Text(duration)
                            .font(AppTypography.interfaceCaption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }

                    if toolCall.state != .completed,
                       let status = ToolCallPresentationResolver.statusLabel(for: toolCall.state) {
                        Text(status)
                            .font(AppTypography.interfaceCaption.weight(.medium))
                            .foregroundStyle(statusColor)
                            .fixedSize()
                    }
                }
                .padding(.vertical, AppSpacing.xxSmall)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let notice = changeNotice {
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.statusWarning)
                    Text("失败，但文件已被修改（\(notice.paths.count) 个）")
                        .font(.caption)
                        .foregroundStyle(AppColors.statusWarning)
                        .lineLimit(1)
                        .accessibilityIdentifier("toolcard.changedOnFailure")
                    if notice.ownerMessageID == window.chat.retractableUserMessageID {
                        Button("查看撤销") { pendingUndo = UndoRequest(messageID: notice.ownerMessageID) }
                            .buttonStyle(QuietLinkButtonStyle())
                    }
                    Spacer()
                }
                .padding(.leading, Self.contentIndent)
                .padding(.bottom, AppSpacing.xxSmall)
                .help(notice.paths.joined(separator: "\n"))
            }

            if let targetURL = resolvedFileTargetURL {
                FileArtifactCard(fileURL: targetURL)
                    .padding(.leading, Self.contentIndent)
                    .padding(.bottom, AppSpacing.xxSmall)
            }

            if isExpanded {
                ToolCallDetails(toolCall: toolCall)
                    .padding(.leading, Self.contentIndent)
                    .padding(.vertical, AppSpacing.xSmall)
            }
        }
        .sheet(item: $pendingUndo) { request in
            UndoMessageSheet(messageID: request.messageID)
                .environment(appState)
        }
    }
}

private struct ToolCallDetails: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let toolCall: ToolCallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            let isBrowser = toolCall.name == "browser_use" || toolCall.name.hasSuffix("browser_use")
            let targetConversationID = toolCall.owningRunID.flatMap { appState.conversationRuns.conversationID(forRunID: $0) } ?? window.conversationID
            let hasSession = targetConversationID.map { appState.browser.hasSession(for: $0) } ?? false
            if isBrowser && hasSession {
                HStack {
                    Button {
                        if let targetConversationID, window.conversationID != targetConversationID {
                            appState.focus(window)
                            appState.conversations.selectConversation(id: targetConversationID)
                        }
                        window.workSurface.openBrowser()
                    } label: {
                        Label("Open Browser", systemImage: "globe")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.bottom, AppSpacing.xxSmall)
            }

            if !toolCall.input.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    HStack {
                        Text("Input")
                            .font(AppTypography.interfaceCaption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        // The recorded arguments exactly as the model sent them.
                        Button("Copy Raw") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(toolCall.input, forType: .string)
                        }
                        .buttonStyle(.link)
                        .font(AppTypography.interfaceCaption)
                        .help("Copy the arguments exactly as recorded")
                    }
                    ScrollView(.vertical) {
                        Text(ToolCallInputPresentation.formatted(toolCall.input))
                            .font(AppTypography.codeMeta)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.toolInputMaximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpacing.small)
                    .background(AppColors.surfaceInteractive)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
            }

            if !toolCall.output.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text("Output")
                        .font(AppTypography.interfaceCaption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.vertical) {
                        Text(toolCall.output)
                            .font(AppTypography.codeMeta)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.toolOutputMaximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppSpacing.small)
                    .background(AppColors.surfaceInteractive)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
            }

            HStack(spacing: AppSpacing.medium) {
                if let approval = ToolCallPresentationResolver.approvalLabel(for: toolCall.approvalState) {
                    Label(approval, systemImage: "hand.raised")
                }
                if let milliseconds = toolCall.durationMilliseconds {
                    Label(ToolCallDurationFormat.detail(milliseconds: milliseconds), systemImage: "clock")
                        .help("\(milliseconds.formatted()) ms")
                }
                if let error = toolCall.errorMessage, !error.isEmpty {
                    Text(error)
                        .foregroundStyle(AppColors.statusError)
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .help(error)
                }
            }
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(.secondary)
        }
    }
}
