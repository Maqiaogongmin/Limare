import SwiftUI

/// Quiet Start / Launcher Surface displayed when the Right Work Surface is presented but has zero open tabs.
/// Only lists registered, fully available surface definitions (currently Browser).
public struct WorkSurfaceLauncherView: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        VStack(spacing: AppSpacing.medium) {
            Spacer()

            VStack(spacing: AppSpacing.small) {
                ForEach(WorkSurfaceRegistry.builtInDefinitions) { def in
                    Button {
                        appState.addSurface(def.kind)
                    } label: {
                        HStack(spacing: AppSpacing.medium) {
                            Image(systemName: def.systemImage)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.title)
                                    .font(AppTypography.interfaceMedium)
                                    .foregroundStyle(AppColors.textPrimary)

                                Text(def.description)
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
                        .background(AppColors.surfaceSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                                .stroke(AppColors.borderMuted, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
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
