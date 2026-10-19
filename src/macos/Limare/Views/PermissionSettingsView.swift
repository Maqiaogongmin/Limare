import SwiftUI

struct PermissionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showFullAccessWarning = false

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Permission Modes") {
                modeRow(
                    mode: .requestApproval,
                    title: "Ask for approval",
                    badge: "Recommended",
                    description: PermissionMode.requestApproval.detail,
                    reviewer: "You"
                )

                SettingsDivider()

                modeRow(
                    mode: .helpMeApprove,
                    title: "Approve for me",
                    badge: nil,
                    description: PermissionMode.helpMeApprove.detail + " An isolated AI reviewer decides.",
                    reviewer: "Automatic review",
                    note: "Automatic review can make mistakes. Unclear or failed reviews fall back to you."
                )

                SettingsDivider()

                modeRow(
                    mode: .fullAccess,
                    title: "Full access",
                    badge: "Danger",
                    description: PermissionMode.fullAccess.detail,
                    reviewer: "None",
                    note: "Higher risk of data loss, leaks, or unintended system modifications."
                )
            }

            Text("Shell commands run in a macOS sandbox, as in Codex; Full access and approved requests run outside it.")
                .font(AppTypography.interfaceCaption)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.horizontal, AppSpacing.xxSmall)
        }
        .alert("Enable Full Access?", isPresented: $showFullAccessWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Full Access", role: .destructive) {
                appState.permissions.mode = .fullAccess
            }
        } message: {
            Text("Commands run outside the sandbox, and file tools reach outside the Project folder, without confirmation: they can open apps, change any file and use AppleScript.")
        }
    }

    private func modeRow(
        mode: PermissionMode,
        title: String,
        badge: String?,
        description: String,
        reviewer: String,
        note: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                selectMode(mode)
            } label: {
                SettingsRadioMark(isSelected: appState.permissions.mode == mode)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    if let badge {
                        SettingsBadge(badge, tone: badge == "Danger" ? .danger : .neutral)
                    }
                }

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Text("Reviewer:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(reviewer)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
                .padding(.top, 2)

                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(mode == .fullAccess ? AppColors.dangerText : Color.secondary)
                        .padding(.top, 1)
                }
            }
            Spacer()
        }
        .padding(.vertical, AppSpacing.xxSmall)
        .contentShape(Rectangle())
        .onTapGesture {
            selectMode(mode)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(appState.permissions.mode == mode ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { selectMode(mode) }
    }

    private func selectMode(_ mode: PermissionMode) {
        if mode == .fullAccess && appState.permissions.mode != .fullAccess {
            showFullAccessWarning = true
        } else {
            appState.permissions.mode = mode
        }
    }
}
