import Foundation

// MARK: - Extension Domain & Identity

enum ExtensionKind: String, Sendable, Codable, Equatable, Hashable {
    case skill
    case mcp
    case hook
}

struct ExtensionSourceIdentity: Sendable, Codable, Equatable, Hashable {
    let kind: ExtensionKind
    let id: String

    init(kind: ExtensionKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

struct ExtensionSourceVersion: Sendable, Codable, Equatable, Hashable {
    let value: String

    init(value: String) {
        self.value = value
    }
}

struct ExtensionContributionIdentity: Sendable, Codable, Equatable, Hashable {
    let kind: ExtensionKind
    let sourceID: String
    let sourceVersion: ExtensionSourceVersion
    let localID: String

    init(kind: ExtensionKind, sourceID: String, sourceVersion: ExtensionSourceVersion, localID: String) {
        self.kind = kind
        self.sourceID = sourceID
        self.sourceVersion = sourceVersion
        self.localID = localID
    }

    var identifierString: String {
        "\(kind.rawValue):\(sourceID):\(sourceVersion.value):\(localID)"
    }
}

// MARK: - Origin & Epistemic Distinctions

enum ExtensionContributionOrigin: Sendable, Equatable, Hashable {
    /// Derived from Skill run snapshot capture; does not constitute execution runtime authority
    case skillRunSnapshot(runID: UUID?)
    /// Derived from live MCP runtime discovery for the current connection generation
    case mcpDiscovered(serverID: String, connectionGeneration: Int)
    /// Derived from actual execution of a hook handler producing additionalContext
    case hookInvocation(sourceID: UUID, definitionHash: String, eventName: String, handlerID: String, executionID: UUID)
}

// MARK: - Prerequisites

enum ExtensionContributionPrerequisites: Sendable, Equatable, Hashable {
    case skillSnapshot(enabledAtCapture: Bool, sourceValid: Bool)
    case mcpDiscovered(enabledIntent: Bool, connectionGeneration: Int, discoverySucceeded: Bool)
    case hookExecuted(trusted: Bool, applicable: Bool, executedWithOutput: Bool)
}

// MARK: - Payload & Claims

enum ExtensionContributionPayload: Sendable, Equatable {
    case promptFragment(String)
    case readableDirectory(URL)
    case toolDefinition(ChatToolDefinition)
    case contextFragment(String)

    static func == (lhs: ExtensionContributionPayload, rhs: ExtensionContributionPayload) -> Bool {
        switch (lhs, rhs) {
        case (.promptFragment(let a), .promptFragment(let b)):
            return a == b
        case (.readableDirectory(let a), .readableDirectory(let b)):
            return a == b
        case (.toolDefinition(let a), .toolDefinition(let b)):
            return a.function.name == b.function.name &&
                   a.function.description == b.function.description &&
                   "\(a.function.parameters)" == "\(b.function.parameters)"
        case (.contextFragment(let a), .contextFragment(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Allowed claims for an extension contribution.
/// Notice: Consumption claims (.consumed, .modelRead, .modelUsed, .modelFollowed, .modelUnderstood)
/// are strictly prohibited by Contract 7 invariants EXT-I06 and EXT-F19.
enum ExtensionContributionClaim: String, Sendable, Codable, Equatable, Hashable {
    case captured
    case available
    case runtimeDerived
    case projected
}

// MARK: - ExtensionContribution

struct ExtensionContribution: Sendable, Equatable, Identifiable {
    var id: ExtensionContributionIdentity { identity }

    let identity: ExtensionContributionIdentity
    var sourceVersion: ExtensionSourceVersion { identity.sourceVersion }
    let origin: ExtensionContributionOrigin
    let prerequisites: ExtensionContributionPrerequisites
    let payload: ExtensionContributionPayload
    let claim: ExtensionContributionClaim

    init(
        identity: ExtensionContributionIdentity,
        origin: ExtensionContributionOrigin,
        prerequisites: ExtensionContributionPrerequisites,
        payload: ExtensionContributionPayload,
        claim: ExtensionContributionClaim = .available
    ) {
        self.identity = identity
        self.origin = origin
        self.prerequisites = prerequisites
        self.payload = payload
        self.claim = claim
    }

}

// MARK: - Conflict & Deduplication Defense

enum ExtensionContributionConflictError: Error, LocalizedError, Equatable {
    case duplicateIdentityWithPayloadMismatch(identity: ExtensionContributionIdentity)
    case duplicateIdentityWithVersionMismatch(identity: ExtensionContributionIdentity)
    case duplicateIdentityWithPrerequisiteMismatch(identity: ExtensionContributionIdentity)
    case duplicateIdentityWithOriginMismatch(identity: ExtensionContributionIdentity)
    case duplicateIdentityWithClaimMismatch(identity: ExtensionContributionIdentity)
    case missingPrerequisite(identity: ExtensionContributionIdentity, detail: String)
    case domainIncoherence(identity: ExtensionContributionIdentity, detail: String)
    case invalidContribution(identity: ExtensionContributionIdentity, reason: String)

    var errorDescription: String? {
        switch self {
        case .duplicateIdentityWithPayloadMismatch(let id):
            return "Conflicting contribution payload for identity '\(id.identifierString)'."
        case .duplicateIdentityWithVersionMismatch(let id):
            return "Conflicting contribution source version for identity '\(id.identifierString)'."
        case .duplicateIdentityWithPrerequisiteMismatch(let id):
            return "Conflicting contribution prerequisites for identity '\(id.identifierString)'."
        case .duplicateIdentityWithOriginMismatch(let id):
            return "Conflicting contribution origin for identity '\(id.identifierString)'."
        case .duplicateIdentityWithClaimMismatch(let id):
            return "Conflicting contribution claim for identity '\(id.identifierString)'."
        case .missingPrerequisite(let id, let detail):
            return "Missing prerequisite for identity '\(id.identifierString)': \(detail)."
        case .domainIncoherence(let id, let detail):
            return "Domain incoherence for identity '\(id.identifierString)': \(detail)."
        case .invalidContribution(let id, let reason):
            return "Invalid contribution for identity '\(id.identifierString)': \(reason)."
        }
    }
}

extension ExtensionContribution {
    /// Validates and deduplicates contributions deterministically.
    /// Exact identical contributions are deduplicated to 1.
    /// If duplicate identities carry conflicting versions, payloads, origins, claims, or prerequisites, fails closed.
    /// Cross-domain masquerade combinations fail closed.
    static func deduplicateAndValidate(contributions: [ExtensionContribution]) throws -> [ExtensionContribution] {
        var seen: [ExtensionContributionIdentity: ExtensionContribution] = [:]

        for c in contributions {
            // Domain Coherence & Structural Prerequisite Validation
            switch c.identity.kind {
            case .skill:
                guard case .skillRunSnapshot = c.origin else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Skill identity kind must have .skillRunSnapshot origin (got \(c.origin))."
                    )
                }
                guard case .skillSnapshot(let enabledAtCapture, let sourceValid) = c.prerequisites else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Skill identity kind must have .skillSnapshot prerequisites (got \(c.prerequisites))."
                    )
                }
                guard enabledAtCapture && sourceValid else {
                    throw ExtensionContributionConflictError.invalidContribution(
                        identity: c.identity,
                        reason: "Skill prerequisites require enabledAtCapture and sourceValid to be true."
                    )
                }
                switch c.payload {
                case .promptFragment, .readableDirectory:
                    break
                default:
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Skill identity kind must have promptFragment or readableDirectory payload (got \(c.payload))."
                    )
                }

            case .mcp:
                guard case .mcpDiscovered(let serverID, let originGen) = c.origin else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "MCP identity kind must have .mcpDiscovered origin (got \(c.origin))."
                    )
                }
                guard case .mcpDiscovered(let enabledIntent, let prereqGen, let discoverySucceeded) = c.prerequisites else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "MCP identity kind must have .mcpDiscovered prerequisites (got \(c.prerequisites))."
                    )
                }
                guard enabledIntent && discoverySucceeded && originGen == prereqGen && serverID == c.identity.sourceID else {
                    throw ExtensionContributionConflictError.invalidContribution(
                        identity: c.identity,
                        reason: "MCP prerequisites require enabledIntent, discoverySucceeded, serverID match, and generation match."
                    )
                }
                guard case .toolDefinition = c.payload else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "MCP identity kind must have .toolDefinition payload (got \(c.payload))."
                    )
                }

            case .hook:
                guard case .hookInvocation(let sourceID, let defHash, _, _, _) = c.origin else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Hook identity kind must have .hookInvocation origin (got \(c.origin))."
                    )
                }
                guard defHash == c.sourceVersion.value && sourceID.uuidString == c.identity.sourceID else {
                    throw ExtensionContributionConflictError.invalidContribution(
                        identity: c.identity,
                        reason: "Hook origin definitionHash must match contribution sourceVersion and sourceID."
                    )
                }
                guard case .hookExecuted(let trusted, let applicable, let executedWithOutput) = c.prerequisites else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Hook identity kind must have .hookExecuted prerequisites (got \(c.prerequisites))."
                    )
                }
                guard trusted && applicable && executedWithOutput else {
                    throw ExtensionContributionConflictError.invalidContribution(
                        identity: c.identity,
                        reason: "Hook prerequisites require trusted == true, applicable == true, and executedWithOutput == true."
                    )
                }
                guard case .contextFragment = c.payload else {
                    throw ExtensionContributionConflictError.domainIncoherence(
                        identity: c.identity,
                        detail: "Hook identity kind must have .contextFragment payload (got \(c.payload))."
                    )
                }
            }

            if let existing = seen[c.identity] {
                // Must be exact match across all facets
                guard existing.sourceVersion == c.sourceVersion else {
                    throw ExtensionContributionConflictError.duplicateIdentityWithVersionMismatch(identity: c.identity)
                }
                guard existing.origin == c.origin else {
                    throw ExtensionContributionConflictError.duplicateIdentityWithOriginMismatch(identity: c.identity)
                }
                guard existing.prerequisites == c.prerequisites else {
                    throw ExtensionContributionConflictError.duplicateIdentityWithPrerequisiteMismatch(identity: c.identity)
                }
                guard existing.payload == c.payload else {
                    throw ExtensionContributionConflictError.duplicateIdentityWithPayloadMismatch(identity: c.identity)
                }
                guard existing.claim == c.claim else {
                    throw ExtensionContributionConflictError.duplicateIdentityWithClaimMismatch(identity: c.identity)
                }
                // Exact duplicate: keep existing
            } else {
                seen[c.identity] = c
            }
        }

        // Return deterministically sorted by identifierString
        return seen.values.sorted { $0.identity.identifierString < $1.identity.identifierString }
    }

    static func projectPrompts(from contributions: [ExtensionContribution]) -> [String] {
        contributions.compactMap { c in
            if case .promptFragment(let p) = c.payload {
                return p
            }
            return nil
        }
    }

    static func projectSkillPrompt(from contributions: [ExtensionContribution]) -> String? {
        let skillContribs = contributions.filter { $0.identity.kind == .skill && $0.identity.localID == "prompt" }
        guard !skillContribs.isEmpty else { return nil }

        var xml = "<available_skills>\n"
        for c in skillContribs {
            if case .promptFragment(let fragment) = c.payload {
                xml += fragment + "\n"
            }
        }
        xml += "</available_skills>"

        var result = "Skills:\n"
        result += "Reusable instruction sets stored on disk. When a task matches an available skill, read the SKILL.md file using file_read to load its full instructions before proceeding.\n\n"
        result += xml

        if let omittedContrib = contributions.first(where: { $0.identity.kind == .skill && $0.identity.localID == "omittedSummary" }),
           case .promptFragment(let summaryText) = omittedContrib.payload,
           !summaryText.isEmpty {
            result += "\n\n" + summaryText
        }

        return result
    }

    static func projectToolDefinitions(from contributions: [ExtensionContribution]) -> [ChatToolDefinition] {
        contributions.compactMap { c in
            if case .toolDefinition(let t) = c.payload {
                return t
            }
            return nil
        }
    }

    static func projectHookContext(from contributions: [ExtensionContribution]) -> String? {
        let fragments: [String] = contributions.compactMap { c in
            if case .contextFragment(let ctx) = c.payload, !ctx.isEmpty {
                return ctx
            }
            return nil
        }
        return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
    }

    static func projectReadableDirectories(from contributions: [ExtensionContribution]) -> [URL] {
        contributions.compactMap { c in
            if case .readableDirectory(let u) = c.payload {
                return u
            }
            return nil
        }
    }
}
