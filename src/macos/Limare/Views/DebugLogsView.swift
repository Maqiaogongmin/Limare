import SwiftUI

struct DebugLogsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug Log")
                .font(.title2.weight(.semibold))
            Text(DebugLogPresentation.scopeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            List(appState.logs.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.category)
                            .font(.caption.weight(.semibold))
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.level.rawValue.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(entry.level == .error ? .red : .secondary)
                    }
                    Text(entry.message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
        }
        .padding()
    }
}
