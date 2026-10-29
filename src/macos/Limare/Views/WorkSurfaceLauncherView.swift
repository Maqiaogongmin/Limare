import SwiftUI

/// Quiet Start / Launcher Surface displayed when the Right Work Surface is presented but has zero open tabs.
/// Lists the surfaces `WorkSurfaceRegistry` defines.
public struct WorkSurfaceLauncherView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    public init() {}

    public var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Spacer()

            VStack(spacing: AppSpacing.small) {
                ForEach(WorkSurfaceRegistry.builtInDefinitions) { def in
                    Button {
                        window.addSurface(def.kind)
                    } label: {
                        WorkSurfaceLauncherCard(definition: def)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: 320)
                }
            }
            .padding(.horizontal, AppSpacing.standard)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One surface to open: its icon on a quiet tile, its name and what it does. A hairline edge at
/// rest; a soft shadow lifts it under the pointer.
private struct WorkSurfaceLauncherCard: View {
    let definition: WorkSurfaceDefinition

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            Image(systemName: definition.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(Color.primary.opacity(0.80))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.title)
                    .font(AppTypography.interfaceMedium)
                    .foregroundStyle(AppColors.textPrimary)

                Text(definition.description)
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textMuted)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textMuted)
        }
        .padding(.horizontal, AppSpacing.medium)
        .padding(.vertical, AppSpacing.small + 2)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .fill(AppColors.workSurface)
                .shadow(color: .black.opacity(isHovering ? 0.06 : 0), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(AppColors.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(AppMotion.resolved(AppMotion.quick), value: isHovering)
    }
}
