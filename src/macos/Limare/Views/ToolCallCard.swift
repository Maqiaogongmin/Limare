import SwiftUI

struct ToolCallCard: View {
    let toolCall: ToolCallRecord
    @Environment(AppState.self) private var appState
    @State private var isManuallyExpanded = false

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
        let workspaceURL = appState.conversations.activeConversationID.map {
            appState.conversations.effectiveWorkingDirectory(for: $0)
        } ?? appState.workspace.url
        return ToolCallFileTargetResolver.resolveTargetURL(for: toolCall, in: workspaceURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
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
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct ToolCallDetails: View {
    @Environment(AppState.self) private var appState
    let toolCall: ToolCallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            let isBrowser = toolCall.name == "browser_use" || toolCall.name.hasSuffix("browser_use")
            let targetConversationID = toolCall.owningRunID.flatMap { appState.conversationRuns.conversationID(forRunID: $0) } ?? appState.conversations.activeConversationID
            let hasSession = targetConversationID.map { appState.browser.hasSession(for: $0) } ?? false
            if isBrowser && hasSession {
                HStack {
                    Button {
                        if let targetConversationID, appState.conversations.activeConversationID != targetConversationID {
                            appState.conversations.selectConversation(id: targetConversationID)
                        }
                        appState.workSurface.openBrowser()
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
                    Text(toolCall.input)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AppSpacing.small)
                        .background(Color.secondary.opacity(0.08))
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
                    .background(Color.secondary.opacity(0.08))
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
