import SwiftUI

struct ChatRunStatusView: View {
    let conversationID: UUID
    @Environment(AppState.self) private var appState
    @State private var showsDetails = false

    private var run: ConversationRun? { appState.conversationRuns.run(for: conversationID) }
    private var trace: RunTraceProjection? { run.map { appState.runtimeEvents.trace(for: $0.id) } }

    var body: some View {
        if let run, let trace {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: icon(for: run.status))
                    .foregroundStyle(color(for: run.status))
                Text(trace.currentStatus)
                    .font(AppTypography.interfaceSubheadline)
                Spacer()
                Button("View run details") { showsDetails = true }
                    .buttonStyle(.link)
                    .font(AppTypography.interfaceCaption)
            }
            .padding(.horizontal, AppSpacing.chatHorizontal)
            .padding(.vertical, AppSpacing.xSmall)
            .background(AppColors.surfaceElevated)
            .sheet(isPresented: $showsDetails) {
                RunTraceDetailSheet(run: run, trace: trace)
                    .environment(appState)
            }
        }
    }

    private func icon(for status: ConversationRunStatus) -> String {
        switch status {
        case .running, .queued: "circle.dotted"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        case .interrupted: "bolt.slash"
        }
    }
    private func color(for status: ConversationRunStatus) -> Color {
        switch status {
        case .failed: AppColors.statusError
        case .completed: AppColors.statusSuccess
        case .paused: AppColors.statusWarning
        case .running, .queued, .cancelled, .interrupted: AppColors.textSecondary
        }
    }
}

struct RunTraceDetailSheet: View {
    let run: ConversationRun
    let trace: RunTraceProjection
    @Environment(\.dismiss) private var dismiss
    @State private var showsTechnical = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Run details").font(AppTypography.interfaceTitle2)
                    if let provider = trace.actualProvider, let model = trace.actualModel { Text("\(provider) · \(model)").font(AppTypography.interfaceCaption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done") { dismiss() }
            }.padding()
            Divider()
            List(trace.events) { event in
                HStack(alignment: .top, spacing: AppSpacing.small) {
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .font(AppTypography.interfaceCaption.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        // Routine lifecycle steps carry no label; causes, diagnostics, routing
                        // and the result keep theirs.
                        if event.presentationRole != .lifecycle {
                            Text(event.presentationRole.rawValue).font(AppTypography.interfaceCaption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(event.summary).font(AppTypography.interface)
                    }
                }.padding(.vertical, 2)
            }
            Divider()
            HStack { Spacer(); Button("Technical details") { showsTechnical.toggle() }.buttonStyle(.link).font(AppTypography.interfaceSubheadline) }.padding()
            if showsTechnical {
                ScrollView { VStack(alignment: .leading, spacing: 8) {
                    ForEach(trace.events) { event in
                        Text("\(event.kind)  \(event.metadata.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "  "))")
                            .font(AppTypography.codeMeta).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom]) }
            }
        }.frame(minWidth: 560, minHeight: 420)
    }

}
