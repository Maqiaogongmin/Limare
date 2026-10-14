import Foundation
import CryptoKit

public enum ResourceKind: String, Codable, Sendable, Equatable, CaseIterable {
    case workspaceFile = "workspace_file"
    case hostFile = "host_file"
    case attachment = "attachment"
    case mcpResource = "mcp_resource"
    case url = "url"
    case artifact = "artifact"

    public var canonicalOwnerDomain: ResourceOwnerDomain {
        switch self {
        case .workspaceFile: return .workspace
        case .hostFile: return .host
        case .attachment: return .attachment
        case .mcpResource: return .mcp
        case .url: return .remote
        case .artifact: return .artifactAuthority
        }
    }
}

public enum ResourceOwnerDomain: String, Codable, Sendable, Equatable {
    case workspace = "workspace"
    case host = "host"
    case attachment = "attachment"
    case mcp = "mcp"
    case remote = "remote"
    case artifactAuthority = "artifact_authority"
}

public enum ResourceAvailability: String, Codable, Sendable, Equatable {
    case available
    case unavailable
    case missing
    case expired
    case denied
    case integrityMismatch
    case failed
    case unknown
}

public enum ResourceResolutionError: Error, LocalizedError, Sendable, Equatable {
    case missing(String)
    case denied(String)
    case unavailable(String)
    case expired(String)
    case unsupported(String)
    case integrityMismatch(expected: String, actual: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let reason):
            return "Resource missing: \(reason)"
        case .denied(let reason):
            return "Resource access denied: \(reason)"
        case .unavailable(let reason):
            return "Resource unavailable: \(reason)"
        case .expired(let reason):
            return "Resource expired: \(reason)"
        case .unsupported(let reason):
            return "Resource unsupported: \(reason)"
        case .integrityMismatch(let exp, let act):
            return "Resource integrity mismatch: expected \(exp), got \(act)"
        case .failed(let reason):
            return "Resource resolution failed: \(reason)"
        }
    }
}

public struct ResourceProvenance: Codable, Equatable, Sendable {
    public let sourceKind: ResourceKind
    public let sourceIdentifier: String
    public let authorityScope: String
    public let conversationID: UUID?
    public let operation: String?

    public init(
        sourceKind: ResourceKind,
        sourceIdentifier: String,
        authorityScope: String,
        conversationID: UUID? = nil,
        operation: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.sourceIdentifier = sourceIdentifier
        self.authorityScope = authorityScope
        self.conversationID = conversationID
        self.operation = operation
    }
}

public struct ResourceRepresentationHint: Codable, Equatable, Sendable {
    public let mimeType: String?
    public let filename: String?
    public let estimatedByteCount: Int64?

    public init(
        mimeType: String? = nil,
        filename: String? = nil,
        estimatedByteCount: Int64? = nil
    ) {
        self.mimeType = mimeType
        self.filename = filename
        self.estimatedByteCount = estimatedByteCount
    }
}

public struct ResourceRef: Codable, Equatable, Sendable, Identifiable {
    public let kind: ResourceKind
    public let locator: String
    public let authorityScope: String
    public let conversationScope: UUID?
    public let representationHint: ResourceRepresentationHint?
    public let provenance: ResourceProvenance?

    public var ownerDomain: ResourceOwnerDomain {
        kind.canonicalOwnerDomain
    }

    public var id: String {
        "\(kind.rawValue):\(authorityScope):\(locator)"
    }

    public init(
        kind: ResourceKind,
        locator: String,
        authorityScope: String,
        conversationScope: UUID? = nil,
        representationHint: ResourceRepresentationHint? = nil,
        provenance: ResourceProvenance? = nil
    ) {
        self.kind = kind
        self.locator = locator
        self.authorityScope = authorityScope
        self.conversationScope = conversationScope
        self.representationHint = representationHint
        self.provenance = provenance
    }

    public static func workspaceFingerprint(for url: URL) -> String {
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(canonicalPath.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func workspaceFile(
        path: String,
        workspaceURL: URL,
        conversationScope: UUID? = nil
    ) -> ResourceRef {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = (cleanPath as NSString).lastPathComponent
        let mime = MIMETypeHelper.mimeType(for: filename)
        let scope = workspaceFingerprint(for: workspaceURL)
        return ResourceRef(
            kind: .workspaceFile,
            locator: cleanPath,
            authorityScope: scope,
            conversationScope: conversationScope,
            representationHint: ResourceRepresentationHint(mimeType: mime, filename: filename),
            provenance: ResourceProvenance(
                sourceKind: .workspaceFile,
                sourceIdentifier: cleanPath,
                authorityScope: scope,
                conversationID: conversationScope
            )
        )
    }

    /// A stable identity for a user-selected host URL. It represents the host
    /// source only; access still requires a matching invocation admission.
    public static func hostFile(url: URL) -> ResourceRef {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = canonical.path
        let scope = workspaceFingerprint(for: canonical.deletingLastPathComponent())
        let filename = canonical.lastPathComponent
        let estimatedByteCount = (try? canonical.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        return ResourceRef(
            kind: .hostFile,
            locator: path,
            authorityScope: scope,
            representationHint: ResourceRepresentationHint(
                mimeType: MIMETypeHelper.mimeType(for: filename),
                filename: filename,
                estimatedByteCount: estimatedByteCount
            ),
            provenance: ResourceProvenance(sourceKind: .hostFile, sourceIdentifier: filename, authorityScope: scope)
        )
    }

    /// Stable, conversation-owned identity for a chat attachment that the
    /// Attachment Authority already stores.
    ///
    /// The locator is the canonical `limare://attachments/...` identity, never the
    /// absolute `AttachmentStore` disk path. Like every other `ResourceRef`, this
    /// carries identity and representation metadata only: it is not an
    /// authorization claim, and resolving it still requires a matching
    /// `AttachmentResourceAdmission` for the requesting conversation.
    public static func attachment(
        _ attachment: ChatAttachment,
        conversationID: UUID
    ) -> ResourceRef {
        let scope = conversationID.uuidString
        let locator = AttachmentReferenceFormatter.uri(for: attachment)
        return ResourceRef(
            kind: .attachment,
            locator: locator,
            authorityScope: scope,
            conversationScope: conversationID,
            representationHint: ResourceRepresentationHint(
                mimeType: attachment.mimeType,
                filename: attachment.filename,
                estimatedByteCount: Int64(attachment.byteCount)
            ),
            provenance: ResourceProvenance(
                sourceKind: .attachment,
                sourceIdentifier: locator,
                authorityScope: scope,
                conversationID: conversationID
            )
        )
    }

    public static func artifact(
        artifactRef: ArtifactRef,
        mimeType: String? = nil,
        filename: String? = nil
    ) -> ResourceRef {
        let scope = artifactRef.conversationID.uuidString
        return ResourceRef(
            kind: .artifact,
            locator: artifactRef.artifactID.uuidString,
            authorityScope: scope,
            conversationScope: artifactRef.conversationID,
            representationHint: ResourceRepresentationHint(mimeType: mimeType, filename: filename),
            provenance: ResourceProvenance(
                sourceKind: .artifact,
                sourceIdentifier: artifactRef.artifactID.uuidString,
                authorityScope: scope,
                conversationID: artifactRef.conversationID
            )
        )
    }
}

/// Invocation-scoped evidence that a particular host source was selected by
/// the user. It is intentionally not a permission registry or durable grant.
public struct HostFileAccessAdmission: Sendable, Equatable {
    public let sourceRefID: String
    public let provenance: String

    public init(source: ResourceRef, provenance: String) {
        self.sourceRefID = source.id
        self.provenance = provenance
    }

    public func admits(_ source: ResourceRef) -> Bool {
        source.kind == .hostFile && source.id == sourceRefID
    }
}

/// A host resource paired with the real UI invocation that admitted it.  This
/// is deliberately constructed at the picker/drop boundary, never from a
/// plain URL inside a downstream consumer.
public struct HostFileSelection: Sendable, Equatable {
    public let source: ResourceRef
    public let admission: HostFileAccessAdmission

    private init(url: URL, admissionProvenance: String) {
        let source = ResourceRef.hostFile(url: url)
        self.source = source
        self.admission = HostFileAccessAdmission(source: source, provenance: admissionProvenance)
    }

    /// Use only for URLs returned by a successful NSOpenPanel invocation.
    public static func openPanelSelection(url: URL) -> HostFileSelection {
        HostFileSelection(url: url, admissionProvenance: "user_file_picker")
    }

    /// Use only for an existing file the user named in their own message with `@<path>`.
    public static func typedByUser(url: URL) -> HostFileSelection {
        HostFileSelection(url: url, admissionProvenance: "user_typed_path")
    }

    /// Use only for URLs delivered by a user drag-and-drop invocation.
    public static func droppedByUser(url: URL) -> HostFileSelection {
        HostFileSelection(url: url, admissionProvenance: "user_file_drop")
    }

    /// Use only for a file the signed-in owner uploaded through Remote Access, which Limare itself
    /// wrote into its own upload directory.
    public static func uploadedByOwner(url: URL) -> HostFileSelection {
        HostFileSelection(url: url, admissionProvenance: "remote_owner_upload")
    }
}

/// Invocation-scoped evidence that one exact chat attachment is genuinely part of
/// the requesting conversation's canonical history.
///
/// It is deliberately **not** a `PermissionStore`, an attachment permission
/// registry, or a durable grant. It exists only for the duration of one tool
/// invocation, can only be built from real canonical conversation messages, and
/// cannot be manufactured from a `limare://attachments/...` string alone.
public struct AttachmentResourceAdmission: Sendable, Equatable {
    public let conversationID: UUID
    /// Exact `ResourceRef.id` of the admitted attachment resource.
    public let sourceRefID: String
    /// Exact canonical attachment identity (`limare://attachments/<id>`).
    public let attachmentURI: String
    /// The exact attachment value the canonical conversation history owns.
    public let attachment: ChatAttachment

    private init(conversationID: UUID, sourceRefID: String, attachmentURI: String, attachment: ChatAttachment) {
        self.conversationID = conversationID
        self.sourceRefID = sourceRefID
        self.attachmentURI = attachmentURI
        self.attachment = attachment
    }

    /// Builds an admission for exactly the attachment that the conversation's
    /// canonical history already owns under `sourceURI`.
    ///
    /// A URI that the caller merely asserts, and that no canonical message
    /// contains, yields `nil` — even if a file with that name happens to exist
    /// on disk.
    /// Internal because the canonical history value type is module-internal: the
    /// admission can only be produced inside the production module from real
    /// canonical messages, never by an external caller asserting a URI.
    static func admit(
        sourceURI: String,
        conversationID: UUID,
        canonicalMessages: [ChatMessage]
    ) -> AttachmentResourceAdmission? {
        let trimmed = sourceURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for message in canonicalMessages {
            for attachment in message.attachments {
                guard AttachmentReferenceFormatter.uri(for: attachment) == trimmed else { continue }
                let ref = ResourceRef.attachment(attachment, conversationID: conversationID)
                return AttachmentResourceAdmission(
                    conversationID: conversationID,
                    sourceRefID: ref.id,
                    attachmentURI: trimmed,
                    attachment: attachment
                )
            }
        }
        return nil
    }

    /// A conversation A admission can never admit conversation B's attachment,
    /// and an admission for attachment A can never admit attachment B.
    public func admits(_ source: ResourceRef) -> Bool {
        source.kind == .attachment
            && source.conversationScope == conversationID
            && source.id == sourceRefID
    }
}

public struct ResourceResolvedContent: Sendable, Equatable {
    public let data: Data
    public let representation: RepresentationDescriptor
    public let filename: String?
    public let ownerDomain: ResourceOwnerDomain
    public let sourceRef: ResourceRef

    public var mimeType: String? {
        representation.mimeType
    }

    public init(
        data: Data,
        representation: RepresentationDescriptor,
        filename: String?,
        ownerDomain: ResourceOwnerDomain,
        sourceRef: ResourceRef
    ) {
        self.data = data
        self.representation = representation
        self.filename = filename
        self.ownerDomain = ownerDomain
        self.sourceRef = sourceRef
    }

    public init(
        data: Data,
        mimeType: String?,
        filename: String?,
        ownerDomain: ResourceOwnerDomain,
        sourceRef: ResourceRef
    ) {
        let mime = mimeType ?? "application/octet-stream"
        let desc = RepresentationDescriptor(mimeType: mime, epistemicLevel: .inferred)
        self.init(
            data: data,
            representation: desc,
            filename: filename,
            ownerDomain: ownerDomain,
            sourceRef: sourceRef
        )
    }
}
