import SwiftUI
import AppKit

struct WorktreeSettingsSection: View {
    @Environment(AppState.self) private var app
    @State private var prefix = "limare"
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SettingsSection(title: "Worktrees") {
            if !app.worktrees.preferences.isReadable {
                InlineStatus(kind: .error, message: "Worktree settings could not be read; creation is paused.")
            }
            SettingsRow("Worktree root", caption: "Changes apply only to newly created worktrees.") {
                HStack {
                    Button("Choose…") { chooseRoot() }
                    if app.worktrees.preferences.value.root != nil {
                        Button("Use Default") { save(root: nil) }
                    }
                }.buttonStyle(.settingsOutline).disabled(saving)
            }
            Text(app.worktrees.managedRoot.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            SettingsDivider()
            SettingsRow("Branch prefix", caption: "Used for newly created task branches.") {
                HStack {
                    TextField("Branch prefix", text: $prefix).textFieldStyle(.roundedBorder).frame(width: 150)
                    Button("Save") { save(root: app.worktrees.preferences.value.root?.url) }.disabled(saving)
                }
            }
            if let error { InlineStatus(kind: .error, message: "\(error)") }
        }
        .onAppear { prefix = app.worktrees.preferences.value.branchPrefix }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { save(root: url) }
        }
    }

    private func save(root: URL?) {
        saving = true; error = nil
        Task {
            do { try await app.worktrees.setPreferences(root: root, branchPrefix: prefix) }
            catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
