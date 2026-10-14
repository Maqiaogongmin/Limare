import SwiftUI

struct AgentRunRow: View {
    /// A research agent run of the removed pre-subagent delegation, rebuilt from its tool output.
    let run: DelegatedRunPresentation
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppSpacing.small) {
                statusIndicator

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text(run.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !run.status.isTerminal {
                            if let startedAt = run.startedAt {
                                Text("·")
                                    .foregroundStyle(.secondary)
                                TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
                                    Text(formattedDuration(from: startedAt, to: context.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if let startedAt = run.startedAt, let completedAt = run.completedAt {
                            Text("·")
                                .foregroundStyle(.secondary)
                            Text(formattedDuration(from: startedAt, to: completedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let activity = run.currentActivity, !activity.isEmpty {
                        Text(activity)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if run.status == .completed {
                        Text("Completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let err = run.error, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, AppSpacing.small)
            .background(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch run.status {
        case .queued:
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        case .cancelled:
            Image(systemName: "slash.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
        }
    }

    private func formattedDuration(from start: Date, to end: Date) -> String {
        let diff = max(0, Int(end.timeIntervalSince(start)))
        if diff < 60 {
            return "\(diff)s"
        }
        let mins = diff / 60
        let secs = diff % 60
        return "\(mins)m \(secs)s"
    }
}
