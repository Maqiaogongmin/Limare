import SwiftUI

struct AgentRunGroupView: View {
    let toolCall: ToolCallRecord
    @State private var selectedRunID: UUID?

    /// Runs of the removed pre-subagent delegation, rebuilt from the tool output; a native
    /// delegate_task call has none and shows as an ordinary tool card.
    private var runs: [DelegatedRunPresentation] {
        ToolCallPresentationResolver.extractDelegatedRuns(from: toolCall.output)
    }

    private func aggregateHeader(for runs: [DelegatedRunPresentation]) -> String {
        let totalCount = runs.count
        let agentNoun = totalCount == 1 ? "agent" : "agents"
        let prefix = "Research · \(totalCount) \(agentNoun)"

        let succeeded = runs.filter { $0.status == .completed }.count
        let timedOut = runs.filter { $0.status == .timedOut }.count
        let failed = runs.filter { $0.status == .failed }.count
        let cancelled = runs.filter { $0.status == .cancelled }.count
        let active = runs.filter { $0.status == .running || $0.status == .queued }.count

        if active > 0 {
            var parts: [String] = ["\(active) active"]
            if succeeded > 0 { parts.append("\(succeeded) succeeded") }
            if timedOut > 0 { parts.append("\(timedOut) timed out") }
            if failed > 0 { parts.append("\(failed) failed") }
            return "\(prefix) · " + parts.joined(separator: " · ")
        }

        // Terminal state
        if succeeded == totalCount {
            return "\(prefix) · \(succeeded) succeeded"
        }

        var parts: [String] = []
        parts.append("\(succeeded) succeeded")
        if timedOut > 0 {
            parts.append("\(timedOut) timed out")
        }
        if failed > 0 {
            parts.append("\(failed) failed")
        }
        if cancelled > 0 {
            parts.append("\(cancelled) cancelled")
        }
        return "\(prefix) · " + parts.joined(separator: " · ")
    }

    private var headerIconColor: Color {
        let presentation = ToolCallPresentationResolver.resolve(toolCall: toolCall, runs: runs)
        switch presentation.tone {
        case .danger: return .red
        case .warning: return .orange
        case .success: return .purple
        case .active: return .blue
        case .neutral: return .purple
        }
    }

    var body: some View {
        let currentRuns = runs
        if !currentRuns.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                HStack(spacing: AppSpacing.xSmall) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(headerIconColor)
                        .font(.caption)
                    Text(aggregateHeader(for: currentRuns))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, AppSpacing.xxSmall)

                VStack(spacing: 4) {
                    ForEach(currentRuns) { run in
                        AgentRunRow(
                            run: run,
                            onSelect: {
                                selectedRunID = run.id
                            }
                        )
                    }
                }
            }
            .padding(AppSpacing.small)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .sheet(isPresented: Binding(
                get: { selectedRunID != nil },
                set: { if !$0 { selectedRunID = nil } }
            )) {
                if let runID = selectedRunID {
                    AgentRunDetailSheet(
                        runID: runID,
                        presentation: currentRuns.first(where: { $0.id == runID })
                    )
                }
            }
        } else {
            ToolCallCard(toolCall: toolCall)
        }
    }
}
