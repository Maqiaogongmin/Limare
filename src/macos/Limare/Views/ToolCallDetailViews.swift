import SwiftUI

extension View {
    /// A content block in the transcript, as a code block is drawn: a 2pt rule on its leading
    /// side and no fill or frame.
    func contentRule() -> some View {
        padding(.leading, 2 + AppSpacing.medium)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(AppColors.contentRule)
                    .frame(width: 2)
            }
    }
}

/// The readable details of a built-in tool call (`ToolCallDetail`); `.raw` and `.questions` draw
/// nothing here.
struct ToolCallDetailView: View {
    let detail: ToolCallDetail

    var body: some View {
        switch detail {
        case .shell(let command, let cwd, let output, let exitCode):
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                Text("$ \(command)")
                    .font(AppTypography.codeMeta)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cwd {
                    Text(cwd)
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !output.isEmpty {
                    ScrollView(.vertical) {
                        Text(output)
                            .font(AppTypography.codeMeta)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: AppLayout.toolOutputMaximumHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let exitCode {
                    Text("exit \(exitCode)")
                        .font(AppTypography.interfaceCaption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .textSelection(.enabled)
            .contentRule()
        case .fileContent(_, let text):
            scrolling(maxHeight: AppLayout.toolOutputMaximumHeight) {
                // A file's final newline ends its last line; it is not a blank line to show.
                Text(text.hasSuffix("\n") ? String(text.dropLast()) : text)
                    .font(AppTypography.codeMeta)
            }
        case .diff(_, let lines):
            scrolling(maxHeight: AppLayout.toolOutputMaximumHeight) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
            }
        case .entries(_, let items):
            scrolling(maxHeight: AppLayout.toolOutputMaximumHeight) {
                Text(items.map { $0.isDirectory ? $0.path + "/" : $0.path }.joined(separator: "\n"))
                    .font(AppTypography.codeMeta)
                    .foregroundStyle(.secondary)
            }
        case .matches(_, let items):
            scrolling(maxHeight: AppLayout.toolOutputMaximumHeight) {
                Text(items.map(Self.matchLine).joined(separator: "\n"))
                    .font(AppTypography.codeMeta)
                    .foregroundStyle(.secondary)
            }
        case .plan(let items):
            VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    PlanItemRow(item: item)
                }
            }
            .textSelection(.enabled)
            .contentRule()
        case .questions, .raw:
            EmptyView()
        }
    }

    private func scrolling<Content: View>(maxHeight: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical) {
            content()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .contentRule()
    }

    static func matchLine(_ match: ToolCallDetail.Match) -> String {
        guard let line = match.line else { return match.path }
        let snippet = match.snippet?.trimmingCharacters(in: .whitespaces) ?? ""
        return snippet.isEmpty ? "\(match.path):\(line)" : "\(match.path):\(line)  \(snippet)"
    }
}

private struct DiffLineRow: View {
    let line: ToolCallDetail.DiffLine

    private var color: Color? {
        switch line.kind {
        case .removed: AppColors.statusError
        case .added: AppColors.statusSuccess
        case .unchanged: nil
        }
    }

    private var prefix: String {
        switch line.kind {
        case .removed: "−"
        case .added: "+"
        case .unchanged: " "
        }
    }

    /// As the Changes view draws a line (`GitDiffView`): only the mark takes the colour, over a
    /// faint tint; whole lines in red and green were glaring.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(prefix)
                .foregroundStyle(color ?? AppColors.textMuted)
                .frame(width: 14, alignment: .leading)
            // Unchanged lines step back so the change reads without its colour.
            Text(line.text)
                .foregroundStyle(color == nil ? AppColors.textSecondary : AppColors.textPrimary)
        }
        .font(AppTypography.codeMeta)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color?.opacity(0.09) ?? .clear)
    }
}

private struct PlanItemRow: View {
    let item: ToolCallDetail.PlanItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
            switch item.status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                Text(item.step).foregroundStyle(.secondary)
            case .inProgress:
                Image(systemName: "circle.inset.filled").foregroundStyle(.primary)
                Text(item.step).fontWeight(.semibold).foregroundStyle(.primary)
            case .pending:
                Image(systemName: "circle").foregroundStyle(.tertiary)
                Text(item.step).foregroundStyle(.secondary)
            }
        }
        .font(AppTypography.interfaceSubheadline)
        .fixedSize(horizontal: false, vertical: true)
    }
}
