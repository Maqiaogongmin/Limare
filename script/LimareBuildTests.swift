import Foundation

private struct BuildFailure: Error, CustomStringConvertible { let description: String }

/// Only a release-channel build takes updates from the public feed; everything else is development.
@main
struct LimareBuildTests {
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw BuildFailure(description: label) }
        print("PASS \(label)")
    }

    static func main() {
        do { try run() } catch { fputs("FAIL build channel: \(error)\n", stderr); exit(1) }
    }

    static func run() throws {
        let release = LimareBuild(info: ["CFBundleShortVersionString": "0.1.0", "LimareBuildChannel": "release", "LimareSourceCommit": ""])
        try check(release.channel == .release && release.takesPublicUpdates && release.displayVersion == "0.1.0",
                  "a release build takes public updates and shows its plain version")

        let installed = LimareBuild(info: ["CFBundleShortVersionString": "0.1.0", "LimareBuildChannel": "development", "LimareSourceCommit": "2584c818"])
        try check(!installed.takesPublicUpdates && installed.displayVersion == "0.1.0 · development build 2584c818",
                  "a development build never takes public updates and names its source commit")

        let unmarked = LimareBuild(info: ["CFBundleShortVersionString": "0.1.0"])
        try check(unmarked.channel == .development && !unmarked.takesPublicUpdates && unmarked.sourceCommit == nil,
                  "a build without a channel is treated as development")

        let unknown = LimareBuild(info: ["CFBundleShortVersionString": "0.1.0", "LimareBuildChannel": "$(LIMARE_BUILD_CHANNEL)"])
        try check(!unknown.takesPublicUpdates, "an unexpanded or unknown channel never takes public updates")
    }
}
