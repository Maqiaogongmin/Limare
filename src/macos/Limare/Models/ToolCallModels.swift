import Foundation

enum ToolExecutionState: String, Codable, Sendable {
    case queued
    case awaitingApproval
    case running
    case completed
    case failed
    case timedOut
    case cancelled
    case denied
    case interrupted
}

public enum ToolResultPart: Codable, Sendable, Equatable {
    case text(String)
    case artifact(
        id: UUID,
        semanticRole: ArtifactSemanticRole,
        mimeType: String
    )
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, semanticRole, mimeType, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "artifact":
            let id = try container.decode(UUID.self, forKey: .id)
            let semanticRole = try container.decodeIfPresent(ArtifactSemanticRole.self, forKey: .semanticRole) ?? .unspecified
            let mimeType = try container.decode(String.self, forKey: .mimeType)
            self = .artifact(id: id, semanticRole: semanticRole, mimeType: mimeType)
        case "error":
            let err = try container.decode(String.self, forKey: .error)
            self = .error(err)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown ToolResultPart type: \(type)")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .artifact(let id, let semanticRole, let mimeType):
            try container.encode("artifact", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(semanticRole, forKey: .semanticRole)
            try container.encode(mimeType, forKey: .mimeType)
        case .error(let err):
            try container.encode("error", forKey: .type)
            try container.encode(err, forKey: .error)
        }
    }
}

struct ToolCallRecord: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var providerCallID: String
    var name: String
    var input: String
    var state: ToolExecutionState
    var output: String
    var durationMilliseconds: Int?
    var errorMessage: String?
    var approvalState: ToolApprovalState
    var resultParts: [ToolResultPart]?

    /// Bounded, machine-readable terminal fact of this tool outcome
    /// (for example `shell(exitCode:timedOut:cancelled:)`).
    ///
    /// `output` holds presentation / model-facing tool result text, which is not a mechanical fact.
    /// This field is the durable terminal truth that bounded evidence reads. The two must never
    /// duplicate each other, and neither prose nor a full tool payload is stored here.
    var mechanicalTerminalFact: ToolMechanicalTerminalFact?
    /// Kernel-owned durable attribution. Older records have no proven run owner.
    var owningRunID: UUID? = nil

    init(
        id: UUID = UUID(),
        providerCallID: String,
        name: String,
        input: String,
        state: ToolExecutionState = .queued,
        output: String = "",
        durationMilliseconds: Int? = nil,
        errorMessage: String? = nil,
        approvalState: ToolApprovalState = .notRequired,
        resultParts: [ToolResultPart]? = nil,
        mechanicalTerminalFact: ToolMechanicalTerminalFact? = nil
    ) {
        self.id = id
        self.providerCallID = providerCallID
        self.name = name
        self.input = input
        self.state = state
        self.output = output
        self.durationMilliseconds = durationMilliseconds
        self.errorMessage = errorMessage
        self.approvalState = approvalState
        self.resultParts = resultParts
        self.mechanicalTerminalFact = mechanicalTerminalFact
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerCallID, name, input, state, output, durationMilliseconds, errorMessage, approvalState, resultParts, mechanicalTerminalFact, owningRunID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.providerCallID = try container.decode(String.self, forKey: .providerCallID)
        self.name = try container.decode(String.self, forKey: .name)
        self.input = try container.decode(String.self, forKey: .input)
        self.state = try container.decode(ToolExecutionState.self, forKey: .state)
        self.output = try container.decodeIfPresent(String.self, forKey: .output) ?? ""
        self.durationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .durationMilliseconds)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.approvalState = try container.decodeIfPresent(ToolApprovalState.self, forKey: .approvalState) ?? .notRequired
        self.resultParts = try container.decodeIfPresent([ToolResultPart].self, forKey: .resultParts)
        self.mechanicalTerminalFact = try container.decodeIfPresent(ToolMechanicalTerminalFact.self, forKey: .mechanicalTerminalFact)
        self.owningRunID = try container.decodeIfPresent(UUID.self, forKey: .owningRunID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerCallID, forKey: .providerCallID)
        try container.encode(name, forKey: .name)
        try container.encode(input, forKey: .input)
        try container.encode(state, forKey: .state)
        try container.encode(output, forKey: .output)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encode(approvalState, forKey: .approvalState)
        try container.encodeIfPresent(resultParts, forKey: .resultParts)
        try container.encodeIfPresent(mechanicalTerminalFact, forKey: .mechanicalTerminalFact)
        try container.encodeIfPresent(owningRunID, forKey: .owningRunID)
    }
}

/// Bounded, machine-readable terminal fact produced by a canonical tool outcome.
///
/// This carries only the mechanical datum that bounded evidence needs to reason about a tool's
/// terminal result. It never carries `stdout`, `stderr`, display text, or a full tool payload —
/// those remain presentation truth in `ToolCallRecord.output` and are never parsed as evidence.
enum BrowserMechanicalDisposition: String, Codable, Sendable { case busy, pausedForUserControl, sessionReset }

enum ToolMechanicalTerminalFact: Codable, Sendable, Equatable {
    case browserAction(dispatched: Bool, disposition: BrowserMechanicalDisposition, reason: String)
    case shell(exitCode: Int32?, timedOut: Bool, cancelled: Bool)
    /// Bounded record of one representation materialization attempt: which exact
    /// source, which exact derived artifact, which conversion attempt, whether the
    /// artifact was committed by Artifact Authority, and whether it was reopened
    /// from that authority afterwards.
    ///
    /// It carries no extracted text, no source bytes, no tool prose, and no model
    /// interpretation. Materialization and reopen are separate booleans so a real
    /// partial side effect ("materialized, reopen failed") stays expressible.
    case representationArtifact(
        sourceRef: ResourceRef,
        artifactRef: ArtifactRef,
        attemptID: UUID,
        materialized: Bool,
        reopened: Bool
    )
    /// Bounded mechanical Computer Use terminal truth (Item 4).
    /// Carries strictly mechanical execution facts: result status, action kind, whether OS event
    /// may have commenced, and transient input release outcome. Zero GUI semantic verdicts.
    case computerUse(
        status: ComputerUseActionResultStatus,
        actionKind: ComputerUseActionKind,
        osEventStarted: Bool,
        transientReleaseOutcome: ComputerUseTransientReleaseOutcome?
    )

    /// Bounded shell terminal metadata, or nil when this fact is not a shell fact.
    var shellTerminal: (exitCode: Int32?, timedOut: Bool, cancelled: Bool)? {
        guard case .shell(let exitCode, let timedOut, let cancelled) = self else { return nil }
        return (exitCode: exitCode, timedOut: timedOut, cancelled: cancelled)
    }

    /// Bounded representation-materialization metadata, or nil when this fact is not one.
    var representationArtifact: (
        sourceRef: ResourceRef,
        artifactRef: ArtifactRef,
        attemptID: UUID,
        materialized: Bool,
        reopened: Bool
    )? {
        guard case .representationArtifact(let sourceRef, let artifactRef, let attemptID, let materialized, let reopened) = self else {
            return nil
        }
        return (sourceRef, artifactRef, attemptID, materialized, reopened)
    }

    /// Bounded Computer Use mechanical terminal metadata, or nil when not a Computer Use fact.
    var computerUseTerminal: (
        status: ComputerUseActionResultStatus,
        actionKind: ComputerUseActionKind,
        osEventStarted: Bool,
        transientReleaseOutcome: ComputerUseTransientReleaseOutcome?
    )? {
        guard case .computerUse(let status, let kind, let osEventStarted, let releaseOutcome) = self else { return nil }
        return (status, kind, osEventStarted, releaseOutcome)
    }
}

struct ToolExecutionOutcome: Sendable {
    let content: String
    let isError: Bool
    let approvalState: ToolApprovalState
    let durationMilliseconds: Int
    let attachments: [ChatAttachment]
    let resultParts: [ToolResultPart]
    /// Minimal typed propagation of the canonical terminal fact when the producing tool owns one.
    let mechanicalTerminalFact: ToolMechanicalTerminalFact?

    init(
        content: String,
        isError: Bool,
        approvalState: ToolApprovalState,
        durationMilliseconds: Int,
        attachments: [ChatAttachment] = [],
        resultParts: [ToolResultPart]? = nil,
        mechanicalTerminalFact: ToolMechanicalTerminalFact? = nil
    ) {
        self.content = content
        self.isError = isError
        self.approvalState = approvalState
        self.durationMilliseconds = durationMilliseconds
        self.attachments = attachments
        self.mechanicalTerminalFact = mechanicalTerminalFact
        if let resultParts {
            self.resultParts = resultParts
        } else if isError {
            self.resultParts = [.error(content)]
        } else {
            self.resultParts = [.text(content)]
        }
    }
}

extension ToolExecutionOutcome {
    /// The same outcome with `text` appended to what the model reads.
    func appendingText(_ text: String) -> ToolExecutionOutcome {
        var parts = resultParts
        if parts.count == 1, case .text = parts[0] { parts = [.text(content + text)] } else { parts.append(.text(text)) }
        return ToolExecutionOutcome(content: content + text, isError: isError, approvalState: approvalState,
                                    durationMilliseconds: durationMilliseconds, attachments: attachments,
                                    resultParts: parts, mechanicalTerminalFact: mechanicalTerminalFact)
    }
}

struct ToolExecutionUpdate: Sendable {
    let state: ToolExecutionState
    let approvalState: ToolApprovalState
    let output: String
}

extension ToolExecutionState {
    var isTerminal: Bool {
        switch self {
        case .queued, .awaitingApproval, .running:
            return false
        case .completed, .failed, .timedOut, .cancelled, .denied, .interrupted:
            return true
        }
    }

    /// Determines whether this state can legally transition to `newState`.
    /// Once terminal, semantic state cannot transition to any different state.
    func canTransition(to newState: ToolExecutionState) -> Bool {
        if self == newState { return true }
        if self.isTerminal {
            return false
        }
        return true
    }
}

extension ToolCallRecord {
    /// Applies an execution update to this record, strictly enforcing terminal-state immutability.
    ///
    /// If this record is already in a terminal state:
    /// - Any conflicting update (e.g. attempting to change state or overwrite output) is rejected.
    /// - The record's `state`, `output`, `errorMessage`, and `approvalState` are strictly preserved.
    /// Returns `true` if the update was applied, or `false` if discarded due to terminal immutability.
    @discardableResult
    mutating func applyExecutionUpdate(_ update: ToolExecutionUpdate) -> Bool {
        if state.isTerminal {
            return false
        }
        state = update.state
        approvalState = update.approvalState
        output = update.output
        if update.state == .failed || update.state == .timedOut || update.state == .cancelled || update.state == .denied || update.state == .interrupted {
            if errorMessage == nil || errorMessage?.isEmpty == true {
                errorMessage = update.output.isEmpty ? nil : update.output
            }
        }
        return true
    }

    /// Merges a finalized ToolExecutionOutcome into this record according to terminal immutability rules.
    mutating func applyFinalOutcome(_ outcome: ToolExecutionOutcome) {
        if !state.isTerminal {
            if durationMilliseconds == nil {
                durationMilliseconds = outcome.durationMilliseconds
            }
            if resultParts == nil || resultParts?.isEmpty == true {
                resultParts = outcome.resultParts
            }
            if outcome.isError {
                state = (outcome.approvalState == .denied) ? .denied : .failed
            } else {
                state = .completed
            }
            approvalState = outcome.approvalState
            if output.isEmpty {
                output = outcome.content
            }
            if outcome.isError {
                errorMessage = outcome.content
            }
        } else {
            // Authoritative terminal state already established: preserve it against contradictory outcomes.
            let conflicting = (!outcome.isError && state != .completed) || (outcome.isError && state == .completed)
            if conflicting {
                // Reject contradictory outcome (e.g. late success on cancelled or failed tool)
                return
            }

            if durationMilliseconds == nil {
                durationMilliseconds = outcome.durationMilliseconds
            }
            if resultParts == nil || resultParts?.isEmpty == true {
                resultParts = outcome.resultParts
            }

            if state == .denied {
                approvalState = .denied
            }

            // Populate empty output if it wasn't populated by an earlier update
            if output.isEmpty {
                output = outcome.content
            }

            // Preserve authoritative failure provenance (exit_code, timed_out, stderr, error details)
            // in errorMessage when outcome indicates failure.
            if outcome.isError && (state == .failed || state == .timedOut || state == .denied) {
                errorMessage = outcome.content
            }
        }

        // Capture the bounded typed terminal fact the producing tool already owns. `output` stays
        // presentation truth and is never parsed; `content` is never copied into the durable record.
        if state.isTerminal, let fact = outcome.mechanicalTerminalFact {
            mechanicalTerminalFact = fact
        }
    }
}
