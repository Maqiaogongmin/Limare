import SwiftUI

struct HookReviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isTechnicalDetailsExpanded: Bool = false

    let source: HookSource
    var onComplete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil

    private var presentationState: HooksSettingsState {
        HooksSettingsState()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                    Text("Review Hook Package")
                        .font(AppTypography.interfaceTitle2)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(source.name)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Button {
                    if let onCancel {
                        onCancel()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(AppSpacing.medium)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    // Security Warning Banner
                    HStack(alignment: .top, spacing: AppSpacing.medium) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(AppColors.statusWarning)
                        VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                            Text("Security Notice")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppColors.textPrimary)
                            Text("Hooks can execute local shell commands on your Mac and may receive conversation context, tool arguments, and execution results. Only trust packages from developers and sources you verify.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                    }
                    .padding(AppSpacing.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.statusWarning.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                            .stroke(AppColors.statusWarning.opacity(0.25), lineWidth: 1)
                    )

                    // Automations Summary Section
                    SettingsSection(title: "What this package will do") {
                        let allEventKeys = source.config.hooks.keys.sorted()
                        if allEventKeys.isEmpty {
                            Text("No lifecycle automations defined in this package.")
                                .font(.caption)
                                .foregroundStyle(AppColors.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: AppSpacing.small) {
                                ForEach(allEventKeys, id: \.self) { eventKey in
                                    eventReviewCard(eventKey: eventKey)
                                }
                            }
                        }
                    }

                    // Collapsible Technical Details Section
                    SettingsSection(title: "Technical Details") {
                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            Button {
                                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                                    isTechnicalDetailsExpanded.toggle()
                                }
                            } label: {
                                HStack(spacing: AppSpacing.xSmall) {
                                    Image(systemName: isTechnicalDetailsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.caption.weight(.semibold))
                                    Text(isTechnicalDetailsExpanded ? "Hide Details" : "Show Details")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(AppColors.sendFill)
                            }
                            .buttonStyle(.plain)

                            if isTechnicalDetailsExpanded {
                                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                                    detailRow(label: "Source Kind", value: source.sourceKind.displayName)
                                    detailRow(label: "Config File", value: source.configURL.path, isMonospaced: true)
                                    detailRow(label: "Package Root", value: source.packageRootURL.path, isMonospaced: true)
                                    detailRow(label: "Definition Hash", value: source.definitionHash, isMonospaced: true)
                                }
                                .padding(.top, AppSpacing.xxSmall)
                            }
                        }
                    }
                }
                .padding(AppSpacing.medium)
            }

            Divider()

            // Footer actions
            HStack {
                Button("Cancel") {
                    if let onCancel {
                        onCancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    appState.hooks.trustAndEnable(sourceID: source.id)
                    if let onComplete {
                        onComplete()
                    } else {
                        dismiss()
                    }
                } label: {
                    Label("Trust & Enable", systemImage: "checkmark.shield.fill")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.charcoalProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(AppSpacing.medium)
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    @ViewBuilder
    private func eventReviewCard(eventKey: String) -> some View {
        let groups = source.config.hooks[eventKey] ?? []
        let friendlyName = presentationState.friendlyEventName(for: eventKey)
        let isSupported = HookEventName(rawValue: eventKey)?.isSupported ?? false

        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.xSmall) {
                Circle()
                    .fill(isSupported ? AppColors.statusSuccess : AppColors.textSecondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                Text(friendlyName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)

                if !isSupported {
                    Text("Unsupported")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppColors.textSecondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            ForEach(groups) { group in
                ForEach(group.hooks) { hook in
                    if let cmd = hook.command, !cmd.isEmpty {
                        commandPreview(cmd)
                    }
                }
            }
        }
        .padding(.vertical, AppSpacing.xxSmall)
    }

    private func commandPreview(_ cmd: String) -> some View {
        Text(cmd)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(AppColors.textPrimary)
            .textSelection(.enabled)
            .padding(AppSpacing.xSmall)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, isMonospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(isMonospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
