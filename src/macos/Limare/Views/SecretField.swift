import SwiftUI

/// Pure state model for SecretField lifecycle and transitions.
struct SecretFieldStateModel: Equatable {
    var identity: AnyHashable?
    var hasStoredSecret: Bool
    var isReplacing: Bool = false
    var isRevealed: Bool = false
    var revealedText: String? = nil
    var isRevealing: Bool = false
    var revealError: String? = nil
    var inputBuffer: String = ""
    var isInputVisible: Bool = false

    mutating func updateIdentity(_ newIdentity: AnyHashable?) {
        if identity != newIdentity {
            identity = newIdentity
            reset()
        }
    }

    mutating func updateHasStoredSecret(_ newValue: Bool) {
        if hasStoredSecret != newValue {
            hasStoredSecret = newValue
            reset()
        }
    }

    mutating func handleReplacementSecretChanged(newValue: String?) {
        if newValue == nil && hasStoredSecret && isReplacing {
            reset()
        }
    }

    mutating func startReplacing() {
        reset()
        isReplacing = true
    }

    mutating func cancelReplacing() {
        reset()
    }

    mutating func hide() {
        isRevealed = false
        revealedText = nil
        revealError = nil
        isRevealing = false
    }

    mutating func startRevealing() {
        isRevealing = true
        revealError = nil
    }

    @discardableResult
    mutating func completeReveal(secret: String, targetIdentity: AnyHashable?) -> Bool {
        guard identity == targetIdentity else { return false }
        revealedText = secret
        isRevealed = true
        isRevealing = false
        return true
    }

    @discardableResult
    mutating func failReveal(errorDescription: String, targetIdentity: AnyHashable?) -> Bool {
        guard identity == targetIdentity else { return false }
        revealError = errorDescription
        isRevealing = false
        return true
    }

    mutating func reset() {
        isReplacing = false
        isRevealed = false
        revealedText = nil
        isRevealing = false
        revealError = nil
        inputBuffer = ""
        isInputVisible = false
    }
}

/// A reusable secret entry & display component conforming to the Harness UI Baseline.
///
/// States:
/// - `stored-hidden`: Shows a static mask placeholder (`••••••••••••••••`) without loading the plaintext secret into UI state.
/// - `stored-revealed`: Fetches the plaintext on demand via `onReveal`. Re-hiding completely drops the plaintext from memory.
/// - `replace-editing`: Uses an isolated replacement buffer when user clicks "Replace". Cancel restores `stored-hidden`.
/// - `editing`: Direct entry mode when no secret is stored.
struct SecretField: View {
    /// The exact credential shown. A change purges revealed plaintext and cancels an in-flight reveal.
    var identity: AnyHashable? = nil
    let hasStoredSecret: Bool
    @Binding var replacementSecret: String?
    var placeholder: String = "Enter API Key"
    var storedMask: String = "••••••••••••••••"
    /// What the secret is called in the status line.
    var secretName: String = "API Key"
    var onReveal: (() async throws -> String)?

    @State private var isReplacing = false
    @State private var isRevealed = false
    @State private var revealedText: String?
    @State private var isRevealing = false
    @State private var revealError: String?
    @State private var inputBuffer = ""
    @State private var isInputVisible = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.small) {
                fieldContent

                actionButtons
            }

            statusFooter
        }
        .onChange(of: identity) {
            resetState()
        }
        .onChange(of: hasStoredSecret) {
            resetState()
        }
        .onChange(of: replacementSecret) { _, newValue in
            if newValue == nil && hasStoredSecret && isReplacing {
                resetState()
            }
        }
        .onDisappear {
            resetState()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var fieldContent: some View {
        if hasStoredSecret && !isReplacing {
            if isRevealed, let text = revealedText {
                TextField(placeholder, text: .constant(text))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                HStack {
                    Text(storedMask)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, AppSpacing.small)
                .frame(height: AppControlHeight.regular)
                .background(AppColors.surfaceInteractive)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row)
                        .stroke(AppColors.borderMuted, lineWidth: 1)
                )
            }
        } else {
            Group {
                if isInputVisible {
                    TextField(placeholder, text: $inputBuffer)
                } else {
                    SecureField(placeholder, text: $inputBuffer)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onChange(of: inputBuffer) {
                let trimmed = inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                replacementSecret = trimmed.isEmpty ? "" : trimmed
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if hasStoredSecret && !isReplacing {
            if isRevealing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else if onReveal != nil {
                Button(action: toggleReveal) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide Secret" : "Reveal Secret")
            }

            Button("Replace") {
                startReplacing()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Replace stored secret")
        } else if hasStoredSecret && isReplacing {
            Button(action: { isInputVisible.toggle() }) {
                Image(systemName: isInputVisible ? "eye.slash" : "eye")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isInputVisible ? "Hide Secret" : "Show Secret")

            Button("Cancel") {
                cancelReplacing()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Cancel secret replacement")
        } else {
            // New / unconfigured secret
            Button(action: { isInputVisible.toggle() }) {
                Image(systemName: isInputVisible ? "eye.slash" : "eye")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(isInputVisible ? "Hide Secret" : "Show Secret")
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        if let error = revealError {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if hasStoredSecret && !isReplacing {
            Label("\(secretName) is saved in Limare private storage.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if hasStoredSecret && isReplacing {
            Label("Editing replacement key — save settings to store it.", systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        } else if !inputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("New \(secretName) entered — save settings to store it.", systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label("No \(secretName) is saved.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func toggleReveal() {
        revealTask?.cancel()
        revealTask = nil

        if isRevealed {
            isRevealed = false
            revealedText = nil
            revealError = nil
        } else {
            guard let onReveal else { return }
            let currentID = identity
            isRevealing = true
            revealError = nil
            revealTask = Task {
                do {
                    let secret = try await onReveal()
                    try Task.checkCancellation()
                    guard self.identity == currentID else { return }
                    self.revealedText = secret
                    self.isRevealed = true
                } catch is CancellationError {
                    // Ignored on cancellation
                } catch {
                    guard self.identity == currentID else { return }
                    self.revealError = "Failed to reveal secret: \(error.localizedDescription)"
                }
                guard self.identity == currentID else { return }
                self.isRevealing = false
            }
        }
    }

    private func startReplacing() {
        revealTask?.cancel()
        revealTask = nil
        isRevealed = false
        revealedText = nil
        revealError = nil
        inputBuffer = ""
        isInputVisible = false
        isReplacing = true
        replacementSecret = ""
    }

    private func cancelReplacing() {
        revealTask?.cancel()
        revealTask = nil
        isReplacing = false
        inputBuffer = ""
        isInputVisible = false
        revealError = nil
        replacementSecret = nil
    }

    private func resetState() {
        revealTask?.cancel()
        revealTask = nil
        isReplacing = false
        isRevealed = false
        revealedText = nil
        isRevealing = false
        revealError = nil
        inputBuffer = ""
        isInputVisible = false
    }
}
