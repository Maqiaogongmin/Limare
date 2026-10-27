import SwiftUI

enum MCPEditMode: String, CaseIterable, Identifiable {
    case stdio = "Local Command"
    case http = "Remote Server"
    case jsonImport = "Import Configuration…"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stdio: String(localized: "Local Command")
        case .http: String(localized: "Remote Server")
        case .jsonImport: String(localized: "Import Configuration…")
        }
    }
}

struct MCPServerEditFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let existingConfig: MCPServerConfig?
    /// Commits the definition and the client secret change as one Host operation.
    let onSave: (MCPServerConfig, MCPSecretMutation) async throws -> Void
    var onCancel: (() -> Void)? = nil
    var onImport: ((String) async throws -> Int)? = nil

    @State private var mode: MCPEditMode = .stdio
    @State private var draft = MCPConnectionDraft()
    @State private var isAdvancedExpanded = false
    @State private var jsonImportText = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isCommitting = false

    var isEditing: Bool { existingConfig != nil }
    /// A profile fixes the endpoint and headers; only the client setup and note are editable.
    private var profile: MCPServerProfile? { existingConfig?.profile }

    private var oauthClientSecretPlaceholder: String {
        guard let existingConfig else { return String(localized: "Optional") }
        switch appState.mcp.credentialPresence(serverID: existingConfig.id, key: MCPSecretKey.oauthClientSecret) {
        case .present: return "<stored secret>"
        case .absent: return String(localized: "Optional")
        case .unknown: return String(localized: "Credential status not checked")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
                    if isEditing {
                        editForm
                    } else {
                        modePicker
                        if mode == .jsonImport {
                            importForm
                        } else {
                            addForm
                        }
                    }

                    if let errorMessage {
                        InlineStatus(kind: .error, message: "\(errorMessage)")
                    }
                    if let successMessage {
                        InlineStatus(kind: .success, message: "\(successMessage)")
                    }
                }
                .padding(AppSpacing.medium)
            }
            Divider()
            footer
        }
        .onAppear(perform: setupInitialValues)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.small) {
            if let onCancel {
                Button {
                    onCancel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Connection")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.8))

                Divider()
                    .frame(height: 14)
            }

            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                Text(isEditing ? "Edit MCP Connection" : "Add MCP Connection")
                    .font(AppTypography.interfaceTitle2)
                    .foregroundStyle(AppColors.textPrimary)
                Text(isEditing ? "Configure connection settings for “\(existingConfig?.id ?? "")”" : "Connect external tools and resources to Limare")
                    .font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(AppSpacing.medium)
    }

    private var modePicker: some View {
        SettingsSegmentedPicker(
            selection: $mode,
            options: MCPEditMode.allCases.map { (value: $0, title: $0.title) }
        )
        .accessibilityLabel("Connection Type")
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
            if mode == .stdio {
                stdioPrimarySection
                stdioAdvancedSection
            } else if mode == .http {
                httpPrimarySection
                httpAdvancedSection
            }
        }
    }

    private var editForm: some View {
        VStack(alignment: .leading, spacing: AppSemanticSpacing.settingsSectionGap) {
            if existingConfig?.isHTTP == true {
                httpPrimarySection
                httpAdvancedSection
            } else {
                stdioPrimarySection
                stdioAdvancedSection
            }
        }
    }

    // MARK: - STDIO Sections

    private var stdioPrimarySection: some View {
        SettingsSection(title: "Connection Details", description: "Executable process running locally on this Mac") {
            FormField("Name:", caption: isEditing ? "Server name cannot be changed." : "Unique identifier for this MCP server") {
                TextField("e.g. filesystem", text: $draft.serverID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)
            }

            FormField("Command:", caption: "Command or executable binary path") {
                TextField("e.g. npx, python3, /usr/local/bin/server", text: $draft.command)
                    .textFieldStyle(.roundedBorder)
            }

            FormField("Arguments:", caption: "Command-line arguments (separated by spaces or newlines)") {
                TextEditor(text: $draft.argumentsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 54)
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.small).stroke(AppColors.borderMuted, lineWidth: 1))
            }

            FormField("Note:", caption: "Optional human description") {
                TextField("e.g. Local file system tools", text: $draft.note)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var stdioAdvancedSection: some View {
        DisclosureSection(
            title: "Advanced",
            summary: "Environment variables, startup timeout",
            isExpanded: $isAdvancedExpanded
        ) {
            FormField("Environment:", caption: "KEY=VALUE per line. Sensitive values are stored in the Limare private vault.", labelWidth: nil) {
                TextEditor(text: $draft.environmentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 72)
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.small).stroke(AppColors.borderMuted, lineWidth: 1))
            }

            FormField("Timeout:", caption: "Maximum seconds to wait for server initialization") {
                HStack(spacing: AppSpacing.small) {
                    Stepper("\(draft.timeoutSeconds)s", value: $draft.timeoutSeconds, in: 5...300, step: 5)
                    Spacer()
                }
            }
        }
    }

    // MARK: - HTTP Sections

    private var httpPrimarySection: some View {
        SettingsSection(title: "Connection Details", description: "Remote server endpoint (Streamable HTTP)") {
            FormField("Name:", caption: isEditing ? "Server name cannot be changed." : "Unique identifier for this MCP server") {
                TextField("e.g. remote-docs", text: $draft.serverID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isEditing)
            }

            FormField("URL:", caption: profile.map { "Fixed by the \($0.contract.displayName) profile." } ?? "Server endpoint URL (HTTP/HTTPS)") {
                TextField("https://example.com/mcp", text: $draft.urlString)
                    .textFieldStyle(.roundedBorder)
                    .disabled(profile != nil)
            }

            FormField("Note:", caption: "Optional human description") {
                TextField("e.g. Documentation search endpoint", text: $draft.note)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var httpAdvancedSection: some View {
        DisclosureSection(
            title: "Advanced",
            summary: MCPStore.oauthAdmitted ? "Custom HTTP headers, authorization" : "Custom HTTP headers, access token",
            isExpanded: $isAdvancedExpanded
        ) {
            FormField("Headers:", caption: "Header: Value per line, e.g. Authorization: Bearer <token>. Sensitive values are stored in Limare's private storage after you confirm.", labelWidth: nil) {
                TextEditor(text: $draft.headersText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.small).stroke(AppColors.borderMuted, lineWidth: 1))
                    .disabled(profile != nil)
            }

            // Client setup is offered only while SDK OAuth is admitted.
            if MCPStore.oauthAdmitted {
                FormField("OAuth Client ID:", caption: "Only for servers that cannot register Limare automatically: the client ID of an OAuth app you registered with the provider. Leave empty otherwise.", labelWidth: nil) {
                    TextField("Optional", text: $draft.oauthClientID)
                        .textFieldStyle(.roundedBorder)
                }

                FormField("OAuth Client Secret:", caption: "Saved with the connection in Limare's private storage after you confirm, never in configuration. Changing the URL or client ID removes it.", labelWidth: nil) {
                    SecureField(oauthClientSecretPlaceholder, text: $draft.oauthClientSecret)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: - Import Form

    private var importForm: some View {
        SettingsSection(title: "Import JSON Configuration", description: "Paste Claude Desktop mcpServers configuration JSON below:") {
            TextEditor(text: $jsonImportText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 180)
                .overlay(RoundedRectangle(cornerRadius: AppRadius.small).stroke(AppColors.borderMuted, lineWidth: 1))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            if !isEditing && mode == .jsonImport {
                Button("Import") {
                    performImport()
                }
                .buttonStyle(.charcoalProminent)
                .disabled(isCommitting || jsonImportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button(isCommitting ? "Saving…" : "Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.charcoalProminent)
                .disabled(isCommitting || draft.serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppSpacing.medium)
    }

    // MARK: - Logic

    private func setupInitialValues() {
        guard let config = existingConfig else { return }
        draft = MCPConnectionDraft(existing: config)
        mode = config.isHTTP ? .http : .stdio
    }

    private func performImport() {
        errorMessage = nil
        successMessage = nil
        guard let onImport else {
            errorMessage = String(localized: "Import is not configured.")
            return
        }

        isCommitting = true
        let text = jsonImportText
        Task {
            defer { isCommitting = false }
            do {
                let count = try await onImport(text)
                successMessage = String(localized: "Successfully imported \(count) connections.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let onCancel {
                        onCancel()
                    } else {
                        dismiss()
                    }
                }
            } catch {
                errorMessage = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }

    private func save() {
        errorMessage = nil
        successMessage = nil
        let isHTTP = isEditing ? (existingConfig?.isHTTP == true) : (mode == .http)
        let command: (MCPServerConfig, MCPSecretMutation)
        do { command = try draft.command(existing: existingConfig, isHTTP: isHTTP) }
        catch { errorMessage = error.localizedDescription; return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                try await onSave(command.0, command.1)
                draft.oauthClientSecret = ""
            } catch {
                errorMessage = String(localized: "Failed to save configuration: \(error.localizedDescription)")
            }
        }
    }
}

struct MCPServerEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existingConfig: MCPServerConfig?
    let onSave: (MCPServerConfig, MCPSecretMutation) async throws -> Void
    var onImport: ((String) async throws -> Int)? = nil

    var body: some View {
        MCPServerEditFormView(
            existingConfig: existingConfig,
            onSave: {
                try await onSave($0, $1)
                dismiss()
            },
            onCancel: {
                dismiss()
            },
            onImport: onImport
        )
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620, minHeight: 460, idealHeight: 520, maxHeight: 680)
    }
}

/// What the connection form holds, and the one mapping from it to a Host command. The form starts
/// from the stored definition, so fields it does not show (profile, imported extensions, fields under
/// review, credential binding) are kept rather than silently dropped.
struct MCPConnectionDraft: Equatable {
    struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var serverID = ""
    var note = ""
    var command = ""
    var argumentsText = ""
    var environmentText = ""
    var timeoutSeconds = 30
    var urlString = ""
    var headersText = ""
    var oauthClientID = ""
    var oauthClientSecret = ""

    init() {}

    init(existing config: MCPServerConfig) {
        func lines(_ entries: [String: String]?, separator: String) -> String {
            (entries ?? [:]).map { key, value in
                "\(key)\(separator)\(MCPServerConfig.isSecretReference(value) ? "<stored secret>" : value)"
            }.sorted().joined(separator: "\n")
        }
        serverID = config.id
        note = config.note ?? ""
        command = config.command ?? ""
        argumentsText = config.args?.joined(separator: "\n") ?? ""
        environmentText = lines(config.env, separator: "=")
        timeoutSeconds = config.startupTimeoutSeconds ?? 30
        urlString = config.url ?? ""
        headersText = lines(config.headers, separator: ": ")
        oauthClientID = config.oauth?.clientId ?? ""
    }

    /// The definition and client secret change one Save submits.
    func command(existing: MCPServerConfig?, isHTTP: Bool) throws -> (MCPServerConfig, MCPSecretMutation) {
        let trimmedID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw Invalid(String(localized: "Connection name is required.")) }
        func entries(_ text: String, separator: Character, existing stored: [String: String]?, kind: String) throws -> [String: String]? {
            var result: [String: String] = [:]
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let index = trimmed.firstIndex(of: separator) else { continue }
                let key = String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: index)...]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { continue }
                if value == "<stored secret>" {
                    guard let reference = stored?[key], MCPServerConfig.isSecretReference(reference) else {
                        throw Invalid(String(localized: "Cannot use '<stored secret>' for new or unset \(kind) '\(key)'."))
                    }
                    result[key] = reference
                } else {
                    result[key] = value
                }
            }
            return result.isEmpty ? nil : result
        }

        var config = existing ?? MCPServerConfig(id: trimmedID)
        config.note = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        if !isHTTP {
            let executable = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !executable.isEmpty else { throw Invalid(String(localized: "Command is required for local MCP connections.")) }
            let args = argumentsText.components(separatedBy: .newlines)
                .flatMap { $0.components(separatedBy: " ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            config.command = executable
            config.args = args.isEmpty ? nil : args
            config.env = try entries(environmentText, separator: "=", existing: existing?.env, kind: String(localized: "environment variable"))
            config.startupTimeoutSeconds = timeoutSeconds
            config.url = nil
            config.headers = nil
            config.oauth = nil
            return (config, .unchanged)
        }
        if config.profile == nil {
            let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { throw Invalid(String(localized: "A URL is required for remote server connections.")) }
            // Scheme, host and credential checks happen in MCPStore.validate when the config is saved.
            config.url = url
            config.headers = try entries(headersText, separator: ":", existing: existing?.headers, kind: "header")
            config.command = nil
            config.args = nil
            config.env = nil
        }
        let clientID = oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        config.oauth = clientID.isEmpty ? nil : MCPOAuthSettings(clientId: clientID, callbackPort: nil)
        // The client secret belongs to its client ID; clearing the ID retires both after commit.
        let secret = oauthClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return (config, clientID.isEmpty || secret.isEmpty ? .unchanged : .replace(secret))
    }
}
