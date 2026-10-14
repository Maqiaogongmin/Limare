import Foundation

public enum ResourceResolver {
    /// Directly resolves the referenced resource through its canonical source authority without creating an Artifact.
    /// Requires requestingConversationID when resolving conversation-scoped resources.
    public static func resolveDirect(
        ref: ResourceRef,
        in workspaceURL: URL?,
        artifactStore: ArtifactStore? = nil,
        requestingConversationID: UUID? = nil,
        hostFileAdmission: HostFileAccessAdmission? = nil,
        attachmentStore: AttachmentStore? = nil,
        attachmentAdmission: AttachmentResourceAdmission? = nil
    ) throws -> ResourceResolvedContent {
        switch ref.kind {
        case .workspaceFile:
            guard let wsURL = workspaceURL else {
                throw ResourceResolutionError.unavailable("Workspace URL is required to resolve workspace file reference.")
            }

            let currentScope = ResourceRef.workspaceFingerprint(for: wsURL)
            guard currentScope == ref.authorityScope else {
                throw ResourceResolutionError.denied("Workspace authority mismatch: reference belongs to workspace [\(ref.authorityScope)], but current workspace is [\(currentScope)].")
            }

            if let refConv = ref.conversationScope {
                guard let requester = requestingConversationID, requester == refConv else {
                    throw ResourceResolutionError.denied("Conversation scope mismatch: resource is scoped to [\(refConv)], but requester is [\(requestingConversationID?.uuidString ?? "none")].")
                }
            }

            let resolvedURL: URL
            do {
                resolvedURL = try WorkspacePathResolver.resolve(ref.locator, relativeTo: wsURL, mustExist: false)
            } catch {
                throw ResourceResolutionError.missing("Failed to resolve workspace path: \(ref.locator)")
            }

            guard WorkspacePathResolver.isInsideWorkspace(resolvedURL, workspaceURL: wsURL) else {
                throw ResourceResolutionError.denied("Path '\(ref.locator)' escapes workspace boundaries.")
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir), !isDir.boolValue else {
                throw ResourceResolutionError.missing("File not found at '\(resolvedURL.path)'.")
            }

            let data: Data
            do {
                data = try Data(contentsOf: resolvedURL)
            } catch {
                throw ResourceResolutionError.failed("Failed to read file at '\(resolvedURL.path)': \(error.localizedDescription)")
            }

            let diskMIME = MIMETypeHelper.mimeType(for: resolvedURL.lastPathComponent)
            let repDescriptor: RepresentationDescriptor
            if diskMIME != "application/octet-stream" {
                repDescriptor = RepresentationDescriptor(mimeType: diskMIME, epistemicLevel: .inferred)
            } else if let hintMIME = ref.representationHint?.mimeType, !hintMIME.isEmpty {
                repDescriptor = RepresentationDescriptor(mimeType: hintMIME, epistemicLevel: .declared)
            } else {
                repDescriptor = RepresentationDescriptor(mimeType: "application/octet-stream", epistemicLevel: .inferred)
            }
            let filename = ref.representationHint?.filename ?? resolvedURL.lastPathComponent

            return ResourceResolvedContent(
                data: data,
                representation: repDescriptor,
                filename: filename,
                ownerDomain: .workspace,
                sourceRef: ref
            )

        case .artifact:
            guard let store = artifactStore else {
                throw ResourceResolutionError.unavailable("ArtifactStore is required to resolve artifact reference.")
            }
            guard let artifactUUID = UUID(uuidString: ref.locator) else {
                throw ResourceResolutionError.missing("Invalid artifact UUID locator: '\(ref.locator)'.")
            }
            guard let resourceConvID = ref.conversationScope else {
                throw ResourceResolutionError.denied("Artifact reference lacks canonical conversation scope.")
            }
            guard ref.authorityScope == resourceConvID.uuidString else {
                throw ResourceResolutionError.denied("Malformed artifact reference: authorityScope [\(ref.authorityScope)] does not match conversationScope [\(resourceConvID)].")
            }
            guard let requester = requestingConversationID else {
                throw ResourceResolutionError.denied("Requesting conversation context is required to resolve artifact reference.")
            }
            guard requester == resourceConvID else {
                throw ResourceResolutionError.denied("Cross-conversation access denied: artifact belongs to conversation [\(resourceConvID)], but requester is [\(requester)].")
            }

            let desc: ArtifactDescriptor
            do {
                desc = try store.resolveDescriptor(artifactID: artifactUUID, conversationID: requester)
            } catch let error as ArtifactStoreError {
                switch error {
                case .artifactNotFound, .fileMissing:
                    throw ResourceResolutionError.missing(error.localizedDescription)
                case .fileExpired:
                    throw ResourceResolutionError.expired(error.localizedDescription)
                case .unauthorizedAccess:
                    throw ResourceResolutionError.denied(error.localizedDescription)
                case .integrityMismatch(let exp, let act):
                    throw ResourceResolutionError.integrityMismatch(expected: exp, actual: act)
                default:
                    throw ResourceResolutionError.failed(error.localizedDescription)
                }
            } catch {
                throw ResourceResolutionError.failed(error.localizedDescription)
            }

            let data: Data
            do {
                data = try store.loadData(artifactID: artifactUUID, conversationID: requester)
            } catch let error as ArtifactStoreError {
                switch error {
                case .fileMissing:
                    throw ResourceResolutionError.missing(error.localizedDescription)
                case .fileExpired:
                    throw ResourceResolutionError.expired(error.localizedDescription)
                case .unauthorizedAccess:
                    throw ResourceResolutionError.denied(error.localizedDescription)
                case .integrityMismatch(let exp, let act):
                    throw ResourceResolutionError.integrityMismatch(expected: exp, actual: act)
                default:
                    throw ResourceResolutionError.failed(error.localizedDescription)
                }
            } catch {
                throw ResourceResolutionError.failed(error.localizedDescription)
            }

            let level = desc.representationEpistemicLevel ?? .inferred
            let repDescriptor = RepresentationDescriptor(mimeType: desc.mimeType, epistemicLevel: level, establishedProfile: desc.representationProfile)
            return ResourceResolvedContent(
                data: data,
                representation: repDescriptor,
                filename: desc.filename,
                ownerDomain: .artifactAuthority,
                sourceRef: ref
            )

        case .hostFile:
            guard hostFileAdmission?.admits(ref) == true else {
                throw ResourceResolutionError.denied("Host source requires matching user-selection admission.")
            }
            let url = URL(fileURLWithPath: ref.locator).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ResourceResolutionError.missing("Selected host file is no longer available.")
            }
            do {
                let data = try Data(contentsOf: url)
                let filename = ref.representationHint?.filename ?? url.lastPathComponent
                let mime = MIMETypeHelper.mimeType(for: filename)
                return ResourceResolvedContent(
                    data: data,
                    representation: RepresentationDescriptor(mimeType: mime, epistemicLevel: .declared),
                    filename: filename,
                    ownerDomain: .host,
                    sourceRef: ref
                )
            } catch {
                throw ResourceResolutionError.failed("Failed to read selected host file.")
            }

        case .attachment:
            // Attachment identity is not authorization. Every check below is
            // ordered so that a denied requester is refused before any byte is read.
            guard let resourceConvID = ref.conversationScope else {
                throw ResourceResolutionError.denied("Attachment reference lacks canonical conversation scope.")
            }
            guard ref.authorityScope == resourceConvID.uuidString else {
                throw ResourceResolutionError.denied("Malformed attachment reference: authorityScope [\(ref.authorityScope)] does not match conversationScope [\(resourceConvID)].")
            }
            guard let requester = requestingConversationID else {
                throw ResourceResolutionError.denied("Requesting conversation context is required to resolve attachment reference.")
            }
            guard requester == resourceConvID else {
                throw ResourceResolutionError.denied("Cross-conversation access denied: attachment belongs to conversation [\(resourceConvID)], but requester is [\(requester)].")
            }
            guard let admission = attachmentAdmission, admission.conversationID == requester, admission.admits(ref) else {
                throw ResourceResolutionError.denied("Attachment source requires a matching conversation attachment admission.")
            }
            guard let store = attachmentStore else {
                throw ResourceResolutionError.unavailable("AttachmentStore is required to resolve attachment reference.")
            }
            // Exact identity: the admitted canonical attachment must be the one
            // this locator names, and any AttachmentStore registry entry for that
            // locator must agree with it.
            let attachment = admission.attachment
            guard AttachmentReferenceFormatter.uri(for: attachment) == ref.locator else {
                throw ResourceResolutionError.denied("Attachment admission does not match the referenced attachment identity.")
            }
            if let registered = store.attachment(forURI: ref.locator), registered.id != attachment.id {
                throw ResourceResolutionError.integrityMismatch(expected: attachment.id.uuidString, actual: registered.id.uuidString)
            }

            let fileURL: URL
            do {
                fileURL = try store.fileURL(for: attachment)
            } catch {
                throw ResourceResolutionError.missing("Attachment backing file for '\(ref.locator)' is no longer available.")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ResourceResolutionError.missing("Attachment backing file for '\(ref.locator)' is no longer available.")
            }

            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ResourceResolutionError.failed("Failed to read attachment bytes for '\(ref.locator)': \(error.localizedDescription)")
            }

            let mime = attachment.mimeType.isEmpty
                ? (ref.representationHint?.mimeType ?? "application/octet-stream")
                : attachment.mimeType
            return ResourceResolvedContent(
                data: data,
                representation: RepresentationDescriptor(mimeType: mime, epistemicLevel: .declared),
                filename: attachment.filename,
                ownerDomain: .attachment,
                sourceRef: ref
            )

        case .mcpResource, .url:
            throw ResourceResolutionError.unsupported("Direct resolution for resource kind '\(ref.kind.rawValue)' is not supported in this seam.")
        }
    }

    /// Explicitly materializes a ResourceRef into a durable ArtifactRef owned by Artifact Authority.
    /// Retains parent provenance without modifying or transferring ownership of the source.
    /// Authorization provenance must be supplied from the caller's actual admission path and is never fabricated.
    public static func materialize(
        ref: ResourceRef,
        to conversationID: UUID,
        in workspaceURL: URL?,
        artifactStore: ArtifactStore,
        authorizationProvenance: String? = nil
    ) throws -> ArtifactRef {
        switch ref.kind {
        case .workspaceFile:
            guard let wsURL = workspaceURL else {
                throw ResourceResolutionError.unavailable("Workspace URL is required to materialize workspace file.")
            }

            let currentScope = ResourceRef.workspaceFingerprint(for: wsURL)
            guard currentScope == ref.authorityScope else {
                throw ResourceResolutionError.denied("Workspace authority mismatch: reference belongs to workspace [\(ref.authorityScope)], but current workspace is [\(currentScope)].")
            }

            if let refConv = ref.conversationScope, refConv != conversationID {
                throw ResourceResolutionError.denied("Conversation scope mismatch: resource is scoped to [\(refConv)], but target is [\(conversationID)].")
            }

            let resolvedURL: URL
            do {
                resolvedURL = try WorkspacePathResolver.resolve(ref.locator, relativeTo: wsURL, mustExist: true)
            } catch {
                throw ResourceResolutionError.missing("Source file '\(ref.locator)' not found for materialization.")
            }

            guard WorkspacePathResolver.isInsideWorkspace(resolvedURL, workspaceURL: wsURL) else {
                throw ResourceResolutionError.denied("Source path '\(ref.locator)' escapes workspace boundaries.")
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir), !isDir.boolValue else {
                throw ResourceResolutionError.missing("Source file not found or is a directory at '\(resolvedURL.path)'.")
            }

            let data: Data
            do {
                data = try Data(contentsOf: resolvedURL)
            } catch {
                throw ResourceResolutionError.failed("Failed to read source bytes from '\(resolvedURL.path)': \(error.localizedDescription)")
            }

            let diskMIME = MIMETypeHelper.mimeType(for: resolvedURL.lastPathComponent)
            let mimeType: String
            let epistemicLevel: RepresentationEpistemicLevel
            if diskMIME != "application/octet-stream" {
                mimeType = diskMIME
                epistemicLevel = .inferred
            } else if let hintMIME = ref.representationHint?.mimeType, !hintMIME.isEmpty {
                mimeType = hintMIME
                epistemicLevel = .declared
            } else {
                mimeType = "application/octet-stream"
                epistemicLevel = .inferred
            }
            let filename = ref.representationHint?.filename ?? resolvedURL.lastPathComponent

            let desc = try artifactStore.save(
                data: data,
                conversationID: conversationID,
                filename: filename,
                mimeType: mimeType,
                representationEpistemicLevel: epistemicLevel,
                producerProvenance: .workspaceRegistration,
                workspaceProvenance: resolvedURL,
                authorizationProvenance: authorizationProvenance,
                parentResourceLocator: ref.id,
                retentionClass: .conversationRetained
            )

            return ArtifactRef(artifactID: desc.artifactID, conversationID: desc.conversationID)

        case .artifact:
            guard let aid = UUID(uuidString: ref.locator) else {
                throw ResourceResolutionError.missing("Invalid artifact UUID locator: '\(ref.locator)'.")
            }
            guard let resourceConvID = ref.conversationScope else {
                throw ResourceResolutionError.denied("Artifact reference lacks conversation scope.")
            }
            guard resourceConvID == conversationID else {
                throw ResourceResolutionError.denied("Cross-conversation artifact materialization denied: [\(resourceConvID)] -> [\(conversationID)].")
            }
            guard ref.authorityScope == resourceConvID.uuidString else {
                throw ResourceResolutionError.denied("Malformed artifact reference: authorityScope [\(ref.authorityScope)] does not match conversationScope [\(resourceConvID)].")
            }

            _ = try artifactStore.resolveDescriptor(artifactID: aid, conversationID: conversationID)
            return ArtifactRef(artifactID: aid, conversationID: conversationID)

        case .hostFile, .attachment, .mcpResource, .url:
            throw ResourceResolutionError.unsupported("Materialization for resource kind '\(ref.kind.rawValue)' is not supported in this seam.")
        }
    }

    /// Checks the current availability of the referenced resource without side effects.
    /// Enforces requestingConversationID validation for conversation-scoped resources.
    public static func checkAvailability(
        ref: ResourceRef,
        in workspaceURL: URL?,
        artifactStore: ArtifactStore? = nil,
        requestingConversationID: UUID? = nil
    ) -> ResourceAvailability {
        switch ref.kind {
        case .workspaceFile:
            guard let wsURL = workspaceURL else { return .unavailable }
            let currentScope = ResourceRef.workspaceFingerprint(for: wsURL)
            guard currentScope == ref.authorityScope else {
                return .denied
            }
            if let refConv = ref.conversationScope {
                guard let requester = requestingConversationID, requester == refConv else {
                    return .denied
                }
            }
            do {
                let resolvedURL = try WorkspacePathResolver.resolve(ref.locator, relativeTo: wsURL, mustExist: false)
                guard WorkspacePathResolver.isInsideWorkspace(resolvedURL, workspaceURL: wsURL) else {
                    return .denied
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDir), !isDir.boolValue {
                    return .available
                } else {
                    return .missing
                }
            } catch {
                return .missing
            }

        case .artifact:
            guard let store = artifactStore,
                  let aid = UUID(uuidString: ref.locator),
                  let resourceConvID = ref.conversationScope else {
                return .unavailable
            }
            guard ref.authorityScope == resourceConvID.uuidString else {
                return .denied
            }
            guard let requester = requestingConversationID else {
                return .denied
            }
            guard requester == resourceConvID else {
                return .denied
            }
            do {
                let desc = try store.resolveDescriptor(artifactID: aid, conversationID: requester)
                switch desc.retentionState {
                case .available:
                    return .available
                case .missing:
                    return .missing
                case .expired:
                    return .expired
                }
            } catch let error as ArtifactStoreError {
                switch error {
                case .unauthorizedAccess:
                    return .denied
                case .fileMissing, .artifactNotFound:
                    return .missing
                case .fileExpired:
                    return .expired
                case .integrityMismatch:
                    return .integrityMismatch
                default:
                    return .failed
                }
            } catch {
                return .failed
            }

        case .hostFile, .attachment, .mcpResource, .url:
            return .unknown
        }
    }
}
