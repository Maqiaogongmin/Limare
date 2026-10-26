import SwiftUI

struct ChatRunStatusView: View {
    let conversationID: UUID
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    private var line: RunStatusStripLine? {
        guard let run = appState.conversationRuns.run(for: conversationID) else { return nil }
        return RunStatusStripPolicy.line(status: run.status, trace: appState.runtimeEvents.trace(for: run.id))
    }

    var body: some View {
        if let line {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: line.symbolName)
                    .foregroundStyle(color(for: line.tone))
                Text(line.text)
                    .font(AppTypography.interfaceSubheadline)
                Spacer()
                Button("View run details") { window.showsRunDetails = true }
                    .buttonStyle(QuietLinkButtonStyle())
            }
            .padding(.leading, AppSpacing.medium)
            .padding(.trailing, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xxSmall)
            // A thin inset strip on the canvas, not a full-width band.
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .stroke(AppColors.hairline, lineWidth: 1)
            )
            .padding(.horizontal, AppSpacing.standard)
            .padding(.top, AppSpacing.xSmall)
        }
    }

    private func color(for tone: RunStatusStripLine.Tone) -> Color {
        switch tone {
        case .error: AppColors.statusError
        case .warning: AppColors.statusWarning
        case .secondary: AppColors.textSecondary
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
