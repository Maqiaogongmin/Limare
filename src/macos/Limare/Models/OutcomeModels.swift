import Foundation

// MARK: - Evidence Operations (Frozen Contract 06 / OUT-I03)

/// Mechanically observable operations allowed in EvidenceReceipts.
/// Cognition / perception / semantic evaluation vocabulary is strictly prohibited.
public enum EvidenceOperation: String, Codable, Sendable, Equatable, Hashable {
    case materialized
    case providerProjected
    case requestDispatched
    case providerResponded
    case specialistProcessed
    case toolExecuted
    case reopened
    case verifiedByTest
}

// MARK: - Mechanical Observation Truth

/// Bounded mechanical observation referencing a canonical source fact.
/// Each observation case strictly defines its unique, non-contradictory EvidenceOperation
/// and single-source causal identities (callID, requestID).
/// Arbitrary or semantic observation cases (e.g. custom) are strictly prohibited.
public enum MechanicalObservation: Codable, Sendable, Equatable {
    case materialized(artifactID: UUID, success: Bool)
    case providerProjected(providerID: String, requestID: String)
    case requestDispatched(requestID: String)
    case providerResponded(providerID: String, requestID: String?, responseID: String?)
    case specialistProcessed(specialistID: String, success: Bool)
    case toolExecuted(toolName: String, callID: String, success: Bool)
    case reopened(artifactID: UUID, success: Bool)
    case deterministicTest(testID: String, targetArtifactID: UUID?, targetRevisionID: String?, passed: Bool, exitCode: Int32?, detail: String?)

    /// Single canonical mapping from observation to operation.
    /// Eliminates any possibility of contradictory operation vs observation truth.
    public var operation: EvidenceOperation {
        switch self {
        case .materialized: return .materialized
        case .providerProjected: return .providerProjected
        case .requestDispatched: return .requestDispatched
        case .providerResponded: return .providerResponded
        case .specialistProcessed: return .specialistProcessed
        case .toolExecuted: return .toolExecuted
        case .reopened: return .reopened
        case .deterministicTest: return .verifiedByTest
        }
    }

    /// Single canonical mapping for call causality.
    public var callID: String? {
        switch self {
        case .toolExecuted(_, let cID, _):
            return cID
        default:
            return nil
        }
    }

    /// Single canonical mapping for request causality.
    public var requestID: String? {
        switch self {
        case .requestDispatched(let rID):
            return rID
        case .providerProjected(_, let rID):
            return rID
        case .providerResponded(_, let rID, _):
            return rID
        default:
            return nil
        }
    }

    public var isMechanicalSuccess: Bool {
        switch self {
        case .materialized(_, let success): return success
        case .providerProjected: return true
        case .requestDispatched: return true
        case .providerResponded: return true
        case .specialistProcessed(_, let success): return success
        case .toolExecuted(_, _, let success): return success
        case .reopened(_, let success): return success
        case .deterministicTest(_, _, _, let passed, _, _): return passed
        }
    }
}

// MARK: - EvidenceReceipt (Contract 06: Bounded Mechanical Evidence)

/// Immutable reference to a mechanical fact owned by another canonical authority.
/// A receipt does not upgrade source truth and never claims cognition or understanding.
/// Its `operation`, `callID`, and `requestID` are strictly derived from its `observation`, enforcing single truth.
public struct EvidenceReceipt: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let taskID: String
    public let runID: UUID
    public let turnID: String?
    /// Canonical causal tool-call identity for observations whose frozen case does not itself
    /// carry one (for example `deterministicTest`). It is never a turn identity and never a second
    /// competing call identity: when `observation.callID` already exists this is normalized to nil.
    public let sourceCallID: String?
    public let resourceRef: ResourceRef?
    public let artifactRef: ArtifactRef?
    public let observation: MechanicalObservation

    /// Informational source-owner attribution label.
    /// Note: R2.3 records source-owner attribution but does not independently authenticate the producer;
    /// actual automatic producer wiring is deferred. This label is not used as an admission grant.
    public let reportedCanonicalOwnerDomain: String
    public let timestamp: Date

    /// Derived operation truth from observation. Cannot contradict observation.
    public var operation: EvidenceOperation {
        observation.operation
    }

    /// Single canonical causal call identity. The observation-derived identity is authoritative;
    /// `sourceCallID` only supplies causality the frozen observation case cannot express.
    public var callID: String? {
        observation.callID ?? sourceCallID
    }

    /// Derived request identity from observation. Single source of causal truth.
    public var requestID: String? {
        observation.requestID
    }

    /// Compatibility accessor for informational source-owner attribution label.
    public var canonicalOwnerDomain: String {
        reportedCanonicalOwnerDomain
    }

    public init(
        id: UUID = UUID(),
        taskID: String,
        runID: UUID,
        turnID: String? = nil,
        sourceCallID: String? = nil,
        resourceRef: ResourceRef? = nil,
        artifactRef: ArtifactRef? = nil,
        observation: MechanicalObservation,
        reportedCanonicalOwnerDomain: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.turnID = turnID
        self.sourceCallID = Self.normalizedSourceCallID(sourceCallID, observation: observation)
        self.resourceRef = resourceRef
        self.artifactRef = artifactRef
        self.observation = observation
        self.reportedCanonicalOwnerDomain = reportedCanonicalOwnerDomain
        self.timestamp = timestamp
    }

    public init(
        id: UUID = UUID(),
        taskID: String,
        runID: UUID,
        turnID: String? = nil,
        sourceCallID: String? = nil,
        resourceRef: ResourceRef? = nil,
        artifactRef: ArtifactRef? = nil,
        observation: MechanicalObservation,
        canonicalOwnerDomain: String,
        timestamp: Date = Date()
    ) {
        self.init(
            id: id,
            taskID: taskID,
            runID: runID,
            turnID: turnID,
            sourceCallID: sourceCallID,
            resourceRef: resourceRef,
            artifactRef: artifactRef,
            observation: observation,
            reportedCanonicalOwnerDomain: canonicalOwnerDomain,
            timestamp: timestamp
        )
    }

    /// A receipt must never expose two competing call identities. When the observation already
    /// carries the authoritative identity, an explicitly supplied value is either a redundant
    /// repeat (dropped, it adds no information) or a contradiction (not representable).
    private static func normalizedSourceCallID(_ sourceCallID: String?, observation: MechanicalObservation) -> String? {
        guard observation.callID == nil else { return nil }
        return sourceCallID
    }
}

// MARK: - Deliverable Slot & Binding Semantics

/// Declared requirement for a deliverable whose concrete artifact identity is bound upon production.
public struct DeliverableRequirement: Codable, Sendable, Equatable {
    public let requirementID: String
    public let name: String
    public let description: String?
    public let expectedScope: UUID?
    public let requireReopenable: Bool

    public init(
        requirementID: String,
        name: String,
        description: String? = nil,
        expectedScope: UUID? = nil,
        requireReopenable: Bool = true
    ) {
        self.requirementID = requirementID
        self.name = name
        self.description = description
        self.expectedScope = expectedScope
        self.requireReopenable = requireReopenable
    }
}

/// Binding connecting a DeliverableRequirement to a produced ArtifactRef.
public struct DeliverableBinding: Codable, Sendable, Equatable {
    public let requirementID: String
    public let artifactRef: ArtifactRef

    public init(requirementID: String, artifactRef: ArtifactRef) {
        self.requirementID = requirementID
        self.artifactRef = artifactRef
    }
}

// MARK: - GUI Verification Requirements (Contract 33 / CUGV-G10)

/// Fact classification for GUI verification requirements.
public enum VerificationFactClass: String, Codable, Sendable, Equatable {
    case deterministic
    case boundedVisual
    case semantic
}

/// Permitted verifier kinds for GUI verification requirements.
public enum VerificationVerifierKind: String, Codable, Sendable, Equatable {
    case deterministic
    case boundedVisual
    case semantic
}

/// Declared blocking semantics for GUI verification requirements.
public enum VerificationBlockingSemantics: String, Codable, Sendable, Equatable {
    case blocking
    case advisory
}

/// Computer Use dependency declaration for GUI verification requirements.
public enum ComputerUseDependency: String, Codable, Sendable, Equatable {
    case none
    case required
}

/// Declared verification requirement carrying fact, condition, class, preferred verifier,
/// concrete verifier identity (when mechanical), evidence requirement, blocking policy, and CU dependency.
public struct VerificationRequirement: Codable, Sendable, Equatable {
    public let requirementID: String
    public let fact: String
    public let expectedCondition: String
    public let factClass: VerificationFactClass
    public let preferredVerifier: VerificationVerifierKind
    public let concreteVerifierIdentity: String?
    public let evidenceRequirement: String
    public let blocking: VerificationBlockingSemantics
    public let computerUseDependency: ComputerUseDependency

    public init(
        requirementID: String,
        fact: String,
        expectedCondition: String,
        factClass: VerificationFactClass,
        preferredVerifier: VerificationVerifierKind,
        concreteVerifierIdentity: String? = nil,
        evidenceRequirement: String,
        blocking: VerificationBlockingSemantics = .blocking,
        computerUseDependency: ComputerUseDependency = .none
    ) {
        self.requirementID = requirementID
        self.fact = fact
        self.expectedCondition = expectedCondition
        self.factClass = factClass
        self.preferredVerifier = preferredVerifier
        self.concreteVerifierIdentity = concreteVerifierIdentity
        self.evidenceRequirement = evidenceRequirement
        self.blocking = blocking
        self.computerUseDependency = computerUseDependency
    }
}

// MARK: - Outcome Requirements

/// Typed requirements declared for a task.
public enum OutcomeRequirement: Codable, Sendable, Equatable {
    case deliverable(DeliverableRequirement)
    case operation(
        requirementID: String,
        operation: EvidenceOperation,
        toolName: String?,
        providerID: String?,
        expectedResource: ResourceRef?
    )
    case test(
        requirementID: String,
        testID: String,
        targetArtifactRef: ArtifactRef?,
        targetRevision: String?
    )
    case verification(VerificationRequirement)

    public var requirementID: String {
        switch self {
        case .deliverable(let req): return req.requirementID
        case .operation(let reqID, _, _, _, _): return reqID
        case .test(let reqID, _, _, _): return reqID
        case .verification(let req): return req.requirementID
        }
    }

    public static func verification(
        requirementID: String,
        fact: String,
        expectedCondition: String,
        factClass: VerificationFactClass,
        preferredVerifier: VerificationVerifierKind,
        concreteVerifierIdentity: String? = nil,
        evidenceRequirement: String,
        blocking: VerificationBlockingSemantics = .blocking,
        computerUseDependency: ComputerUseDependency = .none
    ) -> OutcomeRequirement {
        .verification(VerificationRequirement(
            requirementID: requirementID,
            fact: fact,
            expectedCondition: expectedCondition,
            factClass: factClass,
            preferredVerifier: preferredVerifier,
            concreteVerifierIdentity: concreteVerifierIdentity,
            evidenceRequirement: evidenceRequirement,
            blocking: blocking,
            computerUseDependency: computerUseDependency
        ))
    }
}

/// Exact, pre-declared mechanical invocation permitted to witness one test requirement.
public struct DeterministicTestWitness: Codable, Sendable, Equatable {
    public let requirementID: String
    public let testID: String
    public let toolName: String
    public let exactCommand: String

    public init(requirementID: String, testID: String, toolName: String, exactCommand: String) {
        self.requirementID = requirementID
        self.testID = testID
        self.toolName = toolName
        self.exactCommand = exactCommand
    }
}

public enum OutcomeDeclarationError: Error, Sendable, Equatable {
    case emptyTaskID
    case duplicateRequirementID(String)
    case invalidWitness(String)
    case duplicateWitness(String)
    case missingConcreteVerifierIdentity(String)
}

/// Immutable caller-owned opt-in declaration for one ConversationRun.
public struct OutcomeRunDeclaration: Sendable, Equatable {
    public let taskID: String
    public let requirements: [OutcomeRequirement]
    public let deterministicTestWitnesses: [DeterministicTestWitness]

    public init(taskID: String, requirements: [OutcomeRequirement], deterministicTestWitnesses: [DeterministicTestWitness] = []) throws {
        guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OutcomeDeclarationError.emptyTaskID }
        var requirementIDs = Set<String>()
        for requirement in requirements where !requirementIDs.insert(requirement.requirementID).inserted {
            throw OutcomeDeclarationError.duplicateRequirementID(requirement.requirementID)
        }
        for requirement in requirements {
            if case .verification(let vReq) = requirement {
                if (vReq.factClass == .deterministic || vReq.factClass == .boundedVisual) && (vReq.concreteVerifierIdentity?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                    throw OutcomeDeclarationError.missingConcreteVerifierIdentity(vReq.requirementID)
                }
            }
        }
        var witnessRequirements = Set<String>()
        for witness in deterministicTestWitnesses {
            guard case .test(_, let testID, _, _)? = requirements.first(where: { $0.requirementID == witness.requirementID }),
                  testID == witness.testID,
                  witness.toolName == "shell_execute",
                  !witness.exactCommand.isEmpty else { throw OutcomeDeclarationError.invalidWitness(witness.requirementID) }
            guard witnessRequirements.insert(witness.requirementID).inserted else { throw OutcomeDeclarationError.duplicateWitness(witness.requirementID) }
        }
        self.taskID = taskID
        self.requirements = requirements
        self.deterministicTestWitnesses = deterministicTestWitnesses
    }
}

// MARK: - Outcome Disposition & Blockers

/// Task-level outcome disposition. Never conflated with Run status.
public enum OutcomeDisposition: String, Codable, Sendable, Equatable {
    case complete
    case incomplete
    case blocked
    case failed
}

/// Specific, typed blocker reason categories.
public enum OutcomeBlockerCategory: String, Codable, Sendable, Equatable {
    case missingDeliverable
    case deliverableUnavailable
    case missingEvidence
    case evidenceIdentityMismatch
    case deterministicTestFailed
    case operationFailed
    case blockedPrerequisite
    case unknownCanonicalState
    case contradictoryEvidence
}

/// A structured blocker preventing task completion.
public struct OutcomeBlocker: Codable, Sendable, Equatable {
    public let category: OutcomeBlockerCategory
    public let requirementID: String
    public let detail: String
    public let underlyingFailureReason: String?

    public init(
        category: OutcomeBlockerCategory,
        requirementID: String,
        detail: String,
        underlyingFailureReason: String? = nil
    ) {
        self.category = category
        self.requirementID = requirementID
        self.detail = detail
        self.underlyingFailureReason = underlyingFailureReason
    }
}

// MARK: - Verification Results & Findings (Contract 33 / CUGV-G10)

/// Epistemic result states for verification evaluations.
/// Preserves strict distinctions: unsupported != notRun != indeterminate != blocked != failed != advisoryFinding.
public enum VerificationResultState: String, Codable, Sendable, Equatable {
    case passed
    case failed
    case unsupported
    case notApplicable
    case notRun
    case blocked
    case indeterminate
    case advisoryFinding
}

/// Typed evidence references attached to a VerificationResult.
/// Contains references to canonical artifacts, resources, and receipts; never embeds raw bytes.
public struct VerificationEvidenceReferences: Codable, Sendable, Equatable {
    public let artifactRefs: [ArtifactRef]
    public let resourceRefs: [ResourceRef]
    public let receiptIDs: [UUID]

    public init(
        artifactRefs: [ArtifactRef] = [],
        resourceRefs: [ResourceRef] = [],
        receiptIDs: [UUID] = []
    ) {
        self.artifactRefs = artifactRefs
        self.resourceRefs = resourceRefs
        self.receiptIDs = receiptIDs
    }
}

/// Causal and run correlation for a VerificationResult.
public struct VerificationCorrelation: Codable, Sendable, Equatable {
    public let runID: UUID
    public let verificationRunID: String?
    public let turnID: String?
    public let callID: String?

    public init(
        runID: UUID,
        verificationRunID: String? = nil,
        turnID: String? = nil,
        callID: String? = nil
    ) {
        self.runID = runID
        self.verificationRunID = verificationRunID
        self.turnID = turnID
        self.callID = callID
    }
}

/// Class-C semantic finding payload.
/// Answers: who reported it, against which artifact, what was reported, and which requirement governs consequence.
/// Does NOT duplicate mutable blocking policy; governing requirement declaration is single source of truth.
public struct FindingPayload: Codable, Sendable, Equatable {
    public let evaluatorID: String
    public let artifactRef: ArtifactRef
    public let text: String
    public let governingRequirementID: String

    public init(
        evaluatorID: String,
        artifactRef: ArtifactRef,
        text: String,
        governingRequirementID: String
    ) {
        self.evaluatorID = evaluatorID
        self.artifactRef = artifactRef
        self.text = text
        self.governingRequirementID = governingRequirementID
    }
}

/// Outcome/Handoff-owned durable verification result representation.
public struct VerificationResult: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let requirementID: String
    public let verifierIdentity: String
    public let resultState: VerificationResultState
    public let evidenceReferences: VerificationEvidenceReferences
    public let correlation: VerificationCorrelation
    public let findingPayload: FindingPayload?
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        requirementID: String,
        verifierIdentity: String,
        resultState: VerificationResultState,
        evidenceReferences: VerificationEvidenceReferences = .init(),
        correlation: VerificationCorrelation,
        findingPayload: FindingPayload? = nil,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.requirementID = requirementID
        self.verifierIdentity = verifierIdentity
        self.resultState = resultState
        self.evidenceReferences = evidenceReferences
        self.correlation = correlation
        self.findingPayload = findingPayload
        self.recordedAt = recordedAt
    }
}

// MARK: - Verification Result Shape Validation (§4)

extension VerificationRequirement {
    /// Validates that a verification result conforms to this requirement's shape and integrity rules (§4).
    /// Returns an OutcomeBlocker describing any shape/identity/fact-class mismatch, or nil if valid.
    public func validateResultShape(_ result: VerificationResult) -> OutcomeBlocker? {
        // 1. Requirement identity match
        guard result.requirementID == requirementID else {
            return OutcomeBlocker(
                category: .evidenceIdentityMismatch,
                requirementID: requirementID,
                detail: "Verification result requirementID '\(result.requirementID)' does not match declared requirementID '\(requirementID)'"
            )
        }

        // 2. Verifier identity match & fact-class constraints
        switch factClass {
        case .deterministic, .boundedVisual:
            guard let expectedIdentity = concreteVerifierIdentity, !expectedIdentity.isEmpty else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Mechanical verification requirement '\(requirementID)' missing required concreteVerifierIdentity"
                )
            }
            guard result.verifierIdentity == expectedIdentity else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Mechanical verification result verifierIdentity '\(result.verifierIdentity)' does not match declared concreteVerifierIdentity '\(expectedIdentity)'"
                )
            }
            // Mechanical requirement MUST NOT have advisoryFinding or findingPayload (§3)
            guard result.resultState != .advisoryFinding else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Mechanical verification requirement cannot accept advisoryFinding result state"
                )
            }
            guard result.findingPayload == nil else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Mechanical verification result cannot carry FindingPayload (class-C only)"
                )
            }

        case .semantic:
            if let expectedIdentity = concreteVerifierIdentity, !expectedIdentity.isEmpty {
                guard result.verifierIdentity == expectedIdentity else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "Semantic verification result verifierIdentity '\(result.verifierIdentity)' does not match declared concreteVerifierIdentity '\(expectedIdentity)'"
                    )
                }
            }

            // Semantic evaluator MUST NOT produce mechanical passed (§1, GV-I13, AC-A7)
            guard result.resultState != .passed else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Semantic evaluator cannot claim passed (GV-I13)"
                )
            }

            // Semantic evaluator MUST NOT produce mechanical failed (§1, Contract 33 §11.2, Plan §5.5)
            guard result.resultState != .failed else {
                return OutcomeBlocker(
                    category: .evidenceIdentityMismatch,
                    requirementID: requirementID,
                    detail: "Semantic evaluator cannot emit mechanical failed verdict; semantic findings must use advisoryFinding"
                )
            }

            // Semantic advisoryFinding MUST have valid FindingPayload (§2)
            if result.resultState == .advisoryFinding {
                guard let payload = result.findingPayload else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "Verification result with advisoryFinding state must carry a non-nil FindingPayload"
                    )
                }
                guard payload.governingRequirementID == requirementID else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "FindingPayload governingRequirementID '\(payload.governingRequirementID)' does not match requirementID '\(requirementID)'"
                    )
                }
                guard payload.governingRequirementID == result.requirementID else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "FindingPayload governingRequirementID '\(payload.governingRequirementID)' does not match result requirementID '\(result.requirementID)'"
                    )
                }
                guard payload.evaluatorID == result.verifierIdentity else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "FindingPayload evaluatorID '\(payload.evaluatorID)' does not match result verifierIdentity '\(result.verifierIdentity)'"
                    )
                }
                if let expectedIdentity = concreteVerifierIdentity, !expectedIdentity.isEmpty {
                    guard payload.evaluatorID == expectedIdentity else {
                        return OutcomeBlocker(
                            category: .evidenceIdentityMismatch,
                            requirementID: requirementID,
                            detail: "FindingPayload evaluatorID '\(payload.evaluatorID)' does not match declared concreteVerifierIdentity '\(expectedIdentity)'"
                        )
                    }
                }
            } else {
                // Non-finding semantic result states MUST NOT carry findingPayload (§3)
                guard result.findingPayload == nil else {
                    return OutcomeBlocker(
                        category: .evidenceIdentityMismatch,
                        requirementID: requirementID,
                        detail: "Non-finding semantic result state '\(result.resultState.rawValue)' cannot carry FindingPayload"
                    )
                }
            }
        }

        return nil
    }
}

// MARK: - Outcome Assessment

/// The assessed outcome of a task.
/// Explicitly contains requirements, satisfied/unsatisfied IDs, blockers, receipts, and verification results.
/// Never contains fuzzy scores, confidence ratings, or synthetic success booleans.
public struct OutcomeAssessment: Codable, Sendable, Equatable {
    public let taskID: String
    public let runID: UUID?
    public let disposition: OutcomeDisposition
    public let requirements: [OutcomeRequirement]
    public let satisfiedRequirementIDs: Set<String>
    public let unsatisfiedRequirementIDs: Set<String>
    public let blockers: [OutcomeBlocker]
    public let relevantReceipts: [EvidenceReceipt]
    public let verificationResults: [VerificationResult]
    public let assessedAt: Date

    public init(
        taskID: String,
        runID: UUID?,
        disposition: OutcomeDisposition,
        requirements: [OutcomeRequirement],
        satisfiedRequirementIDs: Set<String>,
        unsatisfiedRequirementIDs: Set<String>,
        blockers: [OutcomeBlocker],
        relevantReceipts: [EvidenceReceipt],
        verificationResults: [VerificationResult] = [],
        assessedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.runID = runID
        self.disposition = disposition
        self.requirements = requirements
        self.satisfiedRequirementIDs = satisfiedRequirementIDs
        self.unsatisfiedRequirementIDs = unsatisfiedRequirementIDs
        self.blockers = blockers
        self.relevantReceipts = relevantReceipts
        self.verificationResults = verificationResults
        self.assessedAt = assessedAt
    }
}

/// Read-only handoff projection derived solely from an OutcomeAssessment.
/// Projection is deterministic and identity-stable: requirements may co-consume one receipt,
/// so the bounded receipt identity list is deduplicated rather than repeating shared identity.
public struct OutcomeHandoff: Sendable, Equatable {
    public let taskID: String
    public let runID: UUID?
    public let disposition: OutcomeDisposition
    public let satisfiedRequirementIDs: Set<String>
    public let unsatisfiedRequirementIDs: Set<String>
    public let blockers: [OutcomeBlocker]
    public let receiptIDs: [UUID]
    public let verificationResults: [VerificationResult]

    public init(assessment: OutcomeAssessment) {
        taskID = assessment.taskID
        runID = assessment.runID
        disposition = assessment.disposition
        satisfiedRequirementIDs = assessment.satisfiedRequirementIDs
        unsatisfiedRequirementIDs = assessment.unsatisfiedRequirementIDs
        blockers = assessment.blockers
        receiptIDs = Set(assessment.relevantReceipts.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        verificationResults = assessment.verificationResults
    }
}
