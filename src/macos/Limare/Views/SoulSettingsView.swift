import SwiftUI
import AppKit

struct SoulSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var editor = SoulEditorState()

    /// The language Limare answers in; named in the current interface language.
    private static var langOptions: [(label: String, value: String)] {
        [(String(localized: "Auto"), "auto")]
            + ["zh", "en"].map { (Locale.current.localizedString(forLanguageCode: $0) ?? $0, $0) }
    }

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
                    editor.statusMessage = String(localized: "Restore failed: \(error.localizedDescription)")
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
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }
                Text(editor.style.isEmpty ? String(localized: "No custom response style set.") : editor.style)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(AppSpacing.standard)
        .settingsCard()
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
                    .buttonStyle(.settingsOutline)

                    if editor.hasCustomAvatar {
                        Button("Remove") {
                            editor.removeAvatar()
                        }
                        .buttonStyle(.settingsOutline)
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
                    Text("Reply Language")
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

                // A pale warm well inside the white card, not a grey box in a grey card.
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editor.bodyText)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(AppSpacing.medium)

                    if editor.bodyText.isEmpty {
                        Text("Describe how Limare should think, behave, and converse...")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, AppSpacing.medium + 5)
                            .padding(.vertical, AppSpacing.medium)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 220, maxHeight: 340)
                .background(AppColors.editorWell)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(editor.isOverLimit ? AppColors.statusError : Color.primary.opacity(0.08), lineWidth: 1)
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
            .buttonStyle(.settingsOutline)

            Spacer()

            if let statusMessage = editor.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            Button("Reload") {
                editor.requestReload(from: appState.soul)
            }
            .buttonStyle(.settingsOutline)

            Button("Save") {
                do {
                    try editor.save(to: appState.soul)
                } catch {
                    editor.statusMessage = String(localized: "Save failed: \(error.localizedDescription)")
                }
            }
            .buttonStyle(.charcoalProminent)
            .disabled(!editor.isDirty || editor.isOverLimit)
        }
        .padding(.top, AppSpacing.xxSmall)
    }

    private func selectAvatarImage() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Select Avatar Image")
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
