import Foundation

/// Which line a running Limare was built from, read from its Info.plist.
///
/// Published releases (Xcode Archive of the Release configuration) are the `release` channel and
/// take updates from limare.app through Sparkle. Development builds (Debug, and the builds
/// script/install_limare.sh installs from limare/mainline) are newer than the last release and
/// share its bundle identifier, so an "update" from the public feed would replace them with older
/// code: they never start the updater. Same idea as Ghostty's and Zed's separate dev channels.
struct LimareBuild: Equatable {
    enum Channel: String {
        case release
        case development
    }

    let version: String
    let channel: Channel
    /// The source commit a development build was made from, when the build recorded one.
    let sourceCommit: String?

    static let current = LimareBuild(info: Bundle.main.infoDictionary ?? [:])

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        // Anything not explicitly marked as a release is treated as development, so a build that
        // lost the key can never update itself from the public feed.
        channel = (info["LimareBuildChannel"] as? String).flatMap(Channel.init(rawValue:)) ?? .development
        let commit = (info["LimareSourceCommit"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        sourceCommit = commit.isEmpty ? nil : commit
    }

    var takesPublicUpdates: Bool { channel == .release }

    /// "0.1.0" for a release; "0.1.0 · development build 2584c818" otherwise.
    var displayVersion: String {
        guard channel == .development else { return version }
        return sourceCommit.map { "\(version) · development build \($0)" } ?? "\(version) · development build"
    }
}
