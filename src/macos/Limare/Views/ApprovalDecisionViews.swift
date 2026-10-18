import SwiftUI

/// The approval a run of this window's conversation waits on, shown in the conversation above
/// the composer rather than in a modal sheet, so the transcript that led to it stays readable
/// and the rest of the app stays usable. Approvals another conversation waits on show as a
/// notice that leads there. Requests outside any conversation, and MCP credentials, still use
/// a sheet (`RootView`).
struct ConversationApprovalArea: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            ApprovalElsewhereNotice(excluding: window.conversationID)
            if let pending = appState.computerUseAppAuthorization.pendingApproval,
               pending.conversationID == window.conversationID {
                AppControlDecisionCard(pending: pending)
            } else if let approval = appState.permissions.pendingApproval,
                      let conversationID = approval.conversationID, conversationID == window.conversationID {
                ToolApprovalDecisionCard(approval: approval)
            }
        }
        .frame(maxWidth: AppLayout.transcriptMaximumWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.chatHorizontal)
    }
}

/// Names the conversations waiting on an approval, other than `excluded`, and leads to the first.
struct ApprovalElsewhereNotice: View {
    @Environment(AppState.self) private var appState
    let excluded: UUID?

    init(excluding excluded: UUID?) {
        self.excluded = excluded
    }

    var body: some View {
        let waiting = appState.conversationsAwaitingApproval.filter { $0 != excluded }
        if let first = waiting.first {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(AppColors.statusWarning)
                Text("“\(title(of: first))” is waiting for your approval.")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppSpacing.small)
                Button("Show") { appState.reveal(conversationID: first) }
                    .controlSize(.small)
                    .accessibilityIdentifier("approval.elsewhere.show")
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.xSmall)
            .background(AppColors.statusWarning.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.card))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("approval.elsewhere")
        }
    }

    private func title(of conversationID: UUID) -> String {
        appState.conversations.conversations.first { $0.id == conversationID }?.title ?? "Another conversation"
    }
}

/// A tool call that crosses a permission boundary: what it does, then Deny or Allow Once.
private struct ToolApprovalDecisionCard: View {
    @Environment(AppState.self) private var appState
    let approval: PendingApproval

    var body: some View {
        ApprovalCardContainer(tint: approval.isHighRisk ? AppColors.statusError : AppColors.statusWarning) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: approval.isHighRisk ? "exclamationmark.triangle.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(approval.isHighRisk ? AppColors.statusError : AppColors.statusWarning)
                Text("Approval Required")
                    .font(AppTypography.interfaceSemibold)
                Text(approval.toolName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(approval.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                if let command = approval.command, !command.isEmpty {
                    ApprovalDetailRow(label: "Command") {
                        ScrollView {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: AppLayout.toolInputMaximumHeight)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !approval.affectedPaths.isEmpty {
                    ApprovalDetailRow(label: "Paths") {
                        Text(approval.affectedPaths.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if approval.requestsNetwork {
                    ApprovalDetailRow(label: "Network") {
                        Label("May access external network", systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(AppColors.statusWarning)
                    }
                }
                if !approval.environmentKeys.isEmpty {
                    ApprovalDetailRow(label: "Env Keys") {
                        Text("\(approval.environmentKeys.joined(separator: ", ")) (values hidden)")
                            .font(.caption.monospaced())
                    }
                }
            }

            HStack {
                Spacer()
                Button("Deny") {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: false)
                }
                .accessibilityIdentifier("approval.deny")
                Button("Allow Once") {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approval.allowOnce")
            }
        }
        .accessibilityIdentifier("approval.card")
    }
}

/// Computer Use asking to control an app for this conversation.
private struct AppControlDecisionCard: View {
    @Environment(AppState.self) private var appState
    let pending: ComputerUseAppApprovalPending

    var body: some View {
        ApprovalCardContainer(tint: AppColors.statusWarning) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(AppColors.statusWarning)
                Text("Authorize App Control")
                    .font(AppTypography.interfaceSemibold)
            }

            Text("Allow Limare to CONTROL this App for the current conversation. It can then send keyboard and mouse events to it until the conversation ends.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                ApprovalDetailRow(label: "Application") {
                    Text(pending.appLocalizedName)
                        .font(.caption.weight(.medium))
                        .accessibilityIdentifier("computerUse.appApproval.appName")
                }
                ApprovalDetailRow(label: "Bundle ID") {
                    Text(pending.bundleID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("computerUse.appApproval.bundleID")
                }
            }

            HStack {
                Button("Block for this conversation") {
                    appState.computerUseAppAuthorization.resolvePendingApproval(id: pending.id, approved: false)
                }
                .accessibilityIdentifier("computerUse.appApproval.blockConversation")
                Spacer()
                Button("Allow for this conversation") {
                    appState.computerUseAppAuthorization.resolvePendingApproval(id: pending.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("computerUse.appApproval.allowConversation")
            }
        }
        .accessibilityIdentifier("computerUse.appApproval.sheet")
    }
}

private struct ApprovalCardContainer<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            content
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surfaceSecondary, in: RoundedRectangle(cornerRadius: AppRadius.bubble))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.bubble).strokeBorder(tint.opacity(0.45)))
        .accessibilityElement(children: .contain)
    }
}

private struct ApprovalDetailRow<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.small) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            value
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
