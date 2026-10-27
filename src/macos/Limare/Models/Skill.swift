import Foundation

enum SkillLocation: Sendable, Hashable, Equatable {
    case workspace(URL)
    case global(URL)

    var isWorkspace: Bool {
        if case .workspace = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .workspace: String(localized: "Project")
        case .global: String(localized: "Global")
        }
    }

    var rootURL: URL {
        switch self {
        case .workspace(let url), .global(let url):
            return url
        }
    }
}

struct Skill: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    var name: String
    var description: String
    var version: String
    var directoryURL: URL
    var fileURL: URL
    var location: SkillLocation
    var isEnabled: Bool
    var updatedAt: Date
    var body: String

    var sourcePath: String {
        fileURL.path
    }
}

extension String {
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
