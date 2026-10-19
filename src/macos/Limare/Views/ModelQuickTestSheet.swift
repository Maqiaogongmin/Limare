import SwiftUI

public struct ModelQuickTestSheet: View {
    let provider: ProviderConfiguration
    let model: ProviderModel
    let apiKey: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var testService = ProviderQuickTestService()
    @State private var hasStarted = false

    public init(
        provider: ProviderConfiguration,
        model: ProviderModel,
        apiKey: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }

    init(provider: ProviderConfiguration, model: ProviderModel, apiKey: String?, client: OpenAICompatibleClient) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        _testService = StateObject(wrappedValue: ProviderQuickTestService(client: client))
    }

    private var snapshot: ProviderDiagnosticsSnapshot {
        let hasResolvedKey = provider.authenticationMode == .none ? true : (apiKey != nil && !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
        return ProviderDiagnosticsSnapshot(
            provider: provider,
            model: model,
            apiKeyAvailable: hasResolvedKey
        )
    }

    private var applicableKinds: [QuickTestKind] {
        ProviderQuickTestService.applicableKinds(for: model, in: provider)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    headerSection
                    diagnosticsSection
                    testCardsSection
                }
                .padding(AppSpacing.large)
            }
            .navigationTitle("Quick Test & Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        testService.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await testService.runAll(provider: provider, model: model, apiKey: apiKey)
                        }
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(testService.isRunning || applicableKinds.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            if !hasStarted && !applicableKinds.isEmpty {
                hasStarted = true
                Task {
                    await testService.runAll(provider: provider, model: model, apiKey: apiKey)
                }
            }
        }
        .onDisappear {
            testService.cancel()
        }
    }

    private var headerSection: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: "bolt.badge.checkmark")
                .font(.system(size: 24))
                .foregroundStyle(AppColors.sendFill)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppSpacing.xSmall) {
                    Text(model.displayName)
                        .font(.title3.weight(.bold))
                    if model.isCustom {
                        Text("Custom")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(model.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Label(provider.name.isEmpty ? "Untitled Provider" : provider.name, systemImage: "server.rack")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(provider.apiFormat.displayName)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))

                    Text(provider.authenticationMode.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(AppSpacing.medium)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text("Diagnostics Snapshot")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                diagnosticRow(label: "Endpoint", value: snapshot.endpointSummary)
                diagnosticRow(
                    label: "Configuration",
                    value: snapshot.isConfigured ? "Ready" : "Incomplete",
                    valueColor: snapshot.isConfigured ? Color.green : Color.orange
                )

                HStack {
                    Text("Reasoning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 100, alignment: .leading)
                    if let sr = snapshot.supportsReasoning {
                        Text(sr ? "Supported" : "Not Supported")
                            .font(.caption)
                            .foregroundStyle(sr ? Color.purple : Color.secondary)
                    } else {
                        Text("Unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let ctx = snapshot.contextWindow {
                    diagnosticRow(label: "Context Window", value: "\(ctx) tokens")
                }
                if let maxTokens = snapshot.maxOutputTokens {
                    diagnosticRow(label: "Max Output", value: "\(maxTokens) tokens")
                }
            }
            .padding(AppSpacing.medium)
            .background(Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
        }
    }

    private func diagnosticRow(label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var testCardsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Capability Smoke Tests")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if applicableKinds.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: AppSpacing.xSmall) {
                        Image(systemName: "slash.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        Text("No supported Quick Tests for this model yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, AppSpacing.large)
                    Spacer()
                }
                .background(Color.secondary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
            } else {
                ForEach(applicableKinds) { kind in
                    QuickTestCard(
                        kind: kind,
                        result: testService.result(for: kind),
                        onRunSingle: {
                            Task {
                                _ = await testService.runSingleTest(
                                    kind: kind,
                                    provider: provider,
                                    model: model,
                                    apiKey: apiKey
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}

private struct QuickTestCard: View {
    let kind: QuickTestKind
    let isProbe: Bool
    let result: QuickTestResult?
    let onRunSingle: () -> Void

    init(
        kind: QuickTestKind,
        isProbe: Bool = false,
        result: QuickTestResult?,
        onRunSingle: @escaping () -> Void
    ) {
        self.kind = kind
        self.isProbe = isProbe
        self.result = result
        self.onRunSingle = onRunSingle
    }

    private var effectiveProbe: Bool {
        result?.isProbe ?? isProbe
    }

    private var cardTitle: String {
        effectiveProbe ? "\(kind.displayName) Probe" : kind.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: kind.icon)
                    .foregroundStyle(AppColors.sendFill)
                Text(cardTitle)
                    .font(.subheadline.weight(.semibold))
                if effectiveProbe {
                    Text("Probe")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                statusBadge
            }

            contentBody
        }
        .padding(AppSpacing.medium)
        .background(AppColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let result {
            switch result.status {
            case .idle:
                Text("Ready")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(effectiveProbe ? "Probing…" : "Testing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .passed(let duration, _):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(format: "%.2fs", duration))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            case .inconclusive(let duration, _):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Inconclusive · \(String(format: "%.2fs", duration))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                }
            case .failed(let duration, _):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(String(format: "%.2fs", duration))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            case .cancelled:
                HStack(spacing: 4) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Cancelled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Pending")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if let result {
            switch result.status {
            case .idle:
                Text("Tap 'Run Again' to test.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running:
                Text(kind == .vision ? (effectiveProbe ? "Probing vision capability with sample image..." : "Sending test image and prompt...") : "Sending text prompt...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .passed(_, let output):
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    if kind == .vision {
                        HStack(spacing: AppSpacing.small) {
                            RoundedRectangle(cornerRadius: AppRadius.small)
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.system(size: 14))
                                        .foregroundStyle(AppColors.sendFill)
                                )
                            Text("1x1 PNG sample image attached")
                                .font(.caption2)
                                .foregroundStyle(AppColors.textSecondary)
                        }
                        .padding(.bottom, AppSpacing.xxxSmall)
                    }
                    Text(output)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(AppSpacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
                }
            case .inconclusive(_, let diagnostic):
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(diagnostic)
                        .font(.callout)
                        .foregroundStyle(AppColors.statusWarning)
                        .textSelection(.enabled)
                        .padding(AppSpacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.statusWarning.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))

                    if result.observation.reasoningCharacters > 0 {
                        Text("Observed \(result.observation.reasoningCharacters) characters of thinking/reasoning content.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    } else if result.observation.toolCallEvents > 0 {
                        Text("Observed \(result.observation.toolCallEvents) tool call event(s).")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                }
            case .failed(_, let error):
                VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(AppColors.statusError)
                        .textSelection(.enabled)
                        .padding(AppSpacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.statusError.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
                }
            case .cancelled:
                Text("Request was cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
