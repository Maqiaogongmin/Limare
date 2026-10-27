import SwiftUI

struct AgentRunDetailSheet: View {
    let runID: UUID
    var presentation: DelegatedRunPresentation? = nil
    @Environment(\.dismiss) private var dismiss

    private var title: String { presentation?.title ?? String(localized: "Research Agent") }
    private var modelAttribution: String { presentation?.modelAttribution ?? "" }
    private var status: AgentRunStatus { presentation?.status ?? .failed }
    private var startedAt: Date? { presentation?.startedAt }
    private var completedAt: Date? { presentation?.completedAt }
    private var currentActivity: String? { presentation?.currentActivity }
    private var error: String? { presentation?.error }
    private var reportSummary: String? { presentation?.summary }

    var body: some View {
        content
            .closesOnClickOutside { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        if presentation != nil {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                        if !modelAttribution.isEmpty {
                            Text(modelAttribution)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    closeButton
                }
                .padding()
                Divider()

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.large) {
                        // Status & Timing Card
                        HStack(spacing: AppSpacing.medium) {
                            Label {
                                Text(status.displayName)
                                    .font(.subheadline.weight(.medium))
                            } icon: {
                                statusIcon(for: status)
                            }

                            Spacer()

                            if let startedAt, let completedAt {
                                let duration = max(0, Int(completedAt.timeIntervalSince(startedAt)))
                                Text("Duration: \(duration)s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let startedAt {
                                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                                    let duration = max(0, Int(context.date.timeIntervalSince(startedAt)))
                                    Text("Elapsed: \(duration)s")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(AppColors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))

                        // Current Activity if running
                        if let activity = currentActivity, !activity.isEmpty {
                            HStack(spacing: AppSpacing.small) {
                                ProgressView().controlSize(.small)
                                Text(activity)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, AppSpacing.small)
                        }


                        // Final Report
                        if let summary = reportSummary {
                            VStack(alignment: .leading, spacing: AppSpacing.small) {
                                Text("Research Report")
                                    .font(.subheadline.weight(.semibold))
                                Text(summary)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                        } else if let err = error {
                            VStack(alignment: .leading, spacing: AppSpacing.small) {
                                Text("Error")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
                                Text(err)
                                    .font(.body)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(minWidth: 500, minHeight: 400)
        } else {
            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding()
                Spacer()
                Text("Subagent record not found.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(minWidth: 400, minHeight: 200)
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Close")
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private func statusIcon(for status: AgentRunStatus) -> some View {
        switch status {
        case .queued, .running:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle.fill").foregroundStyle(.secondary)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark.fill").foregroundStyle(.orange)
        }
    }
}
