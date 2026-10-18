import SwiftUI

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
        guard let conversationID = toolCall.owningRunID.flatMap({
            appState.conversationRuns.conversationID(forRunID: $0)
        }) ?? window.conversationID else { return nil }
        return ToolCallChangeTruth.notice(
            toolState: toolCall.state,
            providerCallID: toolCall.providerCallID,
            records: appState.undo.journal.records(for: conversationID)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                    isManuallyExpanded = !isExpanded
                }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)

                    Text(presentation.displayToolName)
                        .font(.system(.subheadline, design: .monospaced, weight: .medium))
                        .foregroundStyle(Color.primary)

                    if let label = presentation.namespaceLabel {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, AppSpacing.xxSmall + 1)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .foregroundStyle(Color.purple)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                    }

                    if let summary = presentation.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if let duration = toolCall.durationMilliseconds {
                        Text("\(duration) ms")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    Text(toolCall.state.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(statusColor)
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.vertical, AppSpacing.small)
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
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.small)
                .help(notice.paths.joined(separator: "\n"))
            }

            if let targetURL = resolvedFileTargetURL {
                FileArtifactCard(fileURL: targetURL)
                    .padding(.horizontal, AppSpacing.medium)
                    .padding(.bottom, AppSpacing.small)
            }

            if isExpanded {
                Divider()
                    .padding(.horizontal, AppSpacing.small)

                ToolCallDetails(toolCall: toolCall)
                    .padding(AppSpacing.medium)
            }
        }
        .background(AppColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
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
                    Text("Input")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.vertical) {
                        Text(toolCall.input)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.toolInputMaximumHeight)
                    .padding(AppSpacing.small)
                    .background(AppColors.surfaceInteractive)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
            }

            if !toolCall.output.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text("Output")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.vertical) {
                        Text(toolCall.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.toolOutputMaximumHeight)
                    .padding(AppSpacing.small)
                    .background(AppColors.surfaceInteractive)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                }
            }

            HStack(spacing: AppSpacing.medium) {
                Label(toolCall.approvalState.rawValue, systemImage: "hand.raised")
                if let duration = toolCall.durationMilliseconds {
                    Label("\(duration) ms", systemImage: "clock")
                }
                if let error = toolCall.errorMessage, !error.isEmpty {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
