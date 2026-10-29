import Foundation
import Observation

/// Manages presentation state and tabs for the Right Work Surface.
/// Serves as the single source of truth for Work Surface UI visibility and active tab selection.
@MainActor
@Observable
public final class WorkSurfaceStore {
    var additionalBrowsers: [String: BrowserTab] = [:]
    /// The stores of Files tabs other than the navigator, by tab content ID.
    var filePreviews: [String: FilesSurfaceStore] = [:]

    /// Content ID of the Files tab backed by the app's own Files store.
    static let filesNavigatorID = "files"
    /// Content ID of the one Changes tab a window has.
    static let changesID = "changes"

    /// How far the Work Surface reaches past its own column, as a preview or page needs the room.
    public enum Coverage: Sendable, Equatable {
        /// Beside the chat.
        case none
        /// Over the chat column; the sidebar stays.
        case chat
        /// Over the whole window; the sidebar steps aside too.
        case window
    }

    public var isPresented: Bool = false {
        didSet { if !isPresented { coverage = .none } }
    }
    /// Hiding the Work Surface ends any coverage.
    public var coverage: Coverage = .none
    /// The chat column is covered.
    public var isExpanded: Bool { coverage != .none }
    public private(set) var tabs: [WorkSurfaceTab] = []
    public var activeTabID: UUID? = nil

    public init(
        isPresented: Bool = false,
        tabs: [WorkSurfaceTab] = [],
        activeTabID: UUID? = nil
    ) {
        self.isPresented = isPresented
        self.tabs = tabs
        self.activeTabID = activeTabID ?? tabs.first?.id
    }

    public var activeTab: WorkSurfaceTab? {
        if let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) {
            return tab
        }
        return tabs.first
    }

    public var hasTabs: Bool {
        !tabs.isEmpty
    }

    // MARK: - Presentation Controls

    public func show() {
        isPresented = true
    }

    public func hide() {
        isPresented = false
    }

    public func togglePresented() {
        isPresented.toggle()
    }

    /// Where a drag of the panel's leading edge to `pointerX` (window coordinates) puts the
    /// panel: beside the chat at the returned width, over the chat once the chat would be under
    /// half its minimum, over the window once the pointer passes the middle of the sidebar.
    /// `sidebarWidth` is 0 while the sidebar is hidden; `windowWidth` is the window's width.
    static func edgeDrag(
        pointerX x: Double,
        sidebarWidth sidebar: Double,
        windowWidth: Double,
        chatMinimum: Double,
        panelMinimum: Double
    ) -> (coverage: Coverage, width: Double?) {
        if sidebar > 0 && x < sidebar / 2 { return (.window, nil) }
        if x < sidebar + chatMinimum / 2 { return (.chat, nil) }
        let maximum = max(panelMinimum, windowWidth - sidebar - chatMinimum)
        return (.none, min(maximum, max(panelMinimum, windowWidth - x)))
    }

    /// The width the panel may take beside the chat, given the room.
    static func clampedPanelWidth(_ width: Double, windowWidth: Double, sidebarWidth: Double) -> Double {
        let maximum = max(Double(AppLayout.workSurfaceMinimumWidth),
                          windowWidth - sidebarWidth - Double(AppLayout.chatMinimumWidth))
        return min(maximum, max(Double(AppLayout.workSurfaceMinimumWidth), width))
    }

    /// The expand button: covered (by the button or a drag) goes back beside the chat;
    /// beside the chat fills the window.
    public func toggleExpanded() {
        coverage = coverage == .none ? .window : .none
    }

    // MARK: - Tab Operations

    /// Opens or focuses a tab matching `(kind, contentID)`.
    /// If an existing tab matches the semantic identity, focuses it without creating a duplicate.
    /// Ensures the Work Surface is presented.
    @discardableResult
    public func open(
        kind: WorkSurfaceKind,
        contentID: String,
        title: String? = nil,
        systemImage: String? = nil
    ) -> UUID {
        if let existing = tabs.first(where: { $0.matches(kind: kind, contentID: contentID) }) {
            activeTabID = existing.id
            isPresented = true
            return existing.id
        }

        let newTab = WorkSurfaceTab(
            kind: kind,
            contentID: contentID,
            title: title,
            systemImage: systemImage
        )
        tabs.append(newTab)
        activeTabID = newTab.id
        isPresented = true
        return newTab.id
    }

    /// Convenience helper to open or focus the shared Browser tab.
    @discardableResult
    public func openBrowser() -> UUID {
        open(kind: .browser, contentID: "browser")
    }

    /// Convenience helper to open or focus the Files tab.
    @discardableResult
    public func openFiles() -> UUID {
        open(kind: .files, contentID: Self.filesNavigatorID)
    }

    /// Focuses an existing tab by its unique identifier and ensures the Work Surface is presented.
    public func focus(id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        isPresented = true
    }

    /// Closes an individual presentation tab.
    /// If the tab was active, deterministically falls back to an adjacent tab.
    /// If closing the last tab, the Work Surface remains presented in the Launcher state.
    public func close(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        let wasActive = (activeTabID == id)
        let tab = tabs[index]
        additionalBrowsers.removeValue(forKey: tab.contentID)?.teardown()
        filePreviews.removeValue(forKey: tab.contentID)?.clearSelection()
        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
        } else if wasActive {
            if index < tabs.count {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs[tabs.count - 1].id
            }
        }
    }

    /// Closes an individual presentation tab by its semantic identity `(kind, contentID)`.
    public func closeTab(kind: WorkSurfaceKind, contentID: String) {
        if let target = tabs.first(where: { $0.matches(kind: kind, contentID: contentID) }) {
            close(id: target.id)
        }
    }

    /// Resets all ephemeral presentation tabs and collapses the Work Surface.
    func clearFilePreviews() {
        for tab in tabs.filter({ $0.kind == .files && $0.contentID != Self.filesNavigatorID }) {
            close(id: tab.id)
        }
    }

    public func reset() {
        for browser in additionalBrowsers.values { browser.teardown() }
        for files in filePreviews.values { files.clearSelection() }
        additionalBrowsers.removeAll()
        filePreviews.removeAll()
        tabs.removeAll()
        activeTabID = nil
        isPresented = false
    }
}
