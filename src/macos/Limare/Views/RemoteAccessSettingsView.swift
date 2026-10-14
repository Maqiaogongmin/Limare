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
        Form {
            Section {
                Toggle("Enable Remote Access", isOn: $draft.isEnabled)
                LabeledContent("Server") { Text(serverText).foregroundStyle(.secondary) }
                LabeledContent("Tunnel") { Text(tunnelText).foregroundStyle(.secondary) }
            } header: {
                Text("Remote Access")
            } footer: {
                Text("Use this Limare from your phone's browser while Limare runs on this Mac. Limare listens only on 127.0.0.1; Cloudflare Tunnel is the only way in, and Cloudflare Access signs in the one person allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Public hostname", text: $draft.publicHostname, prompt: Text("limare.example.com"))
                TextField("Local port", text: $portText, prompt: Text("\(RemoteAccessConfiguration.defaultPort)"))
                SecretField(hasStoredSecret: remote.hasTunnelToken, replacementSecret: $replacementToken, placeholder: "Paste the tunnel token", secretName: "Tunnel token")
            } header: {
                Text("Cloudflare Tunnel")
            } footer: {
                Text("In Cloudflare Zero Trust, create a tunnel, add a public hostname with service http://127.0.0.1:\(portText.isEmpty ? String(RemoteAccessConfiguration.defaultPort) : portText), and turn on Protect with Access for that route. The token is kept in Limare's private secret store and passed to cloudflared only through its environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Team domain", text: $draft.teamDomain, prompt: Text("myteam.cloudflareaccess.com"))
                TextField("Application AUD tag", text: $draft.audienceTag)
                TextField("Owner email", text: $draft.ownerEmail, prompt: Text("you@example.com"))
            } header: {
                Text("Cloudflare Access")
            } footer: {
                Text("Every request must carry an Access token signed for this application and this email; anything else gets 403, including programs on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    if let applyError {
                        Text(applyError).foregroundStyle(.red).font(.caption)
                    }
                    Spacer()
                    Button(isApplying ? "Applying…" : "Save and Restart Remote Access") { apply() }
                        .disabled(isApplying || !isDirty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
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
