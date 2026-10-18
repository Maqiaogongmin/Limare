import SwiftUI

/// Workspace entries matching the `@` token at the end of the draft. The highlighted row is
/// inserted on Return, Tab or a click; Escape closes the menu.
struct ComposerMentionMenu: View {
    let candidates: [ComposerMentionCandidate]
    let selection: Int
    let onHover: (Int) -> Void
    let onChoose: (ComposerMentionCandidate) -> Void

    var body: some View {
        ComposerMenuScroller(selection: selection) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: candidate.isDirectory ? "folder" : "doc")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(candidate.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let directory = (candidate.relativePath as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.vertical, AppSpacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.modal, style: .continuous)
                        .fill(index == selection ? Color.secondary.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
                .onHover { if $0 { onHover(index) } }
                // A tap, not a button: the editor keeps focus, so the menu stays open under the click.
                .onTapGesture { onChoose(candidate) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(index == selection ? .isSelected : [])
                .accessibilityAction { onChoose(candidate) }
                .id(index)
            }
        }
        .padding(AppSpacing.xxSmall)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.composer, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        .accessibilityIdentifier("composer.mentionMenu")
    }
}

/// The rows of a composer menu, scrolling past `AppLayout.composerMenuMaximumHeight` and
/// keeping the keyboard selection (rows tagged `.id(index)`) in view.
struct ComposerMenuScroller<Rows: View>: View {
    let selection: Int
    @ViewBuilder let rows: Rows
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) { rows }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(rowsHeight, AppLayout.composerMenuMaximumHeight))
            .onChange(of: selection) { _, newValue in proxy.scrollTo(newValue) }
        }
    }
}
