import SwiftUI

struct ProviderQuotaSection: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window
    let provider: ProviderConfiguration
    @State private var managementKey = ""
    @State private var managementError: String?
    @State private var hasManagementKey = false

    private var state: ProviderQuotaState { appState.providerQuota.state(for: provider.id) }
    private var isRouter: Bool { ProviderQuotaService.kind(provider) == .openRouter }
    private var consoleURL: URL? {
        let host = URLComponents(string: provider.baseURL)?.host?.lowercased()
        switch host {
        case "api.deepseek.com": return URL(string: "https://platform.deepseek.com/usage")
        case "api.moonshot.cn": return URL(string: "https://platform.moonshot.cn/console/account")
        case "api.moonshot.ai": return URL(string: "https://platform.moonshot.ai/console/account")
        case "openrouter.ai": return URL(string: "https://openrouter.ai/settings/credits")
        default:
            if ProviderQuotaService.kind(provider) == .relay { return ProviderQuotaService.relayRoot(provider) }
            return provider.authenticationSelection.credentialKind == .oauthAccessToken ? URL(string: "https://chatgpt.com/codex/cloud/settings/analytics#usage") : nil
        }
    }

    var body: some View {
        SettingsSection(title: "Balance and limits", description: "Provider account balances and key usage can include activity from other apps and devices.", trailing: {
            if !state.unsupported {
                Button { Task { await appState.providerQuota.refresh(provider, force: true) } } label: {
                    if state.loading { ProgressView().controlSize(.small) }
                    else { Label("Refresh", systemImage: "arrow.clockwise") }
                }.disabled(state.loading).controlSize(.small)
            }
        }) {
            if state.unsupported {
                Text("Remote balance is not supported for this provider.").foregroundStyle(.secondary)
            } else if state.loading && state.account == nil && state.key == nil {
                Text("Loading balance…").foregroundStyle(.secondary)
            }
            if isRouter {
                quotaPart(title: String(localized: "Current key usage and limits"), part: state.key, error: state.keyError)
                quotaPart(title: String(localized: "Account balance"), part: state.account, error: state.accountError)
                managementControls
            } else {
                quotaPart(title: String(localized: "Provider account balance"), part: state.account, error: state.accountError)
                if state.key != nil || state.keyError != nil {
                    quotaPart(title: String(localized: "Current key usage and limits"), part: state.key, error: state.keyError)
                }
            }
            HStack(spacing: AppSpacing.small) {
                if let consoleURL { Link("Open provider console", destination: consoleURL) }
                Button("View local usage") {
                    appState.usageProviderFilter = provider.id
                    window.screen = .settingsUsage
                }
            }
            .buttonStyle(.settingsOutline)
        }
        .task(id: "\(provider.id)|\(provider.baseURL)|\(provider.apiFormat.rawValue)|\(provider.authenticationSelection.credentialKind.rawValue)|\(appState.providerQuota.generation(for: provider.id))") {
            hasManagementKey = (try? appState.providers.managementKey(providerID: provider.id)) != nil
            await appState.providerQuota.refresh(provider)
        }
    }

    @ViewBuilder private func quotaPart(title: String, part: QuotaPart?, error: String?) -> some View {
        if let part {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(part.amounts) { amount in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(amount.label).foregroundStyle(.secondary)
                            Spacer()
                            if amount.unlimited { Text("No limit set") }
                            else if let text = amount.text {
                                Text(text).monospacedDigit().textSelection(.enabled)
                            } else if let value = amount.value {
                                Text("\(NSDecimalNumber(decimal: value).stringValue) \(amount.currency)")
                                    .monospacedDigit().textSelection(.enabled)
                            } else { Text("—") }
                        }.font(.callout)
                        if let fraction = amount.usedFraction {
                            ProgressView(value: fraction)
                                .tint(fraction >= 0.9 ? AppColors.statusError : fraction >= 0.75 ? .orange : .accentColor)
                                .controlSize(.small)
                        }
                        if let subtitle = amount.subtitle {
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Updated \(part.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if part.insufficient { InlineStatus(kind: .warning, message: "The provider reports that this balance is insufficient for API calls.") }
            }
        }
        if let error {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                if part != nil { Text("Showing previous data").font(.caption).foregroundStyle(.secondary) }
                Text(error).font(.caption).foregroundStyle(AppColors.statusError)
                if isRouter && state.accountPermissionDenied && title == String(localized: "Account balance") {
                    Text("This credential may not be allowed to query the account balance. Use the console or an optional Management Key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var managementControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsDivider()
            Text("Account balance Management Key (optional)").font(.subheadline.weight(.semibold))
            Text("A Management Key has account management permissions and is only used for balance queries. It is stored as plaintext in Limare's local credential file, protected by directory 0700 and file 0600 permissions. Confirm it belongs to the same account as your inference key.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(hasManagementKey ? "Enter a replacement Management Key" : "Enter a Management Key", text: $managementKey)
                    .textFieldStyle(.roundedBorder)
                Button(hasManagementKey ? "Replace" : "Save") {
                    do {
                        try appState.providers.saveManagementKey(managementKey, providerID: provider.id)
                        managementKey = ""; hasManagementKey = true; managementError = nil
                        Task { await appState.providerQuota.refresh(provider, force: true) }
                    } catch { managementError = error.localizedDescription }
                }.disabled(managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasManagementKey {
                    Button("Remove") {
                        do {
                            try appState.providers.deleteManagementKey(providerID: provider.id)
                            hasManagementKey = false; managementError = nil
                            Task { await appState.providerQuota.refresh(provider, force: true) }
                        } catch { managementError = error.localizedDescription }
                    }
                }
            }
            if let managementError { Text(managementError).font(.caption).foregroundStyle(AppColors.statusError) }
        }
    }
}
