import SwiftUI

/// Browser Work Surface content view displaying the active conversation's `WKWebView`
/// with compact human navigation controls, ownership affordance, and quiet empty state.
public struct BrowserSurfaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var urlInput: String = ""
    @State private var isEditingURL: Bool = false
    @State private var validationErrorMessage: String? = nil
    @State private var capacityNotice: String? = nil

    let session: BrowserTab?

    init(session: BrowserTab? = nil) { self.session = session }

    private var activeConversationID: UUID? {
        session?.conversationID ?? window.conversationID
    }

    private var browserStore: BrowserSessionStore {
        appState.browser
    }

    private var currentTab: BrowserTab? {
        if let session {
            return session
        }
        guard let id = window.conversationID else { return nil }
        return appState.browser.tab(for: id)
    }

    public var body: some View {
        let store = browserStore
        let tab = currentTab
        VStack(spacing: 0) {
            navigationRow(store: store, tab: tab)
            Divider()

            if let tab, tab.hasSession {
                activeContentView(tab: tab)
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: window.conversationID) {
            capacityNotice = nil
        }
    }

    // MARK: - Navigation & Control Row

    @ViewBuilder
    private func navigationRow(store: BrowserSessionStore, tab: BrowserTab?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppSpacing.xSmall) {
                // Back button
                Button {
                    tab?.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                }
                .buttonStyle(.plain)
                .disabled(tab?.canGoBack != true)
                .foregroundStyle(tab?.canGoBack == true ? AppColors.textPrimary : AppColors.textMuted)
                .help("Back")

                // Forward button
                Button {
                    tab?.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                }
                .buttonStyle(.plain)
                .disabled(tab?.canGoForward != true)
                .foregroundStyle(tab?.canGoForward == true ? AppColors.textPrimary : AppColors.textMuted)
                .help("Forward")

                // Reload button
                Button {
                    tab?.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                }
                .buttonStyle(.plain)
                .disabled(tab?.hasSession != true)
                .foregroundStyle(tab?.hasSession == true ? AppColors.textPrimary : AppColors.textMuted)
                .help("Reload")

                // URL Field
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                        .foregroundStyle(AppColors.textMuted)

                    TextField("Enter URL", text: $urlInput, onEditingChanged: { editing in
                        isEditingURL = editing
                        if !editing {
                            validationErrorMessage = nil
                        } else {
                            capacityNotice = nil
                        }
                    })
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit {
                        submitURL(store: store, tab: tab)
                    }

                    if !urlInput.isEmpty {
                        Button {
                            urlInput = ""
                            validationErrorMessage = nil
                            capacityNotice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(AppColors.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppSpacing.small)
                .padding(.vertical, 4)
                .background(AppColors.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .stroke(validationErrorMessage != nil ? AppColors.statusError.opacity(0.6) : AppColors.borderMuted, lineWidth: 1)
                )

                // Open in Default Browser
                Button {
                    tab?.openInExternalBrowser()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                }
                .buttonStyle(.plain)
                .disabled(tab?.hasSession != true)
                .foregroundStyle(tab?.hasSession == true ? AppColors.textPrimary : AppColors.textMuted)
                .help("Open in Default Browser")

                if tab?.isLoading == true {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, AppSpacing.xxSmall)
                }

                // Compact Ownership Status & Take Control / Return to Agent
                if let tab, tab.hasSession {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Circle()
                            .fill(tab.owner == .agent ? Color.blue : Color.green)
                            .frame(width: 6, height: 6)

                        Text(tab.owner.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(tab.owner == .agent ? Color.blue : Color.green)
                    }
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.vertical, 3)
                    .background(
                        (tab.owner == .agent ? Color.blue : Color.green).opacity(0.12)
                    )
                    .clipShape(Capsule())

                    if session != nil {
                        EmptyView()
                    } else if tab.owner == .agent {
                        Button {
                            tab.takeControl(logs: appState.logs)
                        } label: {
                            Label("Take Control", systemImage: "hand.raised")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button {
                            tab.returnToAgent(logs: appState.logs)
                        } label: {
                            Label("Return to Agent", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            if let err = validationErrorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(AppColors.statusError)
                    .padding(.leading, AppSpacing.small)
            }
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.vertical, AppSpacing.small)
        .onAppear {
            if !isEditingURL {
                urlInput = tab?.currentURL ?? ""
            }
        }
        .onChange(of: tab?.currentURL) { _, newURL in
            if !isEditingURL {
                urlInput = newURL ?? ""
            }
        }
    }

    private func submitURL(store: BrowserSessionStore, tab: BrowserTab?) {
        let result = BrowserNavigationTargetResolver.resolve(urlInput)
        switch result {
        case .empty:
            validationErrorMessage = nil
        case .valid(let url):
            validationErrorMessage = nil
            if let tab {
                capacityNotice = nil
                tab.navigateByUser(to: url)
            } else if let convID = activeConversationID {
                do {
                    let newTab = try store.getOrCreateTab(for: convID)
                    capacityNotice = nil
                    newTab.navigateByUser(to: url)
                } catch {
                    capacityNotice = "浏览器标签已满，等其他对话结束后再试"
                }
            }
        case .invalid(let msg):
            validationErrorMessage = msg
        }
    }

    // MARK: - Quiet Empty State

    private var emptyStateView: some View {
        VStack(spacing: AppSpacing.small) {
            Spacer()
            if let notice = capacityNotice {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(AppColors.statusWarning)
                Text(notice)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No page loaded")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textMuted)
                Text("Enter a URL above or start a browser task in Chat.")
                    .font(.caption)
                    .foregroundStyle(AppColors.textMuted)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Active Content View

    @ViewBuilder
    private func activeContentView(tab: BrowserTab) -> some View {
        ZStack {
            BrowserWebViewHost(webView: tab.runtime.webView)
                .allowsHitTesting(tab.allowsUserInteraction)

            if !tab.allowsUserInteraction {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
