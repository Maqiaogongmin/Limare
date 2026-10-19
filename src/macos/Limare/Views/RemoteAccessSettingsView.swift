import SwiftUI

struct RemoteAccessSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var draft = RemoteAccessConfiguration()
    @State private var portText = ""
    @State private var replacementToken: String?
    @State private var isApplying = false
    @State private var applyError: String?

    private var remote: RemoteAccessCoordinator { appState.remoteAccess }

    var body: some View {
        SettingsPage {
            // The page title already names it; the first card starts with the switch.
            SettingsSection {
                SettingsRow("Enable Remote Access") {
                    Toggle("Enable Remote Access", isOn: $draft.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsDivider()
                SettingsRow("Server") {
                    Text(serverText)
                        .font(Self.mono)
                        .foregroundStyle(.secondary)
                }
                SettingsDivider()
                SettingsRow("Tunnel") {
                    if case .connected = remote.tunnel.status {
                        SettingsBadge("Connected", tone: .positive)
                    } else {
                        Text(tunnelText)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            footnote("Use this Limare from your phone's browser while Limare runs on this Mac. Limare listens only on 127.0.0.1; Cloudflare Tunnel is the only way in, and Cloudflare Access signs in the one person allowed.")

            SettingsSection(title: "Cloudflare Tunnel") {
                field("Public hostname") {
                    TextField("Public hostname", text: $draft.publicHostname, prompt: Text("limare.example.com"))
                        .font(Self.mono)
                        .settingsFieldWell()
                }
                SettingsDivider()
                field("Local port") {
                    TextField("Local port", text: $portText, prompt: Text("\(RemoteAccessConfiguration.defaultPort)"))
                        .font(Self.mono)
                        .settingsFieldWell()
                }
                SettingsDivider()
                field("Tunnel token") {
                    SecretField(hasStoredSecret: remote.hasTunnelToken, replacementSecret: $replacementToken, placeholder: "Paste the tunnel token", secretName: "Tunnel token")
                }
            }
            footnote("In Cloudflare Zero Trust, create a tunnel, add a public hostname with service http://127.0.0.1:\(portText.isEmpty ? String(RemoteAccessConfiguration.defaultPort) : portText), and turn on Protect with Access for that route. The token is kept in Limare's private secret store and passed to cloudflared only through its environment.")

            SettingsSection(title: "Cloudflare Access") {
                field("Team domain") {
                    TextField("Team domain", text: $draft.teamDomain, prompt: Text("myteam.cloudflareaccess.com"))
                        .font(Self.mono)
                        .settingsFieldWell()
                }
                SettingsDivider()
                field("Application AUD tag") {
                    // A long hash: one line, cut in the middle, so the label beside it keeps its room.
                    TextField("Application AUD tag", text: $draft.audienceTag)
                        .font(Self.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .settingsFieldWell()
                }
                SettingsDivider()
                field("Owner email") {
                    TextField("Owner email", text: $draft.ownerEmail, prompt: Text("you@example.com"))
                        .settingsFieldWell()
                }
            }
            footnote("Every request must carry an Access token signed for this application and this email; anything else gets 403, including programs on this Mac.")

            // Under the last card, at its right edge: charcoal while there is something to save.
            HStack(spacing: AppSpacing.small) {
                if let applyError {
                    Text(applyError)
                        .foregroundStyle(AppColors.dangerText)
                        .font(AppTypography.interfaceCaption)
                }
                Spacer()
                Button(isApplying ? "Applying…" : "Save and Restart Remote Access") { apply() }
                    .buttonStyle(.charcoalProminent)
                    .disabled(isApplying || !isDirty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: load)
    }

    private static let mono = Font.system(size: 12.5, design: .monospaced)

    /// A labelled field: the label at a fixed width, the field filling the rest of the row.
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AppSpacing.medium) {
            Text(label)
                .font(AppTypography.interfaceMedium)
                .foregroundStyle(AppColors.textPrimary)
                .frame(width: 150, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppSemanticSpacing.settingsRowVerticalPadding)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, AppSpacing.xxSmall)
            .padding(.top, -AppSpacing.small)
    }

    private var isDirty: Bool {
        withPort(draft) != remote.configuration || replacementToken != nil
    }

    private var serverText: String {
        switch remote.serverStatus {
        case .off: draft.isEnabled ? "Not running" : "Off"
        case .starting: "Starting…"
        case .serving(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let reason): reason
        }
    }

    private var tunnelText: String {
        switch remote.tunnel.status {
        case .stopped: "Not running"
        case .starting, .running: remote.tunnel.lastError.map { "Connecting to Cloudflare… Last error: \($0)" } ?? "Connecting to Cloudflare…"
        case .connected: "Connected"
        case .restarting(let seconds): "Restarting in \(seconds) s"
        case .failed(let reason): reason
        }
    }

    private func load() {
        draft = remote.configuration
        portText = String(draft.port)
    }

    private func withPort(_ configuration: RemoteAccessConfiguration) -> RemoteAccessConfiguration {
        var copy = configuration
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)) { copy.port = port }
        return copy
    }

    private func apply() {
        let next = withPort(draft)
        let token = replacementToken
        isApplying = true
        applyError = nil
        Task {
            do {
                try await remote.apply(next, tunnelToken: token)
                replacementToken = nil
                draft = remote.configuration
                portText = String(draft.port)
            } catch {
                applyError = "Could not save the tunnel token: \(error.localizedDescription)"
            }
            isApplying = false
        }
    }
}
