import Foundation

/// Pure, stateless evaluator assessing task completion based on mechanically verifiable evidence.
///
/// Invariants:
/// - OUT-I01: Run completion != Task outcome.
/// - OUT-I02: Evaluates only mechanically observable operations.
/// - OUT-I04: Receipt does not upgrade source terminal state or prove cognition/semantic correctness.
/// - OUT-I05: Re-validates canonical Artifact availability at assessment time; stale receipts do not guarantee availability.
/// - OUT-I06: Outcome is not a universal natural-language or semantic correctness judge.
struct OutcomeAssessor: Sendable {

    init() {}

    /// Evaluates the outcome of a task by correlating declared requirements with bounded mechanical evidence
    /// and current canonical storage truth.
    ///
    /// - Parameters:
    ///   - taskID: The unique identity of the task being evaluated.
    ///   - run: The associated conversation run, if available. Run status is read-only and never mutated.
    ///          If run is nil, no active run scope exists; cross-run receipts fail closed.
    ///   - requirements: Declared deterministic requirements for the task.
    ///   - deliverableBindings: Mappings connecting DeliverableRequirements to produced ArtifactRefs.
    ///   - receipts: Bounded evidence receipts recorded by runtime authorities.
    ///   - verificationResults: Bounded verification results recorded by verifier runtimes.
    ///   - artifactStore: Canonical Artifact Authority used to re-validate physical deliverable availability.
    ///   - resourceResolver: Optional resource resolver for validating external resources.
    /// - Returns: A structured `OutcomeAssessment` containing disposition, blockers, and requirement breakdowns.
    func assess(
        taskID: String,
        run: ConversationRun? = nil,
        requirements: [OutcomeRequirement],
        deliverableBindings: [DeliverableBinding] = [],
        receipts: [EvidenceReceipt] = [],
        verificationResults: [VerificationResult] = [],
        artifactStore: ArtifactStore? = nil,
        resourceResolver: ResourceResolver? = nil
    ) async -> OutcomeAssessment {
        var satisfiedRequirementIDs = Set<String>()
        var unsatisfiedRequirementIDs = Set<String>()
        var blockers: [OutcomeBlocker] = []
        var relevantReceipts: [EvidenceReceipt] = []
        var relevantVerificationResults: [VerificationResult] = []

        // 1. Evidence scoping & admission:
        // Fail closed for cross-task.
        // For cross-run: if run == nil, no active run scope exists to authorize reuse -> scopedReceipts = []
        // If run != nil, receipt.runID == run.id is strictly enforced.
        let scopedReceipts: [EvidenceReceipt]
        let scopedVerificationResults: [VerificationResult]
        if let run = run {
            scopedReceipts = receipts.filter { $0.taskID == taskID && $0.runID == run.id }
            scopedVerificationResults = verificationResults.filter { $0.correlation.runID == run.id }
        } else {
            scopedReceipts = []
            scopedVerificationResults = []
        }

        // 2. Evaluate each requirement deterministically
        for req in requirements {
            switch req {
            case .deliverable(let dReq):
                evaluateDeliverable(
                    requirement: dReq,
                    bindings: deliverableBindings,
                    scopedReceipts: scopedReceipts,
                    artifactStore: artifactStore,
                    satisfied: &satisfiedRequirementIDs,
                    unsatisfied: &unsatisfiedRequirementIDs,
                    blockers: &blockers,
                    relevant: &relevantReceipts
                )

            case .operation(let reqID, let op, let toolName, let providerID, let expectedResource):
                evaluateOperation(
                    requirementID: reqID,
                    operation: op,
                    toolName: toolName,
                    providerID: providerID,
                    expectedResource: expectedResource,
                    scopedReceipts: scopedReceipts,
                    satisfied: &satisfiedRequirementIDs,
                    unsatisfied: &unsatisfiedRequirementIDs,
                    blockers: &blockers,
                    relevant: &relevantReceipts
                )

            case .test(let reqID, let testID, let targetArtifactRef, let targetRevision):
                evaluateDeterministicTest(
                    requirementID: reqID,
                    testID: testID,
                    targetArtifactRef: targetArtifactRef,
                    targetRevision: targetRevision,
                    scopedReceipts: scopedReceipts,
                    satisfied: &satisfiedRequirementIDs,
                    unsatisfied: &unsatisfiedRequirementIDs,
                    blockers: &blockers,
                    relevant: &relevantReceipts
                )

            case .verification(let vReq):
                evaluateVerification(
                    requirement: vReq,
                    scopedReceipts: scopedReceipts,
                    scopedResults: scopedVerificationResults,
                    satisfied: &satisfiedRequirementIDs,
                    unsatisfied: &unsatisfiedRequirementIDs,
                    blockers: &blockers,
                    relevantReceipts: &relevantReceipts,
                    relevantResults: &relevantVerificationResults
                )
            }
        }

        // 3. Compute disposition
        let disposition: OutcomeDisposition
        if requirements.isEmpty {
            disposition = .complete
        } else {
            let blockingRequirements = requirements.filter { req in
                switch req {
                case .deliverable, .operation, .test:
                    return true
                case .verification(let vReq):
                    return vReq.blocking == .blocking
                }
            }
            let blockingIDs = Set(blockingRequirements.map(\.requirementID))
            let blockingBlockers = blockers.filter { blockingIDs.contains($0.requirementID) }

            if blockingBlockers.contains(where: { $0.category == .deterministicTestFailed || $0.category == .operationFailed }) {
                disposition = .failed
            } else if blockingBlockers.contains(where: { $0.category == .deliverableUnavailable || $0.category == .contradictoryEvidence || $0.category == .blockedPrerequisite }) {
                disposition = .blocked
            } else {
                let satisfiedBlockingIDs = satisfiedRequirementIDs.intersection(blockingIDs)
                if satisfiedBlockingIDs.count == blockingIDs.count && blockingBlockers.isEmpty {
                    disposition = .complete
                } else {
                    disposition = .incomplete
                }
            }
        }

        return OutcomeAssessment(
            taskID: taskID,
            runID: run?.id,
            disposition: disposition,
            requirements: requirements,
            satisfiedRequirementIDs: satisfiedRequirementIDs,
            unsatisfiedRequirementIDs: unsatisfiedRequirementIDs,
            blockers: blockers,
            relevantReceipts: relevantReceipts,
            verificationResults: relevantVerificationResults,
            assessedAt: Date()
        )
    }

    // MARK: - Deliverable Evaluation

    private func evaluateDeliverable(
        requirement dReq: DeliverableRequirement,
        bindings: [DeliverableBinding],
        scopedReceipts: [EvidenceReceipt],
        artifactStore: ArtifactStore?,
        satisfied: inout Set<String>,
        unsatisfied: inout Set<String>,
        blockers: inout [OutcomeBlocker],
        relevant: inout [EvidenceReceipt]
    ) {
        let matchingBindings = bindings.filter { $0.requirementID == dReq.requirementID }
        if matchingBindings.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .missingDeliverable,
                requirementID: dReq.requirementID,
                detail: "No deliverable binding found for required deliverable '\(dReq.name)'"
            ))
            unsatisfied.insert(dReq.requirementID)
            return
        }

        if matchingBindings.count > 1 {
            // Ambiguous bindings: multiple artifacts bound to same requirement slot
            blockers.append(OutcomeBlocker(
                category: .contradictoryEvidence,
                requirementID: dReq.requirementID,
                detail: "Ambiguous deliverable bindings: \(matchingBindings.count) artifacts bound to requirement '\(dReq.requirementID)'"
            ))
            unsatisfied.insert(dReq.requirementID)
            return
        }

        let binding = matchingBindings[0]

        // Validate expectedScope if declared
        if let expected = dReq.expectedScope {
            if binding.artifactRef.conversationID != expected {
                blockers.append(OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: dReq.requirementID,
                    detail: "Deliverable artifact conversation scope '\(binding.artifactRef.conversationID)' does not match expected scope '\(expected)'"
                ))
                unsatisfied.insert(dReq.requirementID)
                // Stop: do not probe or load bytes from unauthorized conversation scope
                return
            }
        }

        // Collect any receipts referencing this artifact
        let matchingReceipts = scopedReceipts.filter { $0.artifactRef == binding.artifactRef }
        relevant.append(contentsOf: matchingReceipts)

        // Dynamic canonical re-validation: Stale receipt is NEVER accepted as proof of current availability
        if dReq.requireReopenable {
            guard let store = artifactStore else {
                blockers.append(OutcomeBlocker(
                    category: .unknownCanonicalState,
                    requirementID: dReq.requirementID,
                    detail: "ArtifactStore unavailable to verify deliverable reopenability"
                ))
                unsatisfied.insert(dReq.requirementID)
                return
            }

            do {
                _ = try store.loadData(
                    artifactID: binding.artifactRef.artifactID,
                    conversationID: binding.artifactRef.conversationID,
                    verifyIntegrity: true
                )
                satisfied.insert(dReq.requirementID)
            } catch {
                blockers.append(OutcomeBlocker(
                    category: .deliverableUnavailable,
                    requirementID: dReq.requirementID,
                    detail: "Deliverable artifact '\(binding.artifactRef.artifactID)' cannot be reopened from canonical ArtifactStore: \(error.localizedDescription)",
                    underlyingFailureReason: String(describing: error)
                ))
                unsatisfied.insert(dReq.requirementID)
            }
        } else {
            satisfied.insert(dReq.requirementID)
        }
    }

    // MARK: - Mechanical Operation Evaluation

    private func evaluateOperation(
        requirementID: String,
        operation: EvidenceOperation,
        toolName: String?,
        providerID: String?,
        expectedResource: ResourceRef?,
        scopedReceipts: [EvidenceReceipt],
        satisfied: inout Set<String>,
        unsatisfied: inout Set<String>,
        blockers: inout [OutcomeBlocker],
        relevant: inout [EvidenceReceipt]
    ) {
        // Defense against verifiedByTest side-door: verifiedByTest cannot be declared or satisfied via generic operation
        if operation == .verifiedByTest {
            blockers.append(OutcomeBlocker(
                category: .evidenceIdentityMismatch,
                requirementID: requirementID,
                detail: "Deterministic test verification cannot be declared via generic operation requirement; exact test identity must be declared via OutcomeRequirement.test"
            ))
            unsatisfied.insert(requirementID)
            return
        }

        let matching = scopedReceipts.filter { receipt in
            guard receipt.operation == operation else { return false }

            if let tool = toolName {
                guard case .toolExecuted(let tName, _, _) = receipt.observation, tName == tool else {
                    return false
                }
            }

            if let provider = providerID {
                switch receipt.observation {
                case .providerResponded(let pID, _, _):
                    guard pID == provider else { return false }
                case .providerProjected(let pID, _):
                    guard pID == provider else { return false }
                default:
                    return false
                }
            }

            if let expRes = expectedResource {
                guard receipt.resourceRef == expRes else { return false }
            }

            return true
        }

        if matching.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .missingEvidence,
                requirementID: requirementID,
                detail: "Missing required evidence for operation '\(operation.rawValue)'"
            ))
            unsatisfied.insert(requirementID)
            return
        }

        relevant.append(contentsOf: matching)

        let passes = matching.filter { $0.observation.isMechanicalSuccess }
        let fails = matching.filter { !$0.observation.isMechanicalSuccess }

        if !passes.isEmpty && !fails.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .contradictoryEvidence,
                requirementID: requirementID,
                detail: "Contradictory evidence recorded for operation '\(operation.rawValue)'"
            ))
            unsatisfied.insert(requirementID)
        } else if !fails.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .operationFailed,
                requirementID: requirementID,
                detail: "Operation '\(operation.rawValue)' completed with explicit mechanical failure"
            ))
            unsatisfied.insert(requirementID)
        } else {
            satisfied.insert(requirementID)
        }
    }

    // MARK: - Deterministic Test Evaluation

    private func evaluateDeterministicTest(
        requirementID: String,
        testID: String,
        targetArtifactRef: ArtifactRef?,
        targetRevision: String?,
        scopedReceipts: [EvidenceReceipt],
        satisfied: inout Set<String>,
        unsatisfied: inout Set<String>,
        blockers: inout [OutcomeBlocker],
        relevant: inout [EvidenceReceipt]
    ) {
        let candidatesWithTestID = scopedReceipts.filter { receipt in
            guard receipt.operation == .verifiedByTest else { return false }
            guard case .deterministicTest(let tID, _, _, _, _, _) = receipt.observation else {
                return false
            }
            return tID == testID
        }

        let testReceipts = candidatesWithTestID.filter { receipt in
            guard case .deterministicTest(_, let artID, let revID, _, _, _) = receipt.observation else {
                return false
            }

            // Exact artifact reference & identity
            if let expectedArt = targetArtifactRef {
                guard receipt.artifactRef == expectedArt, artID == expectedArt.artifactID else {
                    return false
                }
            }

            // Exact revision identity
            if let expectedRev = targetRevision {
                guard revID == expectedRev else { return false }
            }

            return true
        }

        if testReceipts.isEmpty {
            if !candidatesWithTestID.isEmpty {
                blockers.append(OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Test '\(testID)' evidence exists but targets mismatched artifact or revision"
                ))
            } else {
                blockers.append(OutcomeBlocker(
                    category: .missingEvidence,
                    requirementID: requirementID,
                    detail: "Missing test evidence for test '\(testID)'"
                ))
            }
            unsatisfied.insert(requirementID)
            return
        }

        relevant.append(contentsOf: testReceipts)

        let passes = testReceipts.filter { $0.observation.isMechanicalSuccess }
        let fails = testReceipts.filter { !$0.observation.isMechanicalSuccess }

        if !passes.isEmpty && !fails.isEmpty {
            // Contradictory evidence: PASS + FAIL for identical test identity
            blockers.append(OutcomeBlocker(
                category: .contradictoryEvidence,
                requirementID: requirementID,
                detail: "Deterministic test '\(testID)' has contradictory PASS and FAIL evidence receipts"
            ))
            unsatisfied.insert(requirementID)
        } else if !fails.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .deterministicTestFailed,
                requirementID: requirementID,
                detail: "Deterministic test '\(testID)' recorded mechanical failure"
            ))
            unsatisfied.insert(requirementID)
        } else {
            satisfied.insert(requirementID)
        }
    }

    // MARK: - Result Shape Validation (§4)

    /// Validates that a verification result conforms to the requirement shape and integrity rules (§4).
    public static func validate(
        requirement: VerificationRequirement,
        result: VerificationResult
    ) -> OutcomeBlocker? {
        requirement.validateResultShape(result)
    }

    // MARK: - GUI Verification Evaluation (Contract 33 / CUGV-G10)

    private func evaluateVerification(
        requirement vReq: VerificationRequirement,
        scopedReceipts: [EvidenceReceipt],
        scopedResults: [VerificationResult],
        satisfied: inout Set<String>,
        unsatisfied: inout Set<String>,
        blockers: inout [OutcomeBlocker],
        relevantReceipts: inout [EvidenceReceipt],
        relevantResults: inout [VerificationResult]
    ) {
        let reqID = vReq.requirementID
        let candidates = scopedResults.filter { $0.requirementID == reqID }

        guard !candidates.isEmpty else {
            unsatisfied.insert(reqID)
            return
        }

        // Concrete verifier correlation (§5.3b, AC-A12, AC-A13, AC-A14):
        let matchingResults: [VerificationResult]
        if vReq.factClass == .deterministic || vReq.factClass == .boundedVisual {
            guard let expectedIdentity = vReq.concreteVerifierIdentity, !expectedIdentity.isEmpty else {
                unsatisfied.insert(reqID)
                blockers.append(OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: reqID,
                    detail: "Mechanical verification requirement '\(reqID)' missing required concreteVerifierIdentity"
                ))
                return
            }

            matchingResults = candidates.filter { $0.verifierIdentity == expectedIdentity }
            if matchingResults.isEmpty {
                unsatisfied.insert(reqID)
                blockers.append(OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: reqID,
                    detail: "Verification result verifierIdentity does not match declared concreteVerifierIdentity '\(expectedIdentity)'"
                ))
                return
            }
        } else {
            if let expectedIdentity = vReq.concreteVerifierIdentity, !expectedIdentity.isEmpty {
                matchingResults = candidates.filter { $0.verifierIdentity == expectedIdentity }
                if matchingResults.isEmpty {
                    unsatisfied.insert(reqID)
                    blockers.append(OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: reqID,
                        detail: "Semantic verification result verifierIdentity does not match declared identity '\(expectedIdentity)'"
                    ))
                    return
                }
            } else {
                matchingResults = candidates
            }
        }

        // Validate result shape and semantic/mechanical integrity (§4, ADV-06..ADV-10)
        for res in matchingResults {
            if let blocker = vReq.validateResultShape(res) {
                relevantResults.append(res)
                blockers.append(blocker)
                unsatisfied.insert(reqID)
                return
            }
        }

        relevantResults.append(contentsOf: matchingResults)

        // Correlate with any referenced receipts and check contradiction
        for res in matchingResults {
            let refs = Set(res.evidenceReferences.receiptIDs)
            if !refs.isEmpty {
                let matchingReceipts = scopedReceipts.filter { refs.contains($0.id) }
                relevantReceipts.append(contentsOf: matchingReceipts)

                if res.resultState == .passed && matchingReceipts.contains(where: { !$0.observation.isMechanicalSuccess }) {
                    blockers.append(OutcomeBlocker(
                        category: .contradictoryEvidence,
                        requirementID: reqID,
                        detail: "VerificationResult claimed passed but referenced EvidenceReceipt indicates mechanical failure"
                    ))
                    unsatisfied.insert(reqID)
                    return
                }
                if res.resultState == .failed && matchingReceipts.contains(where: { $0.observation.isMechanicalSuccess }) {
                    blockers.append(OutcomeBlocker(
                        category: .contradictoryEvidence,
                        requirementID: reqID,
                        detail: "VerificationResult claimed failed but referenced EvidenceReceipt indicates mechanical success"
                    ))
                    unsatisfied.insert(reqID)
                    return
                }
            }
        }

        // Check for contradictory result states (PASS + FAIL) among matching results
        let passedResults = matchingResults.filter { $0.resultState == .passed }
        let failedResults = matchingResults.filter { $0.resultState == .failed }
        let findingResults = matchingResults.filter { $0.resultState == .advisoryFinding }

        if !passedResults.isEmpty && !failedResults.isEmpty {
            blockers.append(OutcomeBlocker(
                category: .contradictoryEvidence,
                requirementID: reqID,
                detail: "Contradictory verification results (passed and failed) recorded for requirement '\(reqID)'"
            ))
            unsatisfied.insert(reqID)
            return
        }

        // Evaluate terminal state:
        // Valid mechanical pass
        if !passedResults.isEmpty {
            satisfied.insert(reqID)
            return
        }

        // Non-passing result: requirement is not satisfied
        unsatisfied.insert(reqID)

        if !failedResults.isEmpty {
            if vReq.blocking == .blocking {
                blockers.append(OutcomeBlocker(
                    category: .deterministicTestFailed,
                    requirementID: reqID,
                    detail: "Mechanical verification '\(vReq.concreteVerifierIdentity ?? reqID)' recorded failure"
                ))
            }
            return
        }

        if !findingResults.isEmpty {
            // Finding remains advisoryFinding; does NOT become mechanical failed.
            // Task consequence is derived in disposition ladder.
            return
        }

        if matchingResults.contains(where: { $0.resultState == .blocked }) && vReq.blocking == .blocking {
            blockers.append(OutcomeBlocker(
                category: .blockedPrerequisite,
                requirementID: reqID,
                detail: "Verification blocked by prerequisite condition"
            ))
        }
    }
}
