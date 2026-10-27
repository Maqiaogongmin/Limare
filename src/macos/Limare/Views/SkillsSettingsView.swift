import SwiftUI
import AppKit

struct SkillsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    @State private var state = SkillsSettingsState()

    private var filteredSkills: [Skill] {
        state.filteredSkills(from: appState.skills.skills)
    }

    private var presentedSkill: Skill? {
        guard let id = state.presentedSkillID else { return nil }
        return appState.skills.skills.first(where: { $0.id == id })
    }

    private var activeEffectiveWorkspaceURL: URL? {
        guard let activeID = window.conversationID else { return nil }
        return appState.conversations.effectiveWorkingDirectory(for: activeID)
    }

    var body: some View {
        SettingsPage {
            // Header / Controls Section
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(spacing: AppSpacing.medium) {
                    SettingsSearchField(text: $state.searchText, placeholder: "Search skills…")
                        .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)

                    SettingsSegmentedPicker(
                        selection: $state.filterScope,
                        options: SkillFilterScope.allCases.map { (value: $0, title: $0.displayName) }
                    )
                    .fixedSize()
                    .accessibilityLabel("Scope")

                    Spacer()

                    Button {
                        appState.skills.rescan(workspaceURL: activeEffectiveWorkspaceURL ?? appState.workspace.url)
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.settingsOutline)
                    .help("Rescan Project and Global Skills")
                }
            }

            // Skills List Section
            if appState.skills.skills.isEmpty {
                ContentUnavailableView(
                    "No Skills Found",
                    systemImage: "sparkles",
                    description: Text("Skills add reusable ways for Limare to handle specific kinds of work.\n\nAdd a compatible Skill to a Project or your global Skills folder, then rescan.")
                )
                .padding(.vertical, AppSpacing.xLarge)
                .frame(maxWidth: .infinity)
            } else if filteredSkills.isEmpty {
                if !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No Matching Skills",
                        systemImage: "magnifyingglass",
                        description: Text("No skills match “\(state.searchText)”.")
                    )
                    .padding(.vertical, AppSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView(
                        state.filterScope == .workspace ? "No Project Skills" : "No Global Skills",
                        systemImage: state.filterScope == .workspace ? "folder" : "globe",
                        description: Text(
                            state.filterScope == .workspace
                                ? (activeEffectiveWorkspaceURL != nil
                                    ? "No Skills were found for this Project."
                                    : "Project-specific Skills will appear here when the current Project provides them.")
                                : "No skills found in global locations."
                        )
                    )
                    .padding(.vertical, AppSpacing.xLarge)
                    .frame(maxWidth: .infinity)
                }
            } else {
                SettingsSection(
                    title: "Discovered Skills",
                    description: "\(filteredSkills.count) skills available"
                ) {
                    ForEach(Array(filteredSkills.enumerated()), id: \.element.id) { index, skill in
                        if index > 0 {
                            SettingsDivider()
                        }
                        SkillRowView(skill: skill, state: state)
                    }
                }
            }
        }
        .sheet(item: Binding(
            get: { presentedSkill },
            set: {
                state.presentedSkillID = $0?.id
                if $0 == nil {
                    state.resetSheetState()
                }
            }
        )) { skill in
            SkillDetailSheet(skill: skill, state: state)
        }
    }
}

// MARK: - Skill Row View

private struct SkillRowView: View {
    @Environment(AppState.self) private var appState
    let skill: Skill
    let state: SkillsSettingsState

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            Toggle(
                isOn: Binding(
                    get: { skill.isEnabled },
                    set: { appState.skills.setEnabled($0, for: skill.id) }
                )
            ) {
                EmptyView()
            }
            .toggleStyle(.charcoalCheckbox)
            .labelsHidden()
            .accessibilityLabel("Enable \(skill.name)")

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(skill.name)
                        .font(AppTypography.interfaceMedium)
                        .foregroundStyle(skill.isEnabled ? AppColors.textPrimary : AppColors.textSecondary)
                        .lineLimit(1)

                    SettingsBadge(skill.location.displayName)
                }

                if !skill.description.isEmpty {
                    Text(skill.description.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                        .help(skill.description)
                }
            }

            Spacer(minLength: AppSpacing.small)

            Image(systemName: "chevron.right")
                .font(AppTypography.interfaceCaption2.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary.opacity(0.4))
        }
        .padding(.vertical, AppSemanticSpacing.settingsRowVerticalPadding)
        .contentShape(Rectangle())
        .onTapGesture {
            state.resetSheetState()
            state.presentedSkillID = skill.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            state.resetSheetState()
            state.presentedSkillID = skill.id
        }
    }
}

// MARK: - Skill Detail Sheet

private struct SkillDetailSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    @Bindable var state: SkillsSettingsState

    private var isDescriptionLong: Bool {
        skill.description.count > 120 || skill.description.contains("\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(skill.name)
                        .font(AppTypography.interfaceTitle2)
                        .foregroundStyle(AppColors.textPrimary)

                    SettingsBadge(skill.location.displayName)
                }

                Spacer()

                HStack(spacing: AppSpacing.medium) {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { skill.isEnabled },
                            set: { appState.skills.setEnabled($0, for: skill.id) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.charcoalProminent)
                    .controlSize(.small)
                }
            }
            .padding(AppSpacing.medium)

            Divider()

            // Scrollable Content
            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    // Section: What it does (with progressive disclosure)
                    SettingsSection(title: "What it does") {
                        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                            if skill.description.isEmpty {
                                Text("No description provided.")
                                    .font(.body)
                                    .foregroundStyle(AppColors.textSecondary)
                            } else {
                                Text(skill.description)
                                    .font(.body)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(state.isDescriptionExpanded ? nil : 3)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isDescriptionLong {
                                    Button(state.isDescriptionExpanded ? "Show less" : "Show more") {
                                        withAnimation(AppMotion.resolved(AppMotion.standard)) {
                                            state.isDescriptionExpanded.toggle()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Color.primary.opacity(0.75))
                                    .underline()
                                    .padding(.top, 1)
                                }
                            }
                        }
                    }

                    // Section: Instructions (default collapsed)
                    if !skill.body.isEmpty {
                        DisclosureSection(
                            title: "Instructions",
                            summary: "View full instructions",
                            isExpanded: $state.isInstructionsExpanded
                        ) {
                            ScrollView(.vertical) {
                                Text(skill.body)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(AppColors.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(AppSpacing.small)
                            }
                            .frame(maxHeight: 220)
                            .background(AppColors.surfaceSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous))
                        }
                    }
                }
                .padding(AppSpacing.medium)
            }

            Divider()

            // Low-weight Metadata Footer
            HStack {
                if !skill.version.isEmpty {
                    Text("v\(skill.version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(AppColors.textSecondary)
                }

                Spacer()

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL])
                }
                .controlSize(.small)
                .help(skill.sourcePath)
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .background(AppColors.surfaceSecondary.opacity(0.4))
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 600, minHeight: 320, idealHeight: 400, maxHeight: 540)
    }
}
