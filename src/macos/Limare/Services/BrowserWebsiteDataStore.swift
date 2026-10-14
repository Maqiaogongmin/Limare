import Foundation
import WebKit

/// Manages Limare's dedicated, persistent Browser Profile website data store.
/// Independent from Safari.app, ensuring login states & cookies survive app restarts.
@MainActor
final class BrowserWebsiteDataStore {
    static let shared = BrowserWebsiteDataStore()

    /// Stable profile identifier for Limare's dedicated persistent WebKit store.
    static let profileUUID = UUID(uuidString: "8B4F8146-5F79-4B52-87C7-41A53D2A7BF1")!

    private let customStore: WKWebsiteDataStore

    init(identifier: UUID? = nil) {
        let id = identifier ?? BrowserWebsiteDataStore.profileUUID
        if #available(macOS 14.0, *) {
            self.customStore = WKWebsiteDataStore(forIdentifier: id)
        } else {
            self.customStore = .default()
        }
    }

    /// The persistent `WKWebsiteDataStore` for Limare Browser.
    var websiteDataStore: WKWebsiteDataStore {
        customStore
    }

    /// Removes all stored cookies, local storage, cache, and session data for the Limare profile.
    public func clearWebsiteData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await customStore.dataRecords(ofTypes: types)
        await customStore.removeData(ofTypes: types, for: records)
    }
}
