import SwiftUI
import AppKit

struct SoulSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var editor = SoulEditorState()

    private static let langOptions: [(label: String, value: String)] = [
        ("Auto", "auto"),
        ("Chinese", "zh"),
        ("English", "en"),
    ]

    var body: some View {
        SettingsPage {
            previewCard

            identitySection

            personalitySection

            actionsSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            editor.load(from: appState.soul)
        }
        .alert("Restore Default", isPresented: $editor.isShowingRestoreConfirmation) {
            Button("Restore Default", role: .destructive) {
                do {
                    try editor.confirmRestoreDefault(to: appState.soul)
                } catch {
                    editor.statusMessage = "Restore failed: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {
                editor.cancelRestoreDefault()
            }
        } message: {
            Text("Restore default SOUL.md? Your current personality settings and unsaved changes will be replaced.")
        }
        .alert("Unsaved Changes", isPresented: $editor.isShowingReloadConfirmation) {
            Button("Discard Changes & Reload", role: .destructive) {
                editor.confirmReload(from: appState.soul)
            }
            Button("Cancel", role: .cancel) {
                editor.cancelReload()
            }
        } message: {
            Text("You have unsaved changes. Discard them and reload from disk?")
        }
    }

    private var previewCard: some View {
        HStack(spacing: AppSpacing.standard) {
            AssistantAvatarView(
                image: editor.displayAvatarImage,
                size: 52
            )

            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                HStack(spacing: AppSpacing.small) {
                    Text(editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Limare" : editor.name)
                        .font(.title3.weight(.bold))
                    if !editor.lang.isEmpty {
                        Text(editor.lang.uppercased())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, AppSemanticSpacing.badgePaddingHorizontal)
                            .padding(.vertical, AppSemanticSpacing.badgePaddingVertical)
                            .background(AppColors.surfaceInteractive)
                            .clipShape(Capsule())
                    }
                }
                Text(editor.style.isEmpty ? "No custom response style set." : editor.style)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(AppSpacing.standard)
        .background(AppColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.bubble))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.bubble)
                .stroke(AppColors.borderMuted, lineWidth: 1)
        )
    }

    private var identitySection: some View {
        SettingsSection(title: "Identity") {
            VStack(spacing: AppSpacing.medium) {
                HStack(spacing: AppSpacing.standard) {
                    Text("Avatar")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(AppColors.textSecondary)

                    AssistantAvatarView(
                        image: editor.displayAvatarImage,
                        size: 36
                    )

                    Button("Change Avatar...") {
                        selectAvatarImage()
                    }
                    .controlSize(.small)

                    if editor.hasCustomAvatar {
                        Button("Remove") {
                            editor.removeAvatar()
                        }
                        .controlSize(.small)
                        .foregroundStyle(AppColors.textSecondary)
                    }

                    Spacer()
                }

                HStack {
                    Text("Name")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("Limare", text: $editor.name)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Style")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(AppColors.textSecondary)
                    TextField("e.g. Warm, direct, opinionated", text: $editor.style)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("Language")
                        .frame(width: 80, alignment: .leading)
                        .foregroundStyle(AppColors.textSecondary)
                    Picker("", selection: $editor.lang) {
                        ForEach(Self.langOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160, alignment: .leading)
                    Spacer()
                }
            }
        }
    }

    private var personalitySection: some View {
        SettingsSection(title: "Personality Prompt") {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack {
                    Text("Your custom character, voice, and guidance for Limare. Saved directly to SOUL.md.")
                        .font(.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Text("\(editor.tokenCount) / \(SoulStore.bodyTokenLimit) tokens")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(editor.isOverLimit ? AppColors.statusError : AppColors.textSecondary)
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editor.bodyText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(AppSpacing.small)

                    if editor.bodyText.isEmpty {
                        Text("Describe how Limare should think, behave, and converse...")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, AppSpacing.medium)
                            .padding(.vertical, AppSpacing.medium)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 220, maxHeight: 340)
                .background(AppColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.modal))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.modal)
                        .stroke(editor.isOverLimit ? AppColors.statusError : AppColors.borderMuted, lineWidth: 1)
                )

                if editor.isOverLimit {
                    Text("Personality exceeds the 2000 token cap. Shorten the prompt before saving.")
                        .font(.caption)
                        .foregroundStyle(AppColors.statusError)
                }
            }
        }
    }

    private var actionsSection: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            Button(role: .destructive) {
                editor.requestRestoreDefault()
            } label: {
                Label("Restore Default", systemImage: "arrow.uturn.backward")
            }

            Spacer()

            if let statusMessage = editor.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Button("Reload") {
                editor.requestReload(from: appState.soul)
            }

            Button("Save") {
                do {
                    try editor.save(to: appState.soul)
                } catch {
                    editor.statusMessage = "Save failed: \(error.localizedDescription)"
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!editor.isDirty || editor.isOverLimit)
        }
        .padding(.top, AppSpacing.xxSmall)
    }

    private func selectAvatarImage() {
        let panel = NSOpenPanel()
        panel.title = "Select Avatar Image"
        panel.showsHiddenFiles = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            editor.selectAvatar(from: url)
        }
    }
}
