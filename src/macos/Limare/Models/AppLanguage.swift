import AppKit
import Foundation

/// Limare's display language.
///
/// The choices are the localizations the app bundle ships (the languages in
/// `Localizable.xcstrings`), so adding a language to the catalog adds it to Settings with no
/// code change. A choice is stored as the app's own `AppleLanguages` default, the same
/// per-app override macOS writes from System Settings › Language & Region › Applications,
/// so SwiftUI, AppKit and system-provided text (menus, panels, alerts) all follow it.
/// Like that system setting, a change takes effect when Limare next launches.
enum AppLanguage {
    private static let defaultsKey = "AppleLanguages"

    /// The languages Limare is translated into, as localization identifiers ("en", "zh-Hans").
    static var available: [String] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted { displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending }
    }

    /// The language chosen in Limare, or nil when Limare follows the system.
    /// Reads Limare's own domain only; the global `AppleLanguages` is the system list.
    static var selected: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?[defaultsKey] as? [String]
        else { return nil }
        return languages.first
    }

    /// The language the running app resolved its text to at launch.
    static var inEffect: String? {
        Bundle.main.preferredLocalizations.first
    }

    /// The language Limare shows when it follows the system: the first of the shipped
    /// languages in the system's preferred-language list.
    static var systemResolved: String? {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[defaultsKey] as? [String]
        return Bundle.preferredLocalizations(from: available, forPreferences: system).first
    }

    /// Chooses a language for the next launch; nil follows the system.
    static func select(_ language: String?) {
        if let language {
            UserDefaults.standard.set([language], forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// A language's name in that language ("English", "简体中文"), as a language list shows it.
    static func displayName(for language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Quits Limare and opens it again once this process has exited, so two copies never
    /// share the data store. Quitting runs the usual termination cleanup.
    @MainActor
    static func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try relauncher.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
