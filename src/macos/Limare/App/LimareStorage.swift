import Foundation

/// Where Limare keeps its data when a store is not given an explicit storage root.
///
/// Only the Limare app itself uses the user's Application Support directory. Any other process
/// built from these sources, such as the script test runners or an XCTest host, gets a
/// per-process temporary directory instead, so a test that forgets to pass a storage root can
/// never read or write the user's conversations, settings or logs. A process whose home is
/// already redirected away from the user's (HOME / CFFIXED_USER_HOME, as the sandboxed test
/// runners do) keeps the ordinary location inside that home.
enum LimareStorage {
    static let bundleIdentifier = "app.limare.Limare"

    static let isLimareApp: Bool = Bundle.main.bundleIdentifier == bundleIdentifier
        && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    /// The Application Support directory of the current home, for code that must guard it.
    static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static let applicationSupport: URL = isLimareApp || homeIsRedirected ? userApplicationSupport
        : FileManager.default.temporaryDirectory.appendingPathComponent("limare-isolated-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static let caches: URL = isLimareApp || homeIsRedirected
        ? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        : applicationSupport.appendingPathComponent("Caches", isDirectory: true)

    /// The default data root: Application Support/app.limare.Limare for the app.
    static var defaultRoot: URL { applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true) }

    private static var homeIsRedirected: Bool {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return false }
        let accountHome = URL(fileURLWithPath: String(cString: directory)).standardizedFileURL.path
        return URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path != accountHome
    }
}
