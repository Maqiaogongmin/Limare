import Foundation

/// Semantic content types that the Right Work Surface can host.
public enum WorkSurfaceKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case browser
    case files
    case changes

    public var id: String { rawValue }

    public var defaultTitle: String {
        switch self {
        case .browser:
            return String(localized: "Browser")
        case .files:
            return String(localized: "Files")
        case .changes:
            return String(localized: "Changes")
        }
    }

    public var defaultSystemImage: String {
        switch self {
        case .browser:
            return "globe"
        case .files:
            return "folder"
        case .changes:
            return "plus.forwardslash.minus"
        }
    }
}

/// Represents an individual presentation tab inside the Right Work Surface.
public struct WorkSurfaceTab: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: WorkSurfaceKind
    public let contentID: String
    public var title: String
    public var systemImage: String

    public init(
        id: UUID = UUID(),
        kind: WorkSurfaceKind,
        contentID: String,
        title: String? = nil,
        systemImage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.contentID = contentID
        self.title = title ?? kind.defaultTitle
        self.systemImage = systemImage ?? kind.defaultSystemImage
    }

    /// Checks whether this tab matches the specified semantic identity `(kind, contentID)`.
    public func matches(kind: WorkSurfaceKind, contentID: String) -> Bool {
        self.kind == kind && self.contentID == contentID
    }
}

/// Descriptor defining an available work surface type for the Launcher and `+` add menu.
public struct WorkSurfaceDefinition: Identifiable, Equatable, Sendable {
    public var id: WorkSurfaceKind { kind }
    public let kind: WorkSurfaceKind
    public let title: String
    public let systemImage: String
    public let description: String
    public let order: Int

    public init(
        kind: WorkSurfaceKind,
        title: String,
        systemImage: String,
        description: String,
        order: Int
    ) {
        self.kind = kind
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.order = order
    }
}

/// Boundary registry listing built-in work surface definitions.
public enum WorkSurfaceRegistry {
    /// Currently registered built-in work surface definitions.
    /// Only contains fully implemented surfaces.
    public static let builtInDefinitions: [WorkSurfaceDefinition] = [
        WorkSurfaceDefinition(
            kind: .browser,
            title: String(localized: "Browser"),
            systemImage: "globe",
            description: String(localized: "Open the Agent web surface"),
            order: 0
        ),
        WorkSurfaceDefinition(
            kind: .files,
            title: String(localized: "Files"),
            systemImage: "folder",
            description: String(localized: "Browse workspace files and documents"),
            order: 1
        ),
        WorkSurfaceDefinition(
            kind: .changes,
            title: String(localized: "Changes"),
            systemImage: "plus.forwardslash.minus",
            description: String(localized: "Review the project's Git changes and comment on lines"),
            order: 2
        )
    ]
}
