import Foundation

public struct RepresentationResolver: Sendable {
    public let converters: [RepresentationConverter]

    public init(converters: [RepresentationConverter] = []) {
        self.converters = converters
    }

    /// Resolves a resource to satisfy the consumer's representation requirement.
    /// If the resource already satisfies the requirement (taking into account epistemic level),
    /// returns .satisfied with 0 conversions and 0 artifacts created.
    /// If conversion is required and a legal single-hop converter route exists, converts, validates the output,
    /// and commits a derived ArtifactRef to Artifact Authority with parent provenance and route provenance.
    public func resolve(
        ref: ResourceRef,
        requirement: RepresentationRequirement,
        in workspaceURL: URL?,
        artifactStore: ArtifactStore? = nil,
        requestingConversationID: UUID,
        targetConversationID: UUID,
        retentionClass: ArtifactRetentionClass = .conversationRetained,
        authorizationProvenance: String? = nil,
        hostFileAdmission: HostFileAccessAdmission? = nil,
        retentionIntent: RepresentationRetentionIntent? = nil,
        attachmentStore: AttachmentStore? = nil,
        attachmentAdmission: AttachmentResourceAdmission? = nil
    ) async -> RepresentationTerminalResult {
        let attemptID = UUID()
        let initialSourceRep: RepresentationDescriptor
        if let hint = ref.representationHint, let mime = hint.mimeType, !mime.isEmpty {
            initialSourceRep = RepresentationDescriptor(
                mimeType: mime,
                epistemicLevel: .declared
            )
        } else {
            initialSourceRep = RepresentationDescriptor(
                mimeType: "application/octet-stream",
                epistemicLevel: .inferred
            )
        }

        // Step 1: Pre-flight cancellation check
        if Task.isCancelled {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .cancelled,
                cleanupStatus: .notRequired,
                failureReason: "Pre-flight cancellation"
            )
            return .cancelled(reason: "Pre-flight cancellation", cleanupStatus: .notRequired, attempt: attempt)
        }

        // Step 2: Cross-conversation authorization checks
        if let refConv = ref.conversationScope, refConv != requestingConversationID {
            let reason = "Source resource is scoped to conversation [\(refConv)], but requester is [\(requestingConversationID)]."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .denied,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .denied(reason: reason, attempt: attempt)
        }
        if requestingConversationID != targetConversationID {
            let reason = "Target conversation [\(targetConversationID)] differs from requesting conversation [\(requestingConversationID)]."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .denied,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .denied(reason: reason, attempt: attempt)
        }

        // A host identity is not an authorization claim. Validate the
        // invocation-scoped admission before any metadata-based fast path or
        // source-byte access.
        if ref.kind == .hostFile, hostFileAdmission?.admits(ref) != true {
            let reason = "Host source requires matching user-selection admission."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .denied,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .denied(reason: reason, attempt: attempt)
        }

        // An attachment identity is likewise not an authorization claim. The
        // invocation-scoped conversation attachment admission is validated
        // before any budget fast path or source-byte access.
        if ref.kind == .attachment, attachmentAdmission?.admits(ref) != true {
            let reason = "Attachment source requires a matching conversation attachment admission."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .denied,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .denied(reason: reason, attempt: attempt)
        }

        // File-size metadata is only an early resource bound. The exact
        // post-read check remains authoritative when resolution is required.
        if let maxInputBytes = requirement.budget.maxInputBytes,
           let estimatedByteCount = ref.representationHint?.estimatedByteCount,
           estimatedByteCount > maxInputBytes {
            let reason = "Source estimated size (\(estimatedByteCount) bytes) exceeds maxInputBytes budget (\(maxInputBytes) bytes) before byte resolution."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .overBudget,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .overBudget(reason: reason, attempt: attempt)
        }

        // Step 3: Direct resolution of source bytes
        let sourceContent: ResourceResolvedContent
        do {
            sourceContent = try ResourceResolver.resolveDirect(
                ref: ref,
                in: workspaceURL,
                artifactStore: artifactStore,
                requestingConversationID: requestingConversationID,
                hostFileAdmission: hostFileAdmission,
                attachmentStore: attachmentStore,
                attachmentAdmission: attachmentAdmission
            )
        } catch let error as ResourceResolutionError {
            switch error {
            case .missing(let r):
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .missing,
                    cleanupStatus: .notRequired,
                    failureReason: r
                )
                return .missing(reason: r, attempt: attempt)
            case .denied(let r):
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .denied,
                    cleanupStatus: .notRequired,
                    failureReason: r
                )
                return .denied(reason: r, attempt: attempt)
            case .expired(let r):
                let reason = "Source expired: \(r)"
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .missing,
                    cleanupStatus: .notRequired,
                    failureReason: reason
                )
                return .missing(reason: reason, attempt: attempt)
            case .unavailable(let r):
                let reason = "Source unavailable: \(r)"
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .failed,
                    cleanupStatus: .notRequired,
                    failureReason: reason
                )
                return .failed(reason: reason, cleanupStatus: .notRequired, attempt: attempt)
            case .unsupported(let r):
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .unsupported,
                    cleanupStatus: .notRequired,
                    failureReason: r
                )
                return .unsupported(reason: r, attempt: attempt)
            case .integrityMismatch(let exp, let act):
                let reason = "Source integrity mismatch: expected \(exp), got \(act)"
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .failed,
                    cleanupStatus: .notRequired,
                    failureReason: reason
                )
                return .failed(reason: reason, cleanupStatus: .notRequired, attempt: attempt)
            case .failed(let r):
                let attempt = RepresentationAttemptRecord(
                    attemptID: attemptID,
                    sourceRepresentation: initialSourceRep,
                    targetRequirement: requirement,
                    budgetLimits: requirement.budget,
                    terminalState: .failed,
                    cleanupStatus: .notRequired,
                    failureReason: r
                )
                return .failed(reason: r, cleanupStatus: .notRequired, attempt: attempt)
            }
        } catch {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: initialSourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: .notRequired,
                failureReason: error.localizedDescription
            )
            return .failed(reason: error.localizedDescription, cleanupStatus: .notRequired, attempt: attempt)
        }

        let sourceRep = sourceContent.representation

        // Step 4: Cancellation check after source resolve
        if Task.isCancelled {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .cancelled,
                cleanupStatus: .notRequired,
                failureReason: "Cancelled after resolving source"
            )
            return .cancelled(reason: "Cancelled after resolving source", cleanupStatus: .notRequired, attempt: attempt)
        }

        // Step 5: Check if source directly satisfies requirement (including epistemic level)
        if requirement.matches(descriptor: sourceRep) {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .satisfied,
                cleanupStatus: .notRequired
            )
            return .satisfied(content: sourceContent, attempt: attempt)
        }

        // Step 6: Input budget check
        if let maxIn = requirement.budget.maxInputBytes, Int64(sourceContent.data.count) > maxIn {
            let reason = "Source input size (\(sourceContent.data.count) bytes) exceeds maxInputBytes budget (\(maxIn) bytes)."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .overBudget,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .overBudget(reason: reason, attempt: attempt)
        }

        // Step 7: Deterministic single-hop route & converter selection
        struct Candidate {
            let converter: RepresentationConverter
            let route: ConversionRoute
        }

        var candidates: [Candidate] = []
        for converter in converters {
            let reportedRoutes: [ConversionRoute]
            do {
                reportedRoutes = try converter.applicableRoutes(source: sourceContent, requirement: requirement)
            } catch {
                let reason = "Converter applicability probe failed: \(error.localizedDescription)"
                let attempt = RepresentationAttemptRecord(attemptID: attemptID, sourceRepresentation: sourceRep, targetRequirement: requirement, budgetLimits: requirement.budget, terminalState: .failed, cleanupStatus: .notRequired, failureReason: reason)
                return .failed(reason: reason, cleanupStatus: .notRequired, attempt: attempt)
            }
            for route in reportedRoutes {
                guard converter.capability.supportedRoutes.contains(route) else {
                    let reason = "Converter reported an undeclared applicable route."
                    let attempt = RepresentationAttemptRecord(attemptID: attemptID, sourceRepresentation: sourceRep, targetRequirement: requirement, budgetLimits: requirement.budget, terminalState: .failed, cleanupStatus: .notRequired, failureReason: reason)
                    return .failed(reason: reason, cleanupStatus: .notRequired, attempt: attempt)
                }
                if route.sourceMIME.lowercased() == sourceRep.mimeType.lowercased() &&
                   requirement.acceptsFormat(mimeType: route.targetMIME) {
                    candidates.append(Candidate(converter: converter, route: route))
                }
            }
        }

        if candidates.isEmpty {
            let reason = "No registered converter supports route from '\(sourceRep.mimeType)' (epistemic: \(sourceRep.epistemicLevel.rawValue)) to requirement [\(requirement.acceptedMIMETypes.joined(separator: ", "))]."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                budgetLimits: requirement.budget,
                terminalState: .unsupported,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .unsupported(reason: reason, attempt: attempt)
        }

        // Sort candidates deterministically:
        // 1. route priority descending
        // 2. target MIME ascending
        // 3. converter capability ID ascending
        candidates.sort { a, b in
            if a.route.priority != b.route.priority {
                return a.route.priority > b.route.priority
            }
            if a.route.targetMIME != b.route.targetMIME {
                return a.route.targetMIME < b.route.targetMIME
            }
            return a.converter.capability.id < b.converter.capability.id
        }

        let selected = candidates[0]
        let selectedConverter = selected.converter
        let selectedRoute = selected.route

        // Converter capability maxInputBytes check
        if let convMaxIn = selectedConverter.capability.maxInputBytes, Int64(sourceContent.data.count) > convMaxIn {
            let reason = "Source input size (\(sourceContent.data.count) bytes) exceeds converter maxInputBytes (\(convMaxIn) bytes)."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .overBudget,
                cleanupStatus: .notRequired,
                failureReason: reason
            )
            return .overBudget(reason: reason, attempt: attempt)
        }

        // Step 8: Execution with cooperative cancellation & timeout support
        if Task.isCancelled {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .cancelled,
                cleanupStatus: .notRequired,
                failureReason: "Cancelled before converter execution"
            )
            return .cancelled(reason: "Cancelled before converter execution", cleanupStatus: .notRequired, attempt: attempt)
        }

        let conversionOutput: ConversionOutput
        do {
            if let timeout = requirement.budget.timeoutSeconds, timeout > 0 {
                conversionOutput = try await withThrowingTaskGroup(of: ConversionOutput.self) { group in
                    group.addTask {
                        try await selectedConverter.convert(
                            source: sourceContent,
                            route: selectedRoute,
                            budget: requirement.budget
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw CancellationError()
                    }
                    guard let result = try await group.next() else {
                        throw ResourceResolutionError.failed("No result from conversion task group")
                    }
                    group.cancelAll()
                    return result
                }
            } else {
                conversionOutput = try await selectedConverter.convert(
                    source: sourceContent,
                    route: selectedRoute,
                    budget: requirement.budget
                )
            }
        } catch is CancellationError {
            let cleanup: RepresentationCleanupStatus = .pending
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .cancelled,
                cleanupStatus: cleanup,
                failureReason: "Conversion task was cancelled or timed out"
            )
            return .cancelled(reason: "Conversion task was cancelled or timed out", cleanupStatus: cleanup, attempt: attempt)
        } catch let error as ConversionExecutionError {
            let cleanup = error.cleanupStatus
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: cleanup,
                failureReason: "Converter execution failed: \(error.reason)"
            )
            return .failed(reason: "Converter execution failed: \(error.reason)", cleanupStatus: cleanup, attempt: attempt)
        } catch {
            let cleanup: RepresentationCleanupStatus = .pending
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: cleanup,
                failureReason: "Converter execution failed: \(error.localizedDescription)"
            )
            return .failed(reason: "Converter execution failed: \(error.localizedDescription)", cleanupStatus: cleanup, attempt: attempt)
        }

        let cleanup = conversionOutput.cleanupStatus ?? .pending

        // Step 9: Post-execution cancellation check
        if Task.isCancelled {
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .cancelled,
                cleanupStatus: cleanup,
                failureReason: "Cancelled after converter execution"
            )
            return .cancelled(reason: "Cancelled after converter execution", cleanupStatus: cleanup, attempt: attempt)
        }

        // Step 10: Validate Output against Selected Route & Consumer Requirement
        if conversionOutput.mimeType.lowercased() != selectedRoute.targetMIME.lowercased() {
            let reason = "Converter output MIME '\(conversionOutput.mimeType)' violates selected route target '\(selectedRoute.targetMIME)'."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: cleanup,
                failureReason: reason
            )
            return .failed(reason: reason, cleanupStatus: cleanup, attempt: attempt)
        }

        if !requirement.matches(descriptor: conversionOutput.representation) {
            let reason = "Converter output representation [\(conversionOutput.mimeType), \(conversionOutput.epistemicLevel.rawValue)] does not satisfy consumer requirement."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: cleanup,
                failureReason: reason
            )
            return .failed(reason: reason, cleanupStatus: cleanup, attempt: attempt)
        }

        // Step 11: Output budget check
        if let maxOut = requirement.budget.maxOutputBytes, Int64(conversionOutput.data.count) > maxOut {
            let reason = "Conversion output size (\(conversionOutput.data.count) bytes) exceeds maxOutputBytes budget (\(maxOut) bytes)."
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .overBudget,
                cleanupStatus: cleanup,
                failureReason: reason
            )
            return .overBudget(reason: reason, attempt: attempt)
        }

        // Step 12: Explicit retention outcome. Route discovery, probing,
        // selection, execution and validation above are shared by both modes.
        let effectiveIntent = retentionIntent ?? .materialized(retentionClass: retentionClass)
        if case .directUse = effectiveIntent {
            let direct = DirectUseConversionResult(
                data: conversionOutput.data,
                representation: conversionOutput.representation,
                sourceRef: ref,
                converterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                attemptID: attemptID,
                cleanupStatus: cleanup,
                filename: conversionOutput.filename
            )
            let attempt = RepresentationAttemptRecord(attemptID: attemptID, sourceRepresentation: sourceRep, targetRequirement: requirement, selectedConverterID: selectedConverter.capability.id, selectedRoute: selectedRoute, budgetLimits: requirement.budget, terminalState: .converted, cleanupStatus: cleanup)
            return .directUse(direct, attempt: attempt)
        }

        guard let artifactStore else {
            let reason = "ArtifactStore is required for materialized conversion."
            let attempt = RepresentationAttemptRecord(attemptID: attemptID, sourceRepresentation: sourceRep, targetRequirement: requirement, selectedConverterID: selectedConverter.capability.id, selectedRoute: selectedRoute, budgetLimits: requirement.budget, terminalState: .failed, cleanupStatus: cleanup, failureReason: reason)
            return .failed(reason: reason, cleanupStatus: cleanup, attempt: attempt)
        }

        // Atomic commit to Artifact Authority with ConversionProvenance & Epistemic Truth
        let ext = (conversionOutput.filename as NSString?)?.pathExtension.isEmpty == false ? "" : ".converted"
        let filename = conversionOutput.filename ?? "converted_\(UUID().uuidString)\(ext)"

        let conversionProvenance = ConversionProvenance(
            parentResourceLocator: ref.id,
            converterID: selectedConverter.capability.id,
            selectedRoute: selectedRoute,
            attemptID: attemptID
        )

        let desc: ArtifactDescriptor
        do {
            desc = try artifactStore.save(
                data: conversionOutput.data,
                conversationID: targetConversationID,
                filename: filename,
                mimeType: conversionOutput.mimeType,
                representationEpistemicLevel: conversionOutput.epistemicLevel,
                representationProfile: conversionOutput.representation.establishedProfile,
                producerProvenance: .mediaExtraction,
                authorizationProvenance: authorizationProvenance,
                parentResourceLocator: ref.id,
                conversionRouteProvenance: selectedRoute.routeID,
                conversionProvenance: conversionProvenance,
                retentionClass: retentionClass
            )
        } catch {
            let reason = "Failed to commit converted artifact to store: \(error.localizedDescription)"
            let attempt = RepresentationAttemptRecord(
                attemptID: attemptID,
                sourceRepresentation: sourceRep,
                targetRequirement: requirement,
                selectedConverterID: selectedConverter.capability.id,
                selectedRoute: selectedRoute,
                budgetLimits: requirement.budget,
                terminalState: .failed,
                cleanupStatus: cleanup,
                failureReason: reason
            )
            return .failed(reason: reason, cleanupStatus: cleanup, attempt: attempt)
        }

        let artRef = ArtifactRef(artifactID: desc.artifactID, conversationID: desc.conversationID)
        let attempt = RepresentationAttemptRecord(
            attemptID: attemptID,
            sourceRepresentation: sourceRep,
            targetRequirement: requirement,
            selectedConverterID: selectedConverter.capability.id,
            selectedRoute: selectedRoute,
            budgetLimits: requirement.budget,
            terminalState: .converted,
            cleanupStatus: cleanup,
            derivedArtifactRef: artRef
        )

        return .converted(artifactRef: artRef, descriptor: desc, attempt: attempt)
    }

    public func resolveDirectUse(
        ref: ResourceRef,
        requirement: RepresentationRequirement,
        requestingConversationID: UUID,
        hostFileAdmission: HostFileAccessAdmission
    ) async -> RepresentationTerminalResult {
        await resolve(
            ref: ref,
            requirement: requirement,
            in: nil,
            artifactStore: nil,
            requestingConversationID: requestingConversationID,
            targetConversationID: requestingConversationID,
            hostFileAdmission: hostFileAdmission,
            retentionIntent: .directUse
        )
    }
}
