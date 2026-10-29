import SwiftUI

/// Top Tab Strip for the Right Work Surface.
/// Manages open tabs, tab selection, tab closure, and expanding the surface to fill the window.
/// Frame height matches `AppLayout.workspaceHeaderHeight` (44pt) to ensure pixel-level alignment with Chat Header.
public struct WorkSurfaceTabStrip: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    public init() {}

    public var body: some View {
        HStack(spacing: AppSpacing.small) {
            // Scrollable / Horizontal Tab List. The active tab is scrolled into view whenever it
            // changes, so a new or focused tab never sits past the edge with its close button.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xxSmall) {
                        ForEach(window.workSurface.tabs) { tab in
                            WorkSurfaceTabItemView(
                                title: window.workSurfaceTitle(for: tab),
                                systemImage: window.workSurfaceSystemImage(for: tab),
                                isActive: tab.id == window.workSurface.activeTabID,
                                onSelect: {
                                    window.workSurface.focus(id: tab.id)
                                },
                                onClose: {
                                    window.closeWorkSurfaceTab(id: tab.id)
                                }
                            )
                            .id(tab.id)
                        }

                        // A new tab, right after the last.
                        addSurfaceMenu
                    }
                }
                .onAppear { reveal(window.workSurface.activeTabID, with: proxy) }
                .onChange(of: window.workSurface.activeTabID) { _, active in reveal(active, with: proxy) }
                .onChange(of: window.workSurface.tabs.count) { _, _ in reveal(window.workSurface.activeTabID, with: proxy) }
            }

            Spacer(minLength: 0)

            let isExpanded = window.workSurface.isExpanded
            if !window.workSurface.tabs.isEmpty {
                Button {
                    window.workSurface.toggleExpanded()
                } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(GhostIconButtonStyle(size: 24, iconSize: 12))
                .accessibilityIdentifier("workSurface.expand")
                .accessibilityLabel(isExpanded ? "Show Chat" : "Expand Work Surface")
                .help(isExpanded ? "Show the chat and sidebar again" : "Expand to fill the window")
            }

            // The panel's own hide button, in its corner; the window toolbar shows the Work
            // Surface button only while the panel is hidden.
            Button {
                window.workSurface.togglePresented()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(GhostIconButtonStyle(size: 24, iconSize: 13))
            .accessibilityIdentifier("workSurface.hide")
            .accessibilityLabel("Work Surface")
            .help("Hide Work Surface")
        }
        .padding(.leading, AppSpacing.medium)
        .padding(.trailing, AppSpacing.small)
        .frame(height: AppLayout.workspaceHeaderHeight)
    }

    private var addSurfaceMenu: some View {
        Menu {
            ForEach(WorkSurfaceRegistry.builtInDefinitions) { def in
                Button {
                    window.addSurface(def.kind)
                } label: {
                    Label(def.title, systemImage: def.systemImage)
                }
            }
        } label: {
            Label("Add Surface", systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(GhostIconButtonStyle(size: 24, iconSize: 12))
        .help("Add Surface")
    }

    private func reveal(_ tabID: WorkSurfaceTab.ID?, with proxy: ScrollViewProxy) {
        guard let tabID else { return }
        withAnimation(AppMotion.resolved(AppMotion.quick)) { proxy.scrollTo(tabID) }
    }
}

/// One tab in a strip: the Work Surface's own, and a conversation's browser tabs.
struct WorkSurfaceTabItemView: View {
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
                .foregroundStyle(isActive ? Color.primary.opacity(0.85) : AppColors.textSecondary)

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
                .fill(isActive ? Color.primary.opacity(0.06) : (isHovered ? AppColors.surfaceInteractive : Color.clear))
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
