import AppKit
import SwiftUI

/// Schedules' state in one window: which task is open, the editor when one is shown, a task
/// waiting for delete confirmation, and an error to show.
@MainActor
@Observable
final class ScheduledPanelState {
    var selectedTaskID: UUID?
    var editing: ScheduledTaskEditor.Mode?
    var taskToDelete: ScheduledTask?
    var errorMessage: String?
}

/// Schedules in the window's detail column, beside the usual sidebar: a title bar with New
/// Task, then the tasks in a list card with the open one's detail under it, or, with no tasks,
/// a centred starting point with templates. It fills whatever size the window is given.
struct SchedulesWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    private var panel: ScheduledPanelState { window.scheduledPanel }
    private var scheduler: ScheduledScheduler { appState.scheduled }
    private var store: ScheduledStateStore { appState.scheduled.store }
    private var tasks: [ScheduledTask] { store.tasks.sorted { $0.createdAt > $1.createdAt } }

    /// The page's column, centred in the canvas.
    static let columnMaxWidth: CGFloat = 760

    var body: some View {
        @Bindable var panel = panel
        let tasks = tasks
        VStack(spacing: 0) {
            titleBar
            if !store.isReadable {
                notice(ScheduledTaskCopy.unreadable(path: store.fileURL.path), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    .accessibilityIdentifier("scheduled.unreadable")
            }
            let enabledCount = tasks.filter(\.isEnabled).count
            if enabledCount > ScheduledTaskCopy.manyEnabledThreshold {
                notice(ScheduledTaskCopy.manyEnabled(enabledCount), systemImage: "info.circle", tint: .secondary)
            }
            if tasks.isEmpty {
                ScheduledTasksEmptyState(onPick: create)
                    .offset(y: -20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.large) {
                        taskList(tasks)
                        if let task = panel.selectedTaskID.flatMap({ store.task(id: $0) }) {
                            ScheduledTaskDetail(task: task,
                                                onEdit: { panel.editing = .edit(task) },
                                                onDelete: { panel.taskToDelete = task },
                                                onError: { panel.errorMessage = $0 },
                                                onReveal: reveal)
                        } else {
                            VStack(alignment: .leading, spacing: AppSpacing.small) {
                                Text("从模板开始")
                                    .font(.system(size: 13, weight: .semibold))
                                ScheduledTemplateGrid(onPick: create)
                            }
                        }
                    }
                    .frame(maxWidth: Self.columnMaxWidth)
                    .padding(.horizontal, AppSpacing.xLarge)
                    .padding(.top, AppSpacing.small)
                    .padding(.bottom, AppSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                }
                .settingsScrollEdgeFade()
            }
        }
        .accessibilityIdentifier("scheduled.surface")
        .navigationTitle("定时任务")
        .toolbar(removing: .title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppColors.canvas.ignoresSafeArea())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .tint(AppColors.controlOn)
        .confirmationDialog("删除定时任务？", isPresented: Binding(get: { panel.taskToDelete != nil }, set: { if !$0 { panel.taskToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let task = panel.taskToDelete {
                    do { try scheduler.delete(taskID: task.id) } catch { panel.errorMessage = error.localizedDescription }
                    if panel.selectedTaskID == task.id { panel.selectedTaskID = nil }
                }
                panel.taskToDelete = nil
            }
            Button("取消", role: .cancel) { panel.taskToDelete = nil }
        } message: {
            Text("任务产生的会话和消息都会保留。")
        }
        .alert("操作未完成", isPresented: Binding(get: { panel.errorMessage != nil }, set: { if !$0 { panel.errorMessage = nil } })) {
            Button("好") { panel.errorMessage = nil }
        } message: {
            Text(panel.errorMessage ?? "")
        }
    }

    private var titleBar: some View {
        HStack(spacing: AppSpacing.small) {
            Text("定时任务")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: AppSpacing.small)
            Button {
                create(nil)
            } label: {
                HStack(spacing: AppSpacing.xxSmall) {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text("新建任务")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(store.isReadable ? AppColors.sendGlyph : Color.secondary)
                .padding(.horizontal, AppSpacing.medium)
                .frame(height: 28)
                .background(Capsule().fill(store.isReadable ? AppColors.sendFill : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!store.isReadable)
            .accessibilityIdentifier("scheduled.new")
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .frame(height: AppLayout.workspaceHeaderHeight)
    }

    private func taskList(_ tasks: [ScheduledTask]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 { SettingsDivider().padding(.horizontal, AppSpacing.medium) }
                ScheduledTaskRow(task: task, runs: store.runs(for: task.id), isSelected: panel.selectedTaskID == task.id,
                                 onSelect: {
                                     withAnimation(AppMotion.resolved(AppMotion.layout)) {
                                         panel.selectedTaskID = panel.selectedTaskID == task.id ? nil : task.id
                                     }
                                 }) { enabled in
                    do { try scheduler.setEnabled(enabled, taskID: task.id) } catch { panel.errorMessage = error.localizedDescription }
                }
            }
        }
        .padding(AppSpacing.xxSmall)
        .scheduledCard()
        .accessibilityIdentifier("scheduled.list")
    }

    private func create(_ template: ScheduledTaskTemplate?) {
        guard store.isReadable else { return }
        window.scheduledPanel.editing = .create(template)
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: Self.columnMaxWidth, alignment: .leading)
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.vertical, AppSpacing.xSmall)
            .frame(maxWidth: .infinity)
    }

    private func reveal(_ conversationID: UUID) {
        appState.focus(window)
        appState.reveal(conversationID: conversationID)
    }
}

/// One task in the list card: name, plan and status on the left, the enable switch on the
/// right; the open one on a warm tint, never the system blue.
struct ScheduledTaskRow: View {
    let task: ScheduledTask
    let runs: [ScheduledRun]
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(task.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.88))
                    .lineLimit(1)
                Text(ScheduledRuleDraft(schedule: task.schedule).summary(timeZoneID: task.timeZoneID))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AppSpacing.small)
            VStack(alignment: .trailing, spacing: AppSpacing.xxxSmall) {
                Text(ScheduledTaskPresentation.statusText(ScheduledTaskPresentation.status(task: task, runs: runs), timeZoneID: task.timeZoneID))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.primary.opacity(0.65))
                    .lineLimit(1)
                if let last = runs.first {
                    Text("上次：" + ScheduledTaskPresentation.runSummary(last))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Toggle("", isOn: Binding(get: { task.isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(AppColors.controlOn)
                .accessibilityLabel("启用 \(task.name)")
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.07) : (isHovering ? Color.primary.opacity(0.035) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityIdentifier("scheduled.row")
    }
}

/// A common task to start from: it opens the editor filled in.
struct ScheduledTaskTemplate: Identifiable, Equatable {
    let id: String
    let name: String
    let prompt: String
    let systemImage: String
    let kind: ScheduledRuleDraft.Kind
    let weekday: Int?
    let hour: Int
    let minute: Int

    var ruleDraft: ScheduledRuleDraft {
        var rule = ScheduledRuleDraft()
        rule.kind = kind
        rule.hour = hour
        rule.minute = minute
        if let weekday { rule.weekdays = [weekday] }
        return rule
    }

    var scheduleText: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .weekly:
            let day = ScheduledRuleDraft.weekdayTitles.first { $0.0 == weekday }?.1 ?? ""
            return "每周\(day) \(time)"
        default:
            return "\(kind.title) \(time)"
        }
    }

    static let common: [ScheduledTaskTemplate] = [
        ScheduledTaskTemplate(id: "codeReview", name: "每日代码巡检", prompt: "检查工作区最近一天的代码改动，列出可能的缺陷、遗留的 TODO 和需要补的测试。",
                              systemImage: "checklist", kind: .daily, weekday: nil, hour: 9, minute: 0),
        ScheduledTaskTemplate(id: "weeklyReport", name: "每周工作周报", prompt: "汇总本周工作区里的提交和改动，整理成一份简明的周报：完成了什么、进行中的事项、下周计划。",
                              systemImage: "doc.text", kind: .weekly, weekday: 6, hour: 17, minute: 0),
        ScheduledTaskTemplate(id: "dependencies", name: "依赖更新检查", prompt: "检查项目依赖是否有新版本或已知的安全公告，列出建议升级的依赖和升级风险。",
                              systemImage: "shippingbox", kind: .weekly, weekday: 2, hour: 10, minute: 0),
        ScheduledTaskTemplate(id: "digest", name: "每日资讯摘要", prompt: "整理今天我关心领域的重要资讯，每条一句话概括并附来源。",
                              systemImage: "newspaper", kind: .weekdays, weekday: nil, hour: 8, minute: 30),
    ]
}

/// No tasks yet: a clock badge, a title, the keep-running note and the templates.
private struct ScheduledTasksEmptyState: View {
    let onPick: (ScheduledTaskTemplate?) -> Void

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.raisedSurface)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AppColors.hairline, lineWidth: 1)
                Image(systemName: "clock")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            .frame(width: 56, height: 56)
            .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 2)

            VStack(spacing: AppSpacing.xSmall) {
                Text("让 Limare 按时替你做事")
                    .font(.system(size: 18, weight: .semibold))
                Text(ScheduledTaskCopy.keepRunningNote)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)

            ScheduledTemplateGrid(onPick: onPick)
                .frame(maxWidth: 520)
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .accessibilityIdentifier("scheduled.empty")
    }
}

/// The four templates, two by two.
private struct ScheduledTemplateGrid: View {
    let onPick: (ScheduledTaskTemplate?) -> Void

    var body: some View {
        Grid(horizontalSpacing: AppSpacing.medium, verticalSpacing: AppSpacing.medium) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(ScheduledTaskTemplate.common[(row * 2)..<(row * 2 + 2)]) { template in
                        TemplateCard(template: template) { onPick(template) }
                    }
                }
            }
        }
    }

    private struct TemplateCard: View {
        let template: ScheduledTaskTemplate
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: AppSpacing.small) {
                    Image(systemName: template.systemImage)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                        Text(template.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .lineLimit(1)
                        Text(template.scheduleText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: ScheduledCard.radius, style: .continuous)
                        .fill(AppColors.raisedSurface)
                        .shadow(color: .black.opacity(isHovering ? 0.05 : 0.02), radius: isHovering ? 6 : 2, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScheduledCard.radius, style: .continuous)
                        .strokeBorder(isHovering ? AppColors.composerStroke : AppColors.hairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
            .accessibilityIdentifier("scheduled.template")
        }
    }
}

/// A white card on the canvas with a hairline edge: the detail's sections and the editor's groups.
enum ScheduledCard {
    static let radius: CGFloat = 10
}

extension View {
    func scheduledCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: ScheduledCard.radius, style: .continuous)
                .fill(AppColors.raisedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScheduledCard.radius, style: .continuous)
                .strokeBorder(AppColors.cardStroke, lineWidth: 1)
        )
    }
}

/// A compact text action without chrome at rest, a faint tint under the pointer: the detail's
/// Edit, Duplicate and Delete.
struct ScheduledGhostButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, isDestructive: isDestructive)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let isDestructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isDestructive && isHovering ? AppColors.dangerText : Color.primary.opacity(isHovering ? 0.9 : 0.65))
                .padding(.horizontal, AppSpacing.small)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(isHovering || configuration.isPressed ? AppColors.ghostHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
                .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
        }
    }
}

/// The detail's main action: white with a hairline edge, charcoal text.
struct ScheduledOutlineButtonStyle: ButtonStyle {
    var radius: CGFloat = AppRadius.control

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, radius: radius)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(isEnabled ? 0.88 : 0.4))
                .padding(.horizontal, AppSpacing.medium)
                .frame(height: 28)
                .background(shape.fill(configuration.isPressed || isHovering && isEnabled ? Color.primary.opacity(0.04) : Color.clear).background(shape.fill(AppColors.raisedSurface)))
                .overlay(shape.strokeBorder(AppColors.composerStroke, lineWidth: 1))
                .contentShape(shape)
                .onHover { isHovering = $0 }
        }
    }
}

/// The editor's confirm: charcoal, white text, 8pt corners.
struct ScheduledCharcoalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? AppColors.sendGlyph : Color.secondary)
                .padding(.horizontal, AppSpacing.standard)
                .frame(height: 28)
                .background(shape.fill(isEnabled ? AppColors.sendFill : Color.primary.opacity(0.06)))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(shape)
        }
    }
}

/// Header with status and actions; the instruction in its own card; plan, target, model and
/// notifications as a 2x2 grid; the run history in a list card.
struct ScheduledTaskDetail: View {
    @Environment(AppState.self) private var appState
    let task: ScheduledTask
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onError: (String) -> Void
    let onReveal: (UUID) -> Void

    private var scheduler: ScheduledScheduler { appState.scheduled }
    private var runs: [ScheduledRun] { scheduler.store.runs(for: task.id) }
    private var anotherRunActive: Bool { scheduler.store.pendingCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            header
            if anotherRunActive {
                Text(ScheduledTaskCopy.anotherRunActive).font(.caption).foregroundStyle(.secondary)
            }
            if appState.permissions.mode == .fullAccess {
                ScheduledFullAccessWarning()
            }

            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                sectionLabel("指令")
                Text(task.prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(AppSpacing.standard)
            .scheduledCard()

            settingsGrid

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text("运行历史")
                    .font(.system(size: 13, weight: .semibold))
                VStack(spacing: 0) {
                    if runs.isEmpty {
                        Text("还没有运行")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.medium)
                    } else {
                        ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                            if index > 0 { SettingsDivider().padding(.horizontal, AppSpacing.medium) }
                            historyRow(run)
                        }
                    }
                }
                .scheduledCard()
            }
            .padding(.top, AppSpacing.xSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("scheduled.detail")
    }

    /// Name and status, then the actions; the actions take a line of their own when the
    /// column is too narrow for both.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppSpacing.small) {
                title
                Spacer(minLength: AppSpacing.medium)
                actions
            }
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                title
                HStack(spacing: AppSpacing.small) {
                    actions
                }
            }
        }
    }

    private var title: some View {
        HStack(spacing: AppSpacing.small) {
            Text(task.name)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            statusCapsule
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("编辑", action: onEdit)
            .buttonStyle(ScheduledGhostButtonStyle())
        Button("复制") {
            do { _ = try scheduler.duplicate(taskID: task.id, name: task.name + " 副本") } catch { onError(error.localizedDescription) }
        }
        .buttonStyle(ScheduledGhostButtonStyle())
        Button("删除", action: onDelete)
            .buttonStyle(ScheduledGhostButtonStyle(isDestructive: true))
        Button {
            do { try scheduler.runNow(taskID: task.id) } catch { onError(String(describing: error)) }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: "play.fill").font(.system(size: 9))
                Text("立即运行")
            }
        }
        .buttonStyle(ScheduledOutlineButtonStyle())
        .disabled(anotherRunActive || !scheduler.store.isReadable)
        .help(anotherRunActive ? ScheduledTaskCopy.anotherRunActive : "按无人值守方式立即运行一次")
        .accessibilityIdentifier("scheduled.runNow")
    }


    private var statusCapsule: some View {
        let status = ScheduledTaskPresentation.status(task: task, runs: runs)
        let isActive: Bool = {
            switch status {
            case .next, .running: return true
            default: return false
            }
        }()
        return HStack(spacing: AppSpacing.xxSmall) {
            Circle()
                .fill(isActive ? AppColors.positiveText : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(ScheduledTaskPresentation.statusText(status, timeZoneID: task.timeZoneID))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.small)
        .frame(height: 20)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }

    private var settingsGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cell("执行计划") {
                    Text(planText)
                    if let next = task.nextNominalAt {
                        Text("下次：" + ScheduledTaskPresentation.timeWithZone(next, timeZoneID: task.timeZoneID))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                columnRule
                cell("运行目标") { targetView }
            }
            GridRow {
                SettingsDivider().gridCellColumns(3)
            }
            GridRow {
                cell("模型配置") { Text(ScheduledModelLabel.text(task: task, appState: appState)) }
                columnRule
                cell("通知规则") { Text(task.notifyOn == .completionAndFailure ? "完成和失败" : "仅失败") }
            }
        }
        .scheduledCard()
    }

    private var planText: String {
        ScheduledRuleDraft(schedule: task.schedule).summary(timeZoneID: task.timeZoneID)
    }

    private var columnRule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 1)
            .gridCellUnsizedAxes(.vertical)
    }

    private func cell<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            sectionLabel(title)
            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                content()
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.primary.opacity(0.9))
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var targetView: some View {
        switch task.target {
        case .newConversation(let projectID):
            Text("每次新建会话 · " + (projectID.flatMap { id in appState.conversations.projects.first { $0.id == id }?.name } ?? (projectID == nil ? "默认工作区" : "项目已删除")))
        case .conversation(let id):
            if let conversation = appState.conversations.conversations.first(where: { $0.id == id }) {
                Button { onReveal(id) } label: {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Text(conversation.title).lineLimit(1)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(QuietLinkButtonStyle())
            } else {
                Text("会话已删除").foregroundStyle(.secondary)
            }
        }
    }

    private func historyRow(_ run: ScheduledRun) -> some View {
        HStack(spacing: AppSpacing.small) {
            Circle()
                .fill(runTint(run.status))
                .frame(width: 6, height: 6)
            Text(ScheduledTaskPresentation.fullDate(run.claimedAt, timeZoneID: task.timeZoneID))
                .font(.system(size: 12).monospacedDigit())
            Text(ScheduledTaskPresentation.triggerText(run.trigger))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(ScheduledTaskPresentation.runSummary(run))
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: AppSpacing.small)
            if let conversationID = run.conversationID, appState.conversations.conversations.contains(where: { $0.id == conversationID }) {
                Button { onReveal(conversationID) } label: {
                    HStack(spacing: 3) {
                        Text("打开会话")
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                    }
                }
                .buttonStyle(OpenConversationPillStyle())
            }
        }
        .padding(.horizontal, AppSpacing.medium)
        .frame(minHeight: 38)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduled.history.row")
    }

    private func runTint(_ status: ScheduledRun.Status) -> Color {
        switch status {
        case .completed: AppColors.positiveText
        case .failed, .interrupted: AppColors.dangerText
        case .pending: Color.orange
        case .skipped, .cancelled: Color.secondary.opacity(0.5)
        }
    }
}

/// "打开会话 ↗": a small charcoal outlined capsule, never the link blue.
private struct OpenConversationPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
                .padding(.horizontal, AppSpacing.small)
                .frame(height: 22)
                .background(Capsule().fill(isHovering || configuration.isPressed ? Color.primary.opacity(0.05) : .clear))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
                .contentShape(Capsule())
                .onHover { isHovering = $0 }
        }
    }
}

struct ScheduledFullAccessWarning: View {
    var body: some View {
        Label(ScheduledTaskCopy.fullAccessWarning, systemImage: "exclamationmark.shield")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("scheduled.fullAccessWarning")
    }
}

/// The editor over the whole window: a dimmed layer and the card centred in it. Drawn in the
/// window rather than as a sheet, which macOS places itself (low in a tall window). Clicks
/// behind it are held; Esc and × close it.
struct ScheduledEditorModal: View {
    @Environment(WindowSession.self) private var window
    let mode: ScheduledTaskEditor.Mode

    private static let radius: CGFloat = 14
    private static let margin: CGFloat = 24

    /// The form's own height, so the card hugs it and scrolls only when the window is shorter.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let panel = window.scheduledPanel
        GeometryReader { proxy in
            let available = max(proxy.size.height - 2 * Self.margin, 120)
            ZStack {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                ScrollView {
                    ScheduledTaskEditor(mode: mode, onClose: close) { saved in panel.selectedTaskID = saved.id }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            withAnimation(AppMotion.resolved(ScheduledTaskEditor.disclosure)) { contentHeight = height }
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: ScheduledTaskEditor.width, height: contentHeight > 0 ? min(contentHeight, available) : nil)
                .background(AppColors.canvas)
                .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(AppColors.raisedStroke, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 10)
                .accessibilityAddTraits(.isModal)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("scheduled.editor")
    }

    private func close() {
        withAnimation(AppMotion.resolved(AppMotion.standard)) { window.scheduledPanel.editing = nil }
    }
}

/// A time (or date and time) as compact monospaced digits on a faint 6pt tint: the AppKit
/// field without its bezel, which SwiftUI's field-style picker always draws.
struct ScheduledTimeField: NSViewRepresentable {
    @Binding var selection: Date
    let includesDate: Bool
    var range: ClosedRange<Date>?

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        picker.textColor = .labelColor
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        picker.datePickerElements = includesDate ? [.yearMonthDay, .hourMinute] : [.hourMinute]
        picker.minDate = range?.lowerBound
        picker.maxDate = range?.upperBound
        if picker.dateValue != selection { picker.dateValue = selection }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: ScheduledTimeField
        init(parent: ScheduledTimeField) { self.parent = parent }

        @MainActor @objc func changed(_ sender: NSDatePicker) {
            parent.selection = sender.dateValue
        }
    }
}

extension ScheduledTimeField {
    /// The field on its tint, as the time row shows it.
    var tinted: some View {
        fixedSize()
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// A form row's choice as bare text with a small chevron: no control fill at rest, a faint
/// tint under the pointer; the menu ticks the current value.
struct ScheduledMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]

    @State private var isHovering = false

    init(_ title: String, selection: Binding<Value>, options: [(String, Value)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    private var currentLabel: String {
        options.first { $0.1 == selection }?.0 ?? "—"
    }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.1
                } label: {
                    if option.1 == selection {
                        Label(option.0, systemImage: "checkmark")
                    } else {
                        Text(option.0)
                    }
                }
            }
        } label: {
            HStack(spacing: AppSpacing.xxSmall) {
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, AppSpacing.small)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: 260, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { isHovering = $0 }
        .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
        .accessibilityLabel(title)
        .accessibilityValue(currentLabel)
    }
}

/// The model and effort a task's runs use: its own for a new conversation, the conversation's otherwise.
@MainActor
enum ScheduledModelLabel {
    static func effort(_ level: ThinkingLevel?) -> String {
        guard let level else { return "默认" }
        return level.rawValue.prefix(1).uppercased() + level.rawValue.dropFirst()
    }

    static func text(task: ScheduledTask, appState: AppState) -> String {
        let providers = appState.providers.providers
        switch task.target {
        case .newConversation:
            let model = task.modelSource.map { ModelChoiceCatalog.label(for: $0, modelGroups: appState.modelGroups, providers: providers) } ?? "默认"
            return "\(model) · \(effort(task.thinkingLevel))"
        case .conversation(let id):
            let conversation = appState.conversations.conversations.first { $0.id == id }
            let source = ModelChoiceCatalog.currentModelSource(conversation: conversation, modelGroups: appState.modelGroups, providers: appState.providers)
            return ScheduledTaskCopy.followsConversation(
                model: ModelChoiceCatalog.label(for: source, modelGroups: appState.modelGroups, providers: providers),
                effort: effort(conversation?.thinkingLevelOverride))
        }
    }
}

/// The one sheet of the manager: name and instruction, repeat and time, and the rarely changed
/// target, model, effort and notifications behind 高级.
struct ScheduledTaskEditor: View {
    enum Mode: Identifiable {
        /// A new task, filled in from a template when there is one.
        case create(ScheduledTaskTemplate?)
        case edit(ScheduledTask)
        var id: String {
            switch self {
            case .create(let template): "create-" + (template?.id ?? "")
            case .edit(let task): task.id.uuidString
            }
        }
    }

    enum TargetKind: String, CaseIterable, Identifiable {
        case newConversation, conversation
        var id: String { rawValue }
    }

    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @AppStorage(BackgroundActivityNotifier.enabledKey) private var backgroundAlerts = false

    let mode: Mode
    let onClose: () -> Void
    let onSaved: (ScheduledTask) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var rule = ScheduledRuleDraft()
    @State private var timeOfDay = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var targetKind: TargetKind = .newConversation
    @State private var projectID: UUID?
    @State private var conversationID: UUID?
    @State private var modelSource: ConversationModelSource?
    @State private var thinkingLevel: ThinkingLevel?
    @State private var notifyOn: ScheduledTask.NotifyOn = .completionAndFailure
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var showsAdvanced = false
    @FocusState private var nameFocused: Bool

    static let width: CGFloat = 480
    /// Every card's text starts this far in: name, instruction, and each row's label.
    static let cardInset: CGFloat = 14
    /// The instruction editor already sets its text this far in (the line fragment padding).
    private static let textEditorInset: CGFloat = 5
    private static let rowHeight: CGFloat = 40
    static let disclosure = Animation.spring(response: 0.28, dampingFraction: 0.84)

    private var existing: ScheduledTask? {
        if case .edit(let task) = mode { return task }
        return nil
    }

    private var timeZoneID: String { existing?.timeZoneID ?? TimeZone.current.identifier }

    private var target: ScheduledTask.Target? {
        switch targetKind {
        case .newConversation: return .newConversation(projectID: projectID)
        case .conversation: return conversationID.map { .conversation(id: $0) }
        }
    }

    private var draftSchedule: ScheduledTask.Schedule {
        var rule = rule
        let parts = Calendar.current.dateComponents([.hour, .minute], from: timeOfDay)
        rule.hour = parts.hour ?? 9
        rule.minute = parts.minute ?? 0
        return rule.schedule(timeZoneID: timeZoneID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            header
            instructionCard
            scheduleCard
            if ScheduledTaskPresentation.isShortPeriod(draftSchedule, timeZoneID: timeZoneID) {
                Text(ScheduledTaskCopy.shortPeriodWarning).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            advanced
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11.5)).foregroundStyle(AppColors.dangerText)
            }
            footer
        }
        .padding(AppSpacing.large)
        .frame(width: Self.width)
        .onAppear {
            load()
            nameFocused = true
        }
        // Focusing a field selects its text; the caret goes to the end instead.
        .onChange(of: nameFocused) { _, focused in
            guard focused, let editor = window.hostWindow?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    private var header: some View {
        HStack {
            Text(existing == nil ? "设置定时任务" : "编辑定时任务")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(GhostIconButtonStyle(size: 24, iconSize: 11))
            .keyboardShortcut(.cancelAction)
            .help("关闭")
        }
    }

    private var instructionCard: some View {
        VStack(spacing: 0) {
            TextField("任务名称（如：每日代码巡检）", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .focused($nameFocused)
                .padding(.horizontal, Self.cardInset)
                .frame(height: Self.rowHeight)
                .accessibilityIdentifier("scheduled.form.name")
            SettingsDivider()
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("输入需要 Limare 定时执行的指令说明...")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Self.textEditorInset)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .accessibilityIdentifier("scheduled.form.prompt")
            }
            .frame(height: 90)
            .padding(.horizontal, Self.cardInset - Self.textEditorInset)
            .padding(.vertical, AppSpacing.small)
        }
        .scheduledCard()
    }

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            formRow("重复") {
                ScheduledMenu("重复", selection: $rule.kind, options: ScheduledRuleDraft.Kind.allCases.map { ($0.title, $0) })
                    .accessibilityIdentifier("scheduled.form.repeat")
            }
            switch rule.kind {
            case .weekly:
                SettingsDivider()
                formRow("星期") {
                    HStack(spacing: 3) {
                        ForEach(ScheduledRuleDraft.weekdayTitles, id: \.0) { number, title in
                            let isOn = rule.weekdays.contains(number)
                            Button(title) {
                                if !isOn { rule.weekdays.insert(number) } else if rule.weekdays.count > 1 { rule.weekdays.remove(number) }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isOn ? AppColors.sendGlyph : Color.primary.opacity(0.7))
                            .frame(width: 24, height: 22)
                            .background(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                                .fill(isOn ? AppColors.sendFill : Color.primary.opacity(0.05)))
                            .accessibilityAddTraits(isOn ? .isSelected : [])
                        }
                    }
                }
            case .monthly:
                SettingsDivider()
                formRow("日期") {
                    Stepper("每月 \(rule.dayOfMonth) 日", value: $rule.dayOfMonth, in: 1...31)
                        .font(.system(size: 13))
                }
            case .everyNHours:
                SettingsDivider()
                formRow("间隔") {
                    Stepper("每 \(rule.intervalHours) 小时", value: $rule.intervalHours, in: 1...24)
                        .font(.system(size: 13))
                }
            case .once, .daily, .weekdays:
                EmptyView()
            }
            SettingsDivider()
            formRow(rule.kind == .everyNHours ? "分钟" : "时间") {
                HStack(spacing: AppSpacing.xSmall) {
                    Text("\(timeZoneID) ·")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    if rule.kind == .once {
                        ScheduledTimeField(selection: $rule.fireAt, includesDate: true,
                                           range: Date()...Date().addingTimeInterval(2 * 365 * 24 * 3600))
                            .tinted
                            .accessibilityIdentifier("scheduled.form.fireAt")
                    } else {
                        ScheduledTimeField(selection: $timeOfDay, includesDate: false)
                            .tinted
                    }
                }
            }
        }
        .scheduledCard()
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Button {
                withAnimation(AppMotion.resolved(Self.disclosure)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: AppSpacing.xxSmall) {
                    Text("高级")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsAdvanced ? 180 : 0))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .padding(.horizontal, AppSpacing.small)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scheduled.form.advanced")

            if showsAdvanced {
                VStack(spacing: 0) {
                    formRow("目标") {
                        ScheduledMenu("目标", selection: $targetKind, options: [("新会话", .newConversation), ("指定会话", .conversation)])
                    }
                    SettingsDivider()
                    switch targetKind {
                    case .newConversation:
                        formRow("项目") {
                            ScheduledMenu("项目", selection: $projectID,
                                          options: [("默认工作区", nil)] + appState.conversations.projects.map { ($0.name, Optional($0.id)) })
                        }
                        SettingsDivider()
                        formRow("模型") {
                            ScheduledMenu("模型", selection: $modelSource, options: modelOptions)
                        }
                        SettingsDivider()
                        formRow("思考强度") {
                            ScheduledMenu("思考强度", selection: $thinkingLevel,
                                          options: [("默认", nil)] + ThinkingLevel.selectableCases.map { (ScheduledModelLabel.effort($0), Optional($0)) })
                        }
                    case .conversation:
                        formRow("会话") {
                            ScheduledMenu("会话", selection: $conversationID,
                                          options: [("选择会话", nil)] + appState.conversations.conversations
                                              .filter { !$0.isArchived && !$0.isNativeDelegationChild }
                                              .map { ($0.title, Optional($0.id)) })
                        }
                        SettingsDivider()
                        formRow("模型 / 思考强度") {
                            Text(followsText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("scheduled.form.followsConversation")
                        }
                    }
                    SettingsDivider()
                    formRow("通知") {
                        ScheduledMenu("通知", selection: $notifyOn, options: [("完成和失败", .completionAndFailure), ("仅失败", .failureOnly)])
                    }
                }
                .scheduledCard()
                .transition(.opacity.combined(with: .move(edge: .top)))

                if targetKind == .conversation {
                    Text(ScheduledTaskCopy.conversationTargetNote)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if !backgroundAlerts {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text(ScheduledTaskCopy.notificationsOff).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Button(ScheduledTaskCopy.openSettings) {
                            onClose()
                            window.screen = .settingsGeneral
                        }
                        .buttonStyle(QuietLinkButtonStyle())
                    }
                    .accessibilityIdentifier("scheduled.form.notificationsOff")
                }
            }
        }
    }

    private var footer: some View {
        let isFullAccess = appState.permissions.mode == .fullAccess
        return HStack(spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.xxSmall) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AppColors.cautionIcon)
                Text("无人值守运行 · 需保持应用开启")
                    .foregroundStyle(Color.secondary)
            }
                .font(.system(size: 11.5))
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .help([isFullAccess ? ScheduledTaskCopy.fullAccessWarning : nil, ScheduledTaskCopy.unattendedNote, ScheduledTaskCopy.keepRunningNote]
                    .compactMap { $0 }.joined(separator: "\n"))
                .accessibilityIdentifier("scheduled.form.unattendedNote")
            Spacer(minLength: AppSpacing.small)
            Button("取消") { onClose() }
                .buttonStyle(ScheduledOutlineButtonStyle())
            Button(existing == nil ? "创建" : "保存", action: save)
                .buttonStyle(ScheduledCharcoalButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == nil)
                .accessibilityIdentifier("scheduled.form.save")
        }
        .padding(.top, AppSpacing.xxSmall)
    }

    private func formRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
                .layoutPriority(1)
            Spacer(minLength: AppSpacing.small)
            content()
        }
        .padding(.leading, Self.cardInset)
        // The menus carry their own hover inset; their text lines up with the card's inset.
        .padding(.trailing, Self.cardInset - AppSpacing.small)
        .frame(minHeight: Self.rowHeight)
    }

    /// 默认, the selectable groups, then the visible models as `Provider / Model`.
    private var modelOptions: [(String, ConversationModelSource?)] {
        let providers = appState.providers.providers
        let groups = ModelChoiceCatalog.selectableGroups(modelGroups: appState.modelGroups, providers: providers)
            .map { ($0.name, Optional(ConversationModelSource.group(groupID: $0.id))) }
        let models = ModelChoiceCatalog.visibleModelEntries(providers: providers, current: modelSource)
            .map { ("\($0.providerName) / \($0.model.displayName)", Optional(ConversationModelSource.direct(providerID: $0.providerID, modelID: $0.model.id))) }
        return [("默认", nil)] + groups + models
    }

    private var followsText: String {
        let conversation = conversationID.flatMap { id in appState.conversations.conversations.first { $0.id == id } }
        let source = ModelChoiceCatalog.currentModelSource(conversation: conversation, modelGroups: appState.modelGroups, providers: appState.providers)
        return ScheduledTaskCopy.followsConversation(
            model: ModelChoiceCatalog.label(for: source, modelGroups: appState.modelGroups, providers: appState.providers.providers),
            effort: ScheduledModelLabel.effort(conversation?.thinkingLevelOverride))
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let task = existing else {
            conversationID = window.conversationID
            if case .create(let template?) = mode {
                name = template.name
                prompt = template.prompt
                rule = template.ruleDraft
                timeOfDay = Calendar.current.date(bySettingHour: template.hour, minute: template.minute, second: 0, of: Date()) ?? timeOfDay
            }
            return
        }
        name = task.name
        prompt = task.prompt
        rule = ScheduledRuleDraft(schedule: task.schedule)
        timeOfDay = Calendar.current.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: Date()) ?? timeOfDay
        switch task.target {
        case .newConversation(let id): targetKind = .newConversation; projectID = id
        case .conversation(let id): targetKind = .conversation; conversationID = id
        }
        modelSource = task.modelSource
        thinkingLevel = task.thinkingLevel
        notifyOn = task.notifyOn
        // A task that departs from the defaults opens with them in view.
        showsAdvanced = targetKind != .newConversation || projectID != nil || modelSource != nil || thinkingLevel != nil || notifyOn != .completionAndFailure
    }

    private func save() {
        guard let target else { return }
        var task = existing ?? ScheduledTask(name: name, prompt: prompt, schedule: draftSchedule, target: target)
        task.name = name
        task.prompt = prompt
        task.schedule = draftSchedule
        task.target = target
        task.modelSource = target.isNewConversation ? modelSource : nil
        task.thinkingLevel = target.isNewConversation ? thinkingLevel : nil
        task.notifyOn = notifyOn
        do {
            let saved = existing == nil ? try appState.scheduled.create(task) : try appState.scheduled.update(task)
            onSaved(saved)
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
