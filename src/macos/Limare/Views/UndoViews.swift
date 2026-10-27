import SwiftUI

/// Identifies the user message whose undo is being previewed.
struct UndoRequest: Identifiable, Equatable {
    let messageID: UUID
    var id: UUID { messageID }
}

/// Preview and confirmation of undoing the last user message: which files come back, which
/// effects cannot be undone, and conflicts that block the file restore.
struct UndoMessageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @Environment(\.dismiss) private var dismiss
    let messageID: UUID
    @State private var includeLeftovers = false
    @State private var selectedOptional: Set<String> = []

    private var preview: UndoPreview? {
        window.chat.undoPreview(for: messageID, includeLeftovers: includeLeftovers)
    }

    private var workspaceRoot: String? {
        guard let id = window.conversationID else { return nil }
        return appState.conversations.effectiveWorkingDirectory(for: id).standardizedFileURL.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Undo This Message")
                .font(.title3.weight(.semibold))
            Text("This message and the replies after it are removed, and the message goes back to the composer.")
                .foregroundStyle(.secondary)

            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.medium) {
                        content(for: preview)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Retract Message Only") {
                    window.chat.undoLastUserMessage(messageID, restoreFiles: false)
                    dismiss()
                }
                .accessibilityIdentifier("undo.retractOnly")
                if let preview, preview.hasFileChanges {
                    Button("Undo and Restore Files") {
                        window.chat.undoLastUserMessage(messageID, restoreFiles: true, includeLeftovers: includeLeftovers, optionalPaths: selectedOptional)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.isBlocked)
                    .accessibilityIdentifier("undo.restoreAndRetract")
                }
            }
        }
        .padding(AppSpacing.large)
        .frame(width: 520)
    }

    @ViewBuilder
    private func content(for preview: UndoPreview) -> some View {
        if !preview.conflicts.isEmpty {
            section("Can't Be Restored Safely", tint: .red) {
                ForEach(preview.conflicts) { conflict in
                    row(display(conflict.path), detail: reasonText(conflict.reason))
                }
            }
            if preview.canIncludeLeftovers || preview.includesLeftovers {
                Toggle("Also restore file changes left by retracted messages", isOn: $includeLeftovers)
                    .accessibilityIdentifier("undo.includeLeftovers")
            }
        }
        if !preview.missingBackups.isEmpty {
            section("Backups were cleaned up; only the message can be retracted", tint: .orange) {
                ForEach(preview.missingBackups, id: \.self) { path in row(display(path), detail: nil) }
            }
        }
        if !preview.willRestore.isEmpty {
            section("Will Restore (\(preview.willRestore.count))", tint: .accentColor) {
                ForEach(preview.willRestore) { item in row(display(item.path), detail: kindText(item.kind)) }
            }
        }
        if !preview.optional.isEmpty {
            section("Optional (source uncertain, not selected by default)", tint: .secondary) {
                ForEach(preview.optional) { item in
                    Toggle(isOn: Binding(
                        get: { selectedOptional.contains(item.path) },
                        set: { if $0 { selectedOptional.insert(item.path) } else { selectedOptional.remove(item.path) } }
                    )) {
                        row(display(item.path), detail: "\(kindText(item.kind)) · \(item.source)")
                    }
                }
            }
        }
        if !preview.irreversible.isEmpty {
            section("Can't Be Undone (\(preview.irreversible.count))", tint: .secondary) {
                ForEach(preview.irreversible) { effect in row(effect.title, detail: effect.detail) }
            }
        }
        if !preview.hasFileChanges && preview.irreversible.isEmpty && preview.conflicts.isEmpty && preview.missingBackups.isEmpty {
            Text("No file changes were recorded in this turn.")
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            content()
        }
    }

    private func row(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func display(_ path: String) -> String {
        guard let root = workspaceRoot, path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private func kindText(_ kind: UndoRestoreItem.Kind) -> String {
        switch kind {
        case .removeCreated: String(localized: "Delete the file created in this turn")
        case .restoreContent: String(localized: "Restore the content from before the change")
        case .recreateDeleted: String(localized: "Restore the deleted file")
        }
    }

    private func reasonText(_ reason: UndoConflictReason) -> String {
        switch reason {
        case .modifiedSinceChange: String(localized: "The file was modified afterward")
        case .modifiedBetweenChanges: String(localized: "Something else changed the file between this turn's two edits")
        case .pathRedirected: String(localized: "A parent folder was replaced by a symbolic link or file, so restoring would write elsewhere")
        case .leftoverChanges: String(localized: "File changes from retracted messages haven't been restored")
        }
    }
}

/// Shown while an undo is unfinished: some files could not be restored, or the files are back
/// but the message is not retracted yet. Lists which files are restored and which are not, and
/// offers the exits; new runs wait until it is resolved. After a cancel, says what stayed.
struct UndoPlanBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    var body: some View {
        if let plan = window.chat.openUndoPlan {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(Color.orange)
                    Text(title(for: plan)).font(.subheadline.weight(.medium))
                    Spacer()
                    switch plan.phase {
                    case .partiallyFailed:
                        Button("Retry") { window.chat.resolveOpenUndo(.retry) }
                            .controlSize(.small)
                        Button("Keep Restored Files and Retract Message") { window.chat.resolveOpenUndo(.keepAndRetract) }
                            .controlSize(.small)
                        Button("Cancel Undo") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                            .help("Stop restoring: restored files stay as they are, the rest are not restored, and the message is kept")
                            .accessibilityIdentifier("undo.cancelPlan")
                    case .filesRestored:
                        Button("Finish Retracting") { window.chat.resolveOpenUndo(.retry) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Keep Message") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                            .help("Don't retract the message: restored files stay as they are, and the message is kept")
                            .accessibilityIdentifier("undo.keepMessage")
                    default:
                        Button("Continue") { window.chat.resolveOpenUndo(.retry) }
                            .controlSize(.small)
                        Button("Cancel Undo") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                    }
                }
                pathList(restored: plan.steps.filter { $0.state == .done }.map { ($0.path, nil) })
                pathList(unrestored: plan.steps.filter { $0.state != .done }.map { ($0.path, $0.failure) })
            }
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.small)
            .background(Color.orange.opacity(0.12))
            .accessibilityIdentifier("undo.planBanner")
        } else if let conversationID = window.conversationID,
                  let cancellation = appState.undo.cancellations[conversationID] {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Undo was cancelled and the message kept. Restored files stay as they are; the rest were not restored.").font(.caption)
                    Spacer()
                    Button { appState.undo.dismissCancellation(conversationID: conversationID) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Close")
                }
                pathList(restored: cancellation.restoredPaths.map { ($0, nil) })
                pathList(unrestored: cancellation.unrestoredPaths.map { ($0, nil) })
            }
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.xSmall)
            .accessibilityIdentifier("undo.cancellation")
        }
    }

    private func pathList(restored items: [(String, String?)]) -> some View {
        pathList("Restored (\(items.count))", items)
    }

    private func pathList(unrestored items: [(String, String?)]) -> some View {
        pathList("Not Restored (\(items.count))", items)
    }

    @ViewBuilder
    private func pathList(_ heading: LocalizedStringKey, _ items: [(String, String?)]) -> some View {
        if !items.isEmpty {
            Text(heading).font(.caption.weight(.medium))
            ForEach(items, id: \.0) { path, note in
                Text(note.map { "\(path) — \($0)" } ?? path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func title(for plan: UndoRestorePlan) -> String {
        switch plan.phase {
        case .partiallyFailed: String(localized: "Undo isn't finished: \(plan.failedSteps.count) files couldn't be restored")
        case .filesRestored: String(localized: "Files are restored, but the message isn't retracted yet")
        default: String(localized: "Undo isn't finished")
        }
    }
}
