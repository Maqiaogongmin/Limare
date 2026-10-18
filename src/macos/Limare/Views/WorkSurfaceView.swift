import SwiftUI

/// Root container for the Right Work Surface.
/// Hosts the shared Tab Strip and routes to the active surface content (or Launcher when no tabs are open).
public struct WorkSurfaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // At the bottom of the title row, continuing the line under the chat's title.
            Divider()

            if !window.workSurface.tabs.isEmpty {
                WorkSurfaceTabStrip()
                Divider()
            }

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
        // One column from the top of the window down, in the content's own background, so it
        // reads as part of the window rather than something hung off the chat. A hairline
        // separates it from the chat.
        .background {
            AppColors.surfacePrimary
                .overlay(alignment: .leading) {
                    Rectangle().fill(AppColors.separator).frame(width: 1)
                }
                .ignoresSafeArea(edges: .top)
        }
    }
}
