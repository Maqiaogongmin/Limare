import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The sidebar's visibility before the Work Surface expanded, restored when it stops.
    @State private var visibilityBeforeExpanding: NavigationSplitViewVisibility?

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ZStack {
                if appState.screen.isSettings {
                    SettingsSidebarView(selection: $appState.screen)
                } else {
                    SidebarView()
                }
            }
            .navigationSplitViewColumnWidth(
                min: AppLayout.sidebarMinimumWidth,
                ideal: AppLayout.sidebarIdealWidth,
                max: AppLayout.sidebarMaximumWidth
            )
        } detail: {
            switch appState.screen {
            case .chat:
                ChatView()
            default:
                SettingsDetailView(screen: appState.screen)
            }
        }
        .sheet(item: activeSheet) { item in
            switch item {
            case .permission(let approval):
                PermissionApprovalView(approval: approval)
            case .appApproval(let appApproval):
                ComputerUseAppApprovalView(pending: appApproval)
            case .mcpCredential(let credRequest):
                MCPCredentialPromptView(request: credRequest)
            }
        }
        .environment(\.font, AppTypography.interface)
        .onChange(of: workSurfaceFillsWindow) { _, fills in
            if fills {
                visibilityBeforeExpanding = columnVisibility
                withAnimation { columnVisibility = .detailOnly }
            } else if let previous = visibilityBeforeExpanding {
                visibilityBeforeExpanding = nil
                withAnimation { columnVisibility = previous }
            }
        }
    }

    private var workSurfaceFillsWindow: Bool {
        !appState.screen.isSettings && appState.workSurface.isPresented && appState.workSurface.coverage == .window
    }

    private enum ActiveSheet: Identifiable {
        case permission(PendingApproval)
        case appApproval(ComputerUseAppApprovalPending)
        case mcpCredential(MCPCredentialRequest)

        var id: String {
            switch self {
            case .permission(let p): return "perm-\(p.id)"
            case .appApproval(let a): return "app-\(a.id)"
            case .mcpCredential(let c): return "mcp-cred-\(c.id)"
            }
        }
    }

    private var activeSheet: Binding<ActiveSheet?> {
        Binding(
            get: {
                if let appApproval = appState.computerUseAppAuthorization.pendingApproval {
                    return .appApproval(appApproval)
                }
                if let permission = appState.permissions.pendingApproval {
                    return .permission(permission)
                }
                if let cred = appState.mcp.pendingCredentialRequest {
                    return .mcpCredential(cred)
                }
                return nil
            },
            set: { newValue in
                if newValue == nil {
                    if let pending = appState.computerUseAppAuthorization.pendingApproval {
                        appState.computerUseAppAuthorization.resolvePendingApproval(id: pending.id, approved: false)
                    }
                    if let perm = appState.permissions.pendingApproval {
                        appState.permissions.resolvePendingApproval(id: perm.id, approved: false)
                    }
                    if let cred = appState.mcp.pendingCredentialRequest {
                        appState.mcp.resolveCredentialRequest(id: cred.id, credential: nil)
                    }
                }
            }
        )
    }
}

private struct PermissionApprovalView: View {
    @Environment(AppState.self) private var appState
    let approval: PendingApproval

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: approval.isHighRisk ? "exclamationmark.triangle.fill" : "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(approval.isHighRisk ? AppColors.statusError : AppColors.statusWarning)
                Text("Approval Required")
                    .font(.title2.weight(.semibold))
            }

            Text(approval.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    HStack {
                        Text("Tool:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(approval.toolName)
                            .font(.caption.monospaced())
                    }

                    if let title = approval.conversationTitle, !title.isEmpty {
                        HStack(alignment: .top) {
                            Text("Conversation:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(title)
                                .font(.caption)
                        }
                    }

                    if !approval.affectedPaths.isEmpty {
                        HStack(alignment: .top) {
                            Text("Paths:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(approval.affectedPaths.joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if let command = approval.command, !command.isEmpty {
                        HStack(alignment: .top) {
                            Text("Command:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }

                    if approval.requestsNetwork {
                        HStack {
                            Text("Network:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Label("May access external network", systemImage: "network")
                                .font(.caption)
                                .foregroundStyle(AppColors.statusWarning)
                        }
                    }

                    if !approval.environmentKeys.isEmpty {
                        HStack(alignment: .top) {
                            Text("Env Keys:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Text("\(approval.environmentKeys.joined(separator: ", ")) (values hidden)")
                                .font(.caption.monospaced())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.xxSmall)
            } label: {
                Text("Request Details")
                    .font(.caption.weight(.medium))
            }

            HStack {
                Spacer()
                Button("Deny", role: .cancel) {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: false)
                }
                Button("Allow Once") {
                    appState.permissions.resolvePendingApproval(id: approval.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(minWidth: AppLayout.approvalMinimumWidth, idealWidth: AppLayout.approvalIdealWidth)
        .interactiveDismissDisabled()
    }
}

private struct ComputerUseAppApprovalView: View {
    @Environment(AppState.self) private var appState
    let pending: ComputerUseAppApprovalPending

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(AppColors.statusWarning)
                Text("Authorize App Control")
                    .font(.title2.weight(.semibold))
            }

            Text("Allow Limare to CONTROL this App for the current conversation.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Text("Active desktop control allows Limare to synthesize keyboard and mouse events into this application. This bounds the scope of control, not display visibility.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    HStack {
                        Text("Application:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(pending.appLocalizedName)
                            .font(.caption.weight(.medium))
                            .accessibilityIdentifier("computerUse.appApproval.appName")
                    }

                    HStack {
                        Text("Bundle ID:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text(pending.bundleID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("computerUse.appApproval.bundleID")
                    }

                    HStack {
                        Text("Scope:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        Text("Active conversation only (cleared on exit)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.xxSmall)
            }

            HStack {
                Button("Block for this conversation", role: .cancel) {
                    appState.computerUseAppAuthorization.resolvePendingApproval(id: pending.id, approved: false)
                }
                .accessibilityIdentifier("computerUse.appApproval.blockConversation")

                Spacer()

                Button("Allow for this conversation") {
                    appState.computerUseAppAuthorization.resolvePendingApproval(id: pending.id, approved: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("computerUse.appApproval.allowConversation")
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(minWidth: AppLayout.approvalMinimumWidth, idealWidth: AppLayout.approvalIdealWidth)
        .accessibilityIdentifier("computerUse.appApproval.sheet")
        .interactiveDismissDisabled()
    }
}
