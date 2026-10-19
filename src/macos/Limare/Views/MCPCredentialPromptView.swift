import SwiftUI

struct MCPCredentialPromptView: View {
    @Environment(AppState.self) private var appState
    let request: MCPCredentialRequest

    @State private var token = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(AppColors.sendFill)
                Text("Credential Required")
                    .font(.title2.weight(.semibold))
            }

            Text("The MCP connection “\(request.serverName)” needs a credential to start.")
                .font(.subheadline)
                .foregroundStyle(AppColors.textSecondary)

            GroupBox {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text(request.promptText)
                        .font(.caption)
                        .foregroundStyle(AppColors.textPrimary)

                    SecureField(request.credentialName, text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("Stored in Limare's private storage. Never shown to AI models, chat logs or configuration files.")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.xxSmall)
            } label: {
                Text(request.credentialName)
                    .font(.caption.weight(.medium))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.mcp.resolveCredentialRequest(id: request.id, credential: nil)
                }
                Button("Save & Connect") {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isSubmitting = true
                    appState.mcp.resolveCredentialRequest(id: request.id, credential: trimmed)
                }
                .buttonStyle(.charcoalProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(minWidth: AppLayout.approvalMinimumWidth, idealWidth: AppLayout.approvalIdealWidth)
        .interactiveDismissDisabled()
    }
}
