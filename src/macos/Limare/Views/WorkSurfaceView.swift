import SwiftUI

/// Root container for the Right Work Surface.
/// Hosts the shared Tab Strip and routes to the active surface content (or Launcher when no tabs are open).
public struct WorkSurfaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Always there, empty or not: it holds the add and hide buttons.
            WorkSurfaceTabStrip()

            if window.workSurface.tabs.isEmpty {
                WorkSurfaceLauncherView()
            } else if let activeTab = window.workSurface.activeTab {
                switch activeTab.kind {
                case .browser:
                    BrowserSurfaceView(session: window.workSurface.additionalBrowsers[activeTab.contentID])
                        .id(activeTab.id)
                case .files:
                    FilesSurfaceView(previewStore: window.workSurface.filePreviews[activeTab.contentID])
                        .id(activeTab.id)
                }
            } else {
                WorkSurfaceLauncherView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A white sheet lying on the canvas, its edge a hairline and a soft shadow, rather than
        // a column ruled off from the chat. Its content is clipped to the rounded corners.
        .background(AppColors.workSurface)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.workSurfaceSheet, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: AppRadius.workSurfaceSheet, style: .continuous)
                .fill(AppColors.workSurface)
                .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.workSurfaceSheet, style: .continuous)
                .strokeBorder(AppColors.raisedStroke, lineWidth: 1)
        )
    }
}
