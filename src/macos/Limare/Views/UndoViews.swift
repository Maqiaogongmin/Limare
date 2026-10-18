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
            Text("撤销这条消息")
                .font(.title3.weight(.semibold))
            Text("这条消息和之后的回复会被移除，消息回到输入框。")
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
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("只撤回消息") {
                    window.chat.undoLastUserMessage(messageID, restoreFiles: false)
                    dismiss()
                }
                .accessibilityIdentifier("undo.retractOnly")
                if let preview, preview.hasFileChanges {
                    Button("撤销并恢复文件") {
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
            section("不能安全恢复", tint: .red) {
                ForEach(preview.conflicts) { conflict in
                    row(display(conflict.path), detail: reasonText(conflict.reason))
                }
            }
            if preview.canIncludeLeftovers || preview.includesLeftovers {
                Toggle("一并恢复已撤回消息遗留的文件改动", isOn: $includeLeftovers)
                    .accessibilityIdentifier("undo.includeLeftovers")
            }
        }
        if !preview.missingBackups.isEmpty {
            section("备份已清理，只能撤回消息", tint: .orange) {
                ForEach(preview.missingBackups, id: \.self) { path in row(display(path), detail: nil) }
            }
        }
        if !preview.willRestore.isEmpty {
            section("将恢复（\(preview.willRestore.count)）", tint: .accentColor) {
                ForEach(preview.willRestore) { item in row(display(item.path), detail: kindText(item.kind)) }
            }
        }
        if !preview.optional.isEmpty {
            section("可选恢复（来源不确定，默认不选）", tint: .secondary) {
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
            section("无法撤销（\(preview.irreversible.count)）", tint: .secondary) {
                ForEach(preview.irreversible) { effect in row(effect.title, detail: effect.detail) }
            }
        }
        if !preview.hasFileChanges && preview.irreversible.isEmpty && preview.conflicts.isEmpty && preview.missingBackups.isEmpty {
            Text("这一轮没有记录到文件改动。")
                .foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
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
        case .removeCreated: "删除这一轮新建的文件"
        case .restoreContent: "还原为修改前的内容"
        case .recreateDeleted: "恢复被删除的文件"
        }
    }

    private func reasonText(_ reason: UndoConflictReason) -> String {
        switch reason {
        case .modifiedSinceChange: "该文件在之后被修改过"
        case .modifiedBetweenChanges: "这一轮的两次修改之间，文件被其他操作改过"
        case .pathRedirected: "上级目录被替换成了符号链接或文件，恢复会写到别处"
        case .leftoverChanges: "已撤回消息的文件改动尚未恢复"
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
                        Button("重试") { window.chat.resolveOpenUndo(.retry) }
                            .controlSize(.small)
                        Button("保留已恢复的文件并撤回消息") { window.chat.resolveOpenUndo(.keepAndRetract) }
                            .controlSize(.small)
                        Button("取消撤销") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                            .help("停止恢复：已恢复的文件保持现状，其余文件不再恢复，消息保留")
                            .accessibilityIdentifier("undo.cancelPlan")
                    case .filesRestored:
                        Button("完成撤回") { window.chat.resolveOpenUndo(.retry) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("保留消息") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                            .help("不再撤回消息：已恢复的文件保持现状，消息保留")
                            .accessibilityIdentifier("undo.keepMessage")
                    default:
                        Button("继续") { window.chat.resolveOpenUndo(.retry) }
                            .controlSize(.small)
                        Button("取消撤销") { window.chat.resolveOpenUndo(.cancel) }
                            .controlSize(.small)
                    }
                }
                pathList("已恢复", plan.steps.filter { $0.state == .done }.map { ($0.path, nil) })
                pathList("未恢复", plan.steps.filter { $0.state != .done }.map { ($0.path, $0.failure) })
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
                    Text("撤销已取消，消息保留。已恢复的文件保持现状，其余文件未恢复。").font(.caption)
                    Spacer()
                    Button { appState.undo.dismissCancellation(conversationID: conversationID) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("关闭")
                }
                pathList("已恢复", cancellation.restoredPaths.map { ($0, nil) })
                pathList("未恢复", cancellation.unrestoredPaths.map { ($0, nil) })
            }
            .padding(.horizontal, AppSpacing.standard)
            .padding(.vertical, AppSpacing.xSmall)
            .accessibilityIdentifier("undo.cancellation")
        }
    }

    @ViewBuilder
    private func pathList(_ heading: String, _ items: [(String, String?)]) -> some View {
        if !items.isEmpty {
            Text("\(heading)（\(items.count)）").font(.caption.weight(.medium))
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
        case .partiallyFailed: "撤销未完成：\(plan.failedSteps.count) 个文件未能恢复"
        case .filesRestored: "文件已恢复，消息尚未撤回"
        default: "撤销未完成"
        }
    }
}
