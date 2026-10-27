import SwiftUI

/// Browser Work Surface content view displaying the active conversation's `WKWebView`
/// with compact human navigation controls, ownership affordance, and quiet empty state.
/// A conversation with several tabs shows them in a row under the controls.
public struct BrowserSurfaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowSession.self) private var window

    @State private var urlInput: String = ""
    @State private var isEditingURL: Bool = false
    @FocusState private var isURLFieldFocused: Bool
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
        return appState.browser.shownTab(for: id)
    }

    /// The conversation's tabs, when it has several; a browser the user opened beside it has one.
    private var conversationTabs: [BrowserTab] {
        guard session == nil, let id = window.conversationID else { return [] }
        let tabs = appState.browser.tabs(for: id)
        return tabs.count > 1 ? tabs : []
    }

    public var body: some View {
        let store = browserStore
        let tab = currentTab
        VStack(spacing: 0) {
            navigationRow(store: store, tab: tab)
            let tabs = conversationTabs
            if !tabs.isEmpty {
                tabRow(store: store, tabs: tabs, shown: tab)
            }
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
                .accessibilityLabel("Back")

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
                .accessibilityLabel("Forward")

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
                .accessibilityLabel("Reload")

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
                    .focused($isURLFieldFocused)
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
                .accessibilityLabel("Open in Default Browser")

                // New tab, for the person; the agent's current tab stays where it is.
                if session == nil, tab != nil {
                    Button {
                        openNewTab(store: store)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: AppControlHeight.iconSmall, height: AppControlHeight.iconSmall)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textPrimary)
                    .help("New Tab")
                    .accessibilityLabel("New Tab")
                }

                if tab?.isLoading == true {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, AppSpacing.xxSmall)
                }

                // Compact Ownership Status & Take Control / Return to Agent
                if let tab, tab.hasSession {
                    HStack(spacing: AppSpacing.xxSmall) {
                        Circle()
                            .fill(tab.owner == .agent ? AppColors.statusInfo : AppColors.statusSuccess)
                            .frame(width: 6, height: 6)

                        Text(tab.owner.displayName)
                            .font(AppTypography.interfaceCaption2.weight(.medium))
                            .foregroundStyle(tab.owner == .agent ? AppColors.statusInfo : AppColors.statusSuccess)
                    }
                    .padding(.horizontal, AppSpacing.xSmall)
                    .padding(.vertical, 3)
                    .background(
                        (tab.owner == .agent ? AppColors.statusInfo : AppColors.statusSuccess).opacity(0.12)
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
        // The field shows the page's address; a tab with no page yet ("") never blanks an
        // address the user just entered.
        .onAppear {
            if !isEditingURL, let current = tab?.currentURL, !current.isEmpty {
                urlInput = current
            }
        }
        .onChange(of: tab?.currentURL) { _, newURL in
            if !isEditingURL, let newURL, !newURL.isEmpty {
                urlInput = newURL
            }
        }
        // Another tab shown: its address, blank for a new tab.
        .onChange(of: tab?.id) { _, _ in
            urlInput = tab?.currentURL ?? ""
            validationErrorMessage = nil
        }
    }

    // MARK: - Tab Row

    private func tabRow(store: BrowserSessionStore, tabs: [BrowserTab], shown: BrowserTab?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.xxSmall) {
                    ForEach(tabs) { item in
                        WorkSurfaceTabItemView(
                            title: Self.title(of: item),
                            systemImage: item.owner == .user ? "hand.raised" : "globe",
                            isActive: item === shown,
                            onSelect: { store.show(item) },
                            onClose: { store.closeByUser(item) }
                        )
                        .id(item.id)
                    }
                }
            }
            .onAppear { if let shown { proxy.scrollTo(shown.id) } }
            .onChange(of: shown?.id) { _, id in
                guard let id else { return }
                withAnimation(AppMotion.resolved(AppMotion.quick)) { proxy.scrollTo(id) }
            }
        }
        .padding(.horizontal, AppSpacing.standard)
        .padding(.bottom, AppSpacing.xSmall)
    }

    /// A tab's page title, else its host, else "New Tab".
    private static func title(of tab: BrowserTab) -> String {
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let host = URL(string: tab.currentURL)?.host(), !host.isEmpty { return host }
        return String(localized: "New Tab")
    }

    private func openNewTab(store: BrowserSessionStore) {
        guard let convID = activeConversationID else { return }
        do {
            try store.openTab(for: convID, owner: .user, makesCurrent: false)
            capacityNotice = nil
            urlInput = ""
            isURLFieldFocused = true
        } catch {
            capacityNotice = String(localized: "Browser tabs are full; try again when other conversations finish")
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
                urlInput = url.absoluteString
                isURLFieldFocused = false
                isEditingURL = false
            } else if let convID = activeConversationID {
                do {
                    let newTab = try store.getOrCreateTab(for: convID)
                    capacityNotice = nil
                    newTab.navigateByUser(to: url)
                    // Leave the field, so the page's address shows in it once it loads.
                    urlInput = url.absoluteString
                    isURLFieldFocused = false
                    isEditingURL = false
                } catch {
                    capacityNotice = String(localized: "Browser tabs are full; try again when other conversations finish")
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
                    .font(AppTypography.interface)
                    .foregroundStyle(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.standard)
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
