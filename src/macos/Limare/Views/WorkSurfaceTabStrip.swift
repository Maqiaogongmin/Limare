import SwiftUI

/// Top Tab Strip for the Right Work Surface.
/// Manages open tabs, tab selection, tab closure, and expanding the surface to fill the window.
/// Frame height matches `AppLayout.workspaceHeaderHeight` (44pt) to ensure pixel-level alignment with Chat Header.
public struct WorkSurfaceTabStrip: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        HStack(spacing: AppSpacing.small) {
            // Scrollable / Horizontal Tab List
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xxSmall) {
                    ForEach(appState.workSurface.tabs) { tab in
                        WorkSurfaceTabItemView(
                            title: appState.workSurfaceTitle(for: tab),
                            systemImage: appState.workSurfaceSystemImage(for: tab),
                            isActive: tab.id == appState.workSurface.activeTabID,
                            onSelect: {
                                appState.workSurface.focus(id: tab.id)
                            },
                            onClose: {
                                appState.closeWorkSurfaceTab(id: tab.id)
                            }
                        )
                    }
                }
            }

            Spacer(minLength: 0)

            let isExpanded = appState.workSurface.isExpanded
            Button {
                appState.workSurface.toggleExpanded()
            } label: {
                Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workSurface.expand")
            .accessibilityLabel(isExpanded ? "Show Chat" : "Expand Work Surface")
            .help(isExpanded ? "Show the chat and sidebar again" : "Expand to fill the window")
        }
        .padding(.horizontal, AppSpacing.standard)
        .frame(height: AppLayout.workspaceHeaderHeight)
    }
}

private struct WorkSurfaceTabItemView: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : AppColors.textSecondary)

            Text(title)
                .font(AppTypography.interface.weight(isActive ? .medium : .regular))
                .foregroundStyle(isActive ? AppColors.textPrimary : AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 160, alignment: .leading)
                .help(title)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppColors.textMuted)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(title)")
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .fill(isActive ? AppColors.surfaceSecondary : (isHovered ? AppColors.surfaceInteractive : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .stroke(isActive ? AppColors.borderMuted : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
