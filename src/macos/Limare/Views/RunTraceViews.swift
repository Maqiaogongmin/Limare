import SwiftUI

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
