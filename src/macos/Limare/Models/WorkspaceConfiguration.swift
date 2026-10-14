import Foundation

struct WorkspaceConfiguration: Codable, Sendable, Equatable {
    let name: String
    let path: String
    let bookmarkData: Data?
    let usesSecurityScope: Bool

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    static func from(url rawURL: URL) -> WorkspaceConfiguration {
        let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
        let bookmark: Data?
        let usesSecurityScope: Bool
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = true
        } catch {
            bookmark = try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            usesSecurityScope = false
        }
        return WorkspaceConfiguration(
            name: url.lastPathComponent,
            path: url.path,
            bookmarkData: bookmark,
            usesSecurityScope: usesSecurityScope
        )
    }
}
