import SwiftUI
import AppKit

struct RecoveryBannerView: View {
    @Environment(AppState.self) private var appState

    private var activeConversationID: UUID? {
        appState.conversations.activeConversationID
    }

    var body: some View {
        if let convID = activeConversationID,
           appState.conversationRuns.hasInterruptedRun(for: convID) {
            let record = appState.conversationRuns.interruptedRunRecord(for: convID)
            let blocked = appState.conversationRuns.isRecoveryBlocked(for: convID)

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: AppSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.orange)

                    if blocked.isDirectoryMissing {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Previous working directory is unavailable.")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.primary)
                            if let path = record?.workingDirectorySnapshot.path {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else if blocked.isModelUnavailable {
                        Text("Previous model is unavailable.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                    } else {
                        Text("Previous run was interrupted.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.primary)
                    }

                    Spacer()

                    if blocked.isDirectoryMissing {
                        Button("Choose Folder…") {
                            chooseDirectory(for: convID)
                        }
                        .controlSize(.small)

                        if let currentURL = currentWorkspaceURL(for: convID),
                           FileManager.default.fileExists(atPath: currentURL.path),
                           currentURL != record?.workingDirectorySnapshot {
                            Button("Use Current Folder") {
                                appState.conversationRuns.startRecoveryRun(
                                    conversationID: convID,
                                    overrideWorkingDirectory: currentURL
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Discard") {
                            appState.conversationRuns.discardRecovery(conversationID: convID)
                        }
                        .controlSize(.small)
                    } else if blocked.isModelUnavailable {
                        if let currentModelSource = appState.conversations.activeConversation?.effectiveModelSource,
                           appState.conversationRuns.isModelSourceAvailable(currentModelSource) {
                            Button("Use Current Model") {
                                appState.conversationRuns.startRecoveryRun(
                                    conversationID: convID,
                                    overrideModelSource: currentModelSource
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("Discard") {
                            appState.conversationRuns.discardRecovery(conversationID: convID)
                        }
                        .controlSize(.small)
                    } else {
                        Button("Continue") {
                            appState.conversationRuns.startRecoveryRun(conversationID: convID)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Discard") {
                            appState.conversationRuns.discardRecovery(conversationID: convID)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, AppSpacing.standard)
                .padding(.vertical, AppSpacing.small)
                .background(Color.orange.opacity(0.12))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundStyle(Color.orange.opacity(0.25)),
                    alignment: .bottom
                )
            }
        }
    }

    private func currentWorkspaceURL(for conversationID: UUID) -> URL? {
        let conv = appState.conversations.conversations.first(where: { $0.id == conversationID })
        let parentProj = conv.flatMap { appState.conversations.project(for: $0) }
        return conv?.workspace?.url ?? parentProj?.workspace?.url
    }

    private func chooseDirectory(for conversationID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let selectedURL = panel.url else { return }
            appState.conversationRuns.startRecoveryRun(
                conversationID: conversationID,
                overrideWorkingDirectory: selectedURL
            )
        }
    }
}
