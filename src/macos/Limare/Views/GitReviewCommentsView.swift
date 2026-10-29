import SwiftUI

/// Every review comment of the conversation: jump to its line, edit, delete, or clear them all.
struct GitReviewCommentsView: View {
    let store: GitReviewStore
    let onClose: () -> Void

    @State private var confirmsClear = false

    private var sorted: [GitReviewComment] {
        store.comments.sorted {
            ($0.anchor.path, $0.anchor.line) < ($1.anchor.path, $1.anchor.line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review Comments")
                    .font(AppTypography.interfaceMedium)
                Spacer(minLength: 0)
                Button("Clear All") { confirmsClear = true }
                    .buttonStyle(.plain)
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .disabled(store.comments.isEmpty)
            }
            .padding(AppSpacing.medium)

            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { comment in
                        row(comment)
                        Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 340)
        .confirmationDialog("Delete all review comments?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                store.clearComments()
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ comment: GitReviewComment) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.xxSmall) {
                Text(verbatim: "\(comment.anchor.path):\(comment.anchor.line)")
                    .font(AppTypography.codeMeta)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(ChangesScopeLabel.title(comment.anchor.scope, base: comment.anchor.base, taskBase: store.taskBaseName))
                    .font(AppTypography.interfaceCaption2)
                    .foregroundStyle(AppColors.textMuted)
                    .lineLimit(1)
                if comment.isOutdated {
                    Text("Outdated")
                        .font(AppTypography.interfaceCaption2)
                        .foregroundStyle(AppColors.cautionIcon)
                }
                Spacer(minLength: 0)
            }
            Text(comment.anchor.quote)
                .font(AppTypography.codeMeta)
                .foregroundStyle(AppColors.textMuted)
                .lineLimit(1)
            Text(comment.body)
                .font(AppTypography.interface)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(3)
            HStack(spacing: AppSpacing.medium) {
                Button("Show") {
                    store.reveal(comment)
                    onClose()
                }
                Button("Edit") {
                    store.edit(comment)
                    onClose()
                }
                Button("Delete") { store.deleteComment(id: comment.id) }
            }
            .buttonStyle(.plain)
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small)
        .accessibilityElement(children: .contain)
    }
}
