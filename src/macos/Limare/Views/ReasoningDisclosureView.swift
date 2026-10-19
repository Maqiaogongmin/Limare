import SwiftUI

/// Dedicated, independent presentation component for Provider-exposed Reasoning (RP-I15.B).
///
/// Strictly renders retained model reasoning from `ChatMessage.reasoningContent`.
/// Completely orthogonal to primary communication Markdown, tool calls, and copy/speaker payloads.
struct ReasoningDisclosureView: View {
    let reasoning: String
    let state: ChatMessage.State
    let hasVisibleOutput: Bool

    @State private var isManuallyExpanded: Bool? = nil

    var isExpanded: Bool {
        isManuallyExpanded ?? false
    }

    var label: String {
        state == .streaming && !hasVisibleOutput ? "Thinking…" : "Thought process"
    }

    static func hasVisibleOutput(content: String, toolCalls: [ToolCallRecord]) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !toolCalls.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AppMotion.resolved(AppMotion.standard)) {
                    isManuallyExpanded = !isExpanded
                }
            } label: {
                // Lined up with the tool rows it sits among, and as quiet: no fill of its own.
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(label)
                        .font(AppTypography.interfaceSubheadline)
                        .foregroundStyle(Color.secondary)

                    Spacer()
                }
                .padding(.vertical, AppSpacing.xxSmall)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Text(reasoning)
                        .font(AppTypography.chatBodyItalic)
                        .foregroundStyle(.secondary)
                        .lineSpacing(AppTypography.chatLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppSpacing.small)
                        .padding(.vertical, AppSpacing.small)
                }
                .background(Color.secondary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
                )
                .padding(.top, AppSpacing.xxSmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
