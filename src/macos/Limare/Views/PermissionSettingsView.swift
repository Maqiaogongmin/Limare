import SwiftUI

struct PermissionSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showFullAccessWarning = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    modeRow(
                        mode: .requestApproval,
                        title: "Ask for approval",
                        badge: "Recommended",
                        description: PermissionMode.requestApproval.detail,
                        reviewer: "You"
                    )

                    Divider()

                    modeRow(
                        mode: .helpMeApprove,
                        title: "Approve for me",
                        badge: nil,
                        description: PermissionMode.helpMeApprove.detail + " An isolated AI reviewer decides.",
                        reviewer: "Automatic review",
                        note: "Automatic review can make mistakes. Unclear or failed reviews fall back to you."
                    )

                    Divider()

                    modeRow(
                        mode: .fullAccess,
                        title: "Full access",
                        badge: "Danger",
                        description: PermissionMode.fullAccess.detail,
                        reviewer: "None",
                        note: "Higher risk of data loss, leaks, or unintended system modifications."
                    )
                }
                .padding(.vertical, 4)
            } header: {
                Text("Permission Modes")
            } footer: {
                Text("Shell commands run in a macOS sandbox, as in Codex; Full access and approved requests run outside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Image(systemName: appState.permissions.mode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(appState.permissions.mode == mode ? Color.accentColor : Color.secondary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge == "Danger" ? Color.red.opacity(0.15) : Color.accentColor.opacity(0.15))
                            .foregroundStyle(badge == "Danger" ? Color.red : Color.accentColor)
                            .clipShape(Capsule())
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
                        .foregroundStyle(mode == .fullAccess ? Color.red : Color.secondary)
                        .padding(.top, 1)
                }
            }
            Spacer()
        }
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
