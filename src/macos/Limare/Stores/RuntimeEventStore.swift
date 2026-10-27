import Foundation
import Observation

enum RuntimeEventDomain: String, Codable, CaseIterable, Sendable {
    case run, modelRouting, tool, permission, context, recovery, failure
}

enum RuntimeEventSeverity: String, Codable, Sendable {
    case info, warning, error
}

enum RuntimeEventPresentationRole: String, Sendable {
    case rootFailure = "Cause"
    case derivedDiagnostic = "Diagnostic consequence"
    case routingDecision = "Routing decision"
    case terminalOutcome = "Terminal result"
    case lifecycle = "Lifecycle"
}

enum RuntimeFailureClassification: String, Codable, Sendable {
    case provider, authentication, rateLimit, network, modelCapability, context
    case tool, persistence
    case cancellation
    case internalError = "internal"
}

struct RuntimeEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let sequence: Int
    let conversationID: UUID
    let runID: UUID
    let domain: RuntimeEventDomain
    let kind: String
    let severity: RuntimeEventSeverity
    let summary: String
    let metadata: [String: String]

    init(id: UUID = UUID(), timestamp: Date = Date(), sequence: Int = 0, conversationID: UUID, runID: UUID, domain: RuntimeEventDomain, kind: String, severity: RuntimeEventSeverity = .info, summary: String, metadata: [String: String] = [:]) {
        self.id = id
        self.timestamp = timestamp
        self.sequence = sequence
        self.conversationID = conversationID
        self.runID = runID
        self.domain = domain
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.metadata = metadata
    }
}

extension RuntimeEvent {
    var presentationRole: RuntimeEventPresentationRole {
        if kind == "failure.recorded" || kind == "context.exhausted" { return .rootFailure }
        if kind.hasPrefix("model.") { return .routingDecision }
        if ["run.completed", "run.failed", "run.cancelled", "run.interrupted"].contains(kind) { return .terminalOutcome }
        if kind == "trace.truncated" || kind.contains("diagnostic") { return .derivedDiagnostic }
        return .lifecycle
    }
}

struct RunTraceProjection: Sendable {
    let events: [RuntimeEvent]
    let currentStatus: String
    let actualProvider: String?
    let actualModel: String?

    init(events: [RuntimeEvent]) {
        self.events = events.sorted { $0.sequence < $1.sequence }
        actualProvider = self.events.last(where: { $0.kind == "model.selected" })?.metadata["provider"]
        actualModel = self.events.last(where: { $0.kind == "model.selected" })?.metadata["model"]
        currentStatus = Self.projectStatus(events: self.events)
    }

    private static func projectStatus(events: [RuntimeEvent]) -> String {
        guard !events.isEmpty else { return String(localized: "Working") }
        if let terminal = events.last(where: { ["run.completed", "run.failed", "run.cancelled", "run.interrupted"].contains($0.kind) }) {
            return terminal.summary
        }
        if let request = events.last(where: { $0.kind == "permission.requested" }),
           !events.contains(where: { $0.sequence > request.sequence && ["permission.approved", "permission.denied", "permission.cancelled"].contains($0.kind) && $0.metadata["toolCallID"] == request.metadata["toolCallID"] }) {
            return String(localized: "Waiting for approval")
        }
        if let question = events.last(where: { $0.kind == "question.presented" }),
           !events.contains(where: { $0.sequence > question.sequence && ["question.answered", "question.skipped", "question.superseded", "question.cancelled"].contains($0.kind) && $0.metadata["toolCallID"] == question.metadata["toolCallID"] }) {
            return String(localized: "Waiting for your answer")
        }
        if events.last(where: { $0.domain == .run })?.kind == "run.paused" { return "Paused" }
        if let started = events.last(where: { $0.kind == "tool.started" }),
           !events.contains(where: { $0.sequence > started.sequence && ["tool.completed", "tool.failed"].contains($0.kind) && $0.metadata["toolCallID"] == started.metadata["toolCallID"] }) {
            switch started.metadata["tool"] {
            case "file_read": return String(localized: "Reading file")
            case "shell_execute": return String(localized: "Running command")
            case "browser_use": return String(localized: "Browsing web")
            default: return String(localized: "Using connected tool")
            }
        }
        return String(localized: "Working")
    }
}

/// The one line the top of a conversation shows about its run, when there is news.
struct RunStatusStripLine: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case error, warning, secondary }
    let text: String
    let symbolName: String
    let tone: Tone
}

/// When the run status line shows, and what it says. Most of a run's states are already in the
/// transcript (the working row, the approval, the question card, the reply's notice), so the
/// line shows only what nothing else does: a failure, a pause, a retry, a backup model.
enum RunStatusStripPolicy {
    static let retryingKinds: Set<String> = ["model.retrying", "providerRequest.retrying"]

    static func line(status: ConversationRunStatus, trace: RunTraceProjection) -> RunStatusStripLine? {
        if status == .failed {
            return RunStatusStripLine(text: trace.currentStatus, symbolName: "exclamationmark.triangle", tone: .error)
        }
        if status == .paused {
            return RunStatusStripLine(text: String(localized: "Paused"), symbolName: "pause.circle", tone: .warning)
        }
        // A model group retrying its member and a provider retrying its own request both wait to
        // send again; the line clears once the request goes out.
        if status == .running || status == .queued,
           let routing = trace.events.last(where: { $0.domain == .modelRouting }), retryingKinds.contains(routing.kind) {
            return RunStatusStripLine(text: routing.summary, symbolName: "arrow.clockwise", tone: .secondary)
        }
        // Kept once the run ends, so the reply's source stays known until the next turn.
        if let fallback = trace.events.last(where: { $0.kind == "model.fallback" }) {
            let text = fallback.metadata["toModel"].map { "Switched to a backup model: \($0)" } ?? "Switched to a backup model"
            return RunStatusStripLine(text: text, symbolName: "arrow.triangle.branch", tone: .secondary)
        }
        return nil
    }
}

@MainActor
@Observable
final class RuntimeEventStore {
    private(set) var eventsByRun: [UUID: [RuntimeEvent]] = [:]
    private let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let persistenceWriter: ((Data, URL) throws -> Void)?
    private let maximumEventsPerRun = 500

    init(
        storageRootURL: URL? = nil,
        fileManager: FileManager = .default,
        persistenceWriter: ((Data, URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        let applicationRoot = storageRootURL ?? LimareStorage.defaultRoot
        rootURL = applicationRoot.appendingPathComponent("runtime_events", isDirectory: true)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.persistenceWriter = persistenceWriter
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        loadPersistedEvents()
    }

    func record(conversationID: UUID, runID: UUID, domain: RuntimeEventDomain, kind: String, severity: RuntimeEventSeverity = .info, summary: String, metadata: [String: String] = [:]) {
        // This is a provenance store, not a transcript. Call sites intentionally
        // provide only identifiers, counts, status codes, and redacted reasons.
        let cleanMetadata = sanitize(metadata)
        var list = eventsByRun[runID] ?? []
        let nextSequence = (list.map(\.sequence).max() ?? 0) + 1
        list.append(RuntimeEvent(sequence: nextSequence, conversationID: conversationID, runID: runID, domain: domain, kind: kind, severity: severity, summary: sanitizeSummary(summary), metadata: cleanMetadata))
        if list.count > maximumEventsPerRun {
            let firstLostSequence = list.sorted { $0.sequence < $1.sequence }.first?.sequence ?? 0
            let retained = Array(list.sorted { $0.sequence < $1.sequence }.suffix(maximumEventsPerRun - 1))
            let marker = list.first(where: { $0.kind == "trace.truncated" }) ?? RuntimeEvent(
                sequence: firstLostSequence,
                conversationID: conversationID,
                runID: runID,
                domain: .run,
                kind: "trace.truncated",
                severity: .warning,
                summary: "Earlier trace history was omitted.",
                metadata: ["truncated": "true"]
            )
            list = [marker] + retained.filter { $0.kind != "trace.truncated" }
        }
        eventsByRun[runID] = list
        persist(list, conversationID: conversationID, runID: runID)
    }

    /// A deleted conversation's run events go with it; they were kept forever before and all of
    /// them were loaded at every launch.
    func removeEvents(conversationID: UUID) {
        eventsByRun = eventsByRun.filter { $0.value.first?.conversationID != conversationID }
        try? fileManager.removeItem(at: rootURL.appendingPathComponent(conversationID.uuidString, isDirectory: true))
    }

    func events(for runID: UUID) -> [RuntimeEvent] { (eventsByRun[runID] ?? []).sorted { $0.sequence < $1.sequence } }
    func trace(for runID: UUID) -> RunTraceProjection { RunTraceProjection(events: events(for: runID)) }

    private func fileURL(conversationID: UUID, runID: UUID) -> URL {
        let directory = rootURL.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("\(runID.uuidString).json")
    }

    private func persist(_ events: [RuntimeEvent], conversationID: UUID, runID: UUID) {
        let url = fileURL(conversationID: conversationID, runID: runID)
        do {
            let data = try encoder.encode(events)
            if let persistenceWriter {
                try persistenceWriter(data, url)
            } else {
                try data.write(to: url, options: .atomic)
            }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Observability must never alter the run's outcome. */ }
    }

    private func loadPersistedEvents() {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where url.pathExtension == "json" {
            guard let events = try? decoder.decode([RuntimeEvent].self, from: Data(contentsOf: url)), let runID = events.first?.runID else { continue }
            eventsByRun[runID] = events.sorted { $0.sequence < $1.sequence }
        }
    }

    private func sanitize(_ metadata: [String: String]) -> [String: String] {
        let safeKeys: Set<String> = [
            "disposition", "dispatched", "reason",
            "outcome", "finishRaw", "finishUnified", "textCharacters", "reasoningCharacters", "terminalMarkerReceived",
            "protocol", "authRoute", "thinkingRequested", "thinkingEffective", "thinkingControl", "thinkingSource", "thinkingOffBehavior", "thinkingClampReason", "thinkingUnsupportedRaw",
            "provider", "model", "requestedSource", "attempt", "requestAttempt", "classification",
            "recoverable", "httpStatus", "decision", "fromProvider", "fromModel",
            "toProvider", "toModel", "tool", "toolCallID", "durationMilliseconds",
            "approvalState", "contextWindow", "estimatedBefore", "estimatedAfter",
            "effectiveBudget", "compactedMessageCount", "recoveredFromRunID", "group",
            "availability", "contextFailureKind", "compactionStage", "fallbackReason",
            "targetBudget", "semanticFallbackCount", "reasoningItemsReduced",
            "attachmentsReduced", "toolResultsReduced", "stagesAttempted",
            "providerID", "fromProviderID", "toProviderID", "candidateState",
            "skipReason", "scheduledTaskID", "scheduledRunID", "truncated", "firstOutputMilliseconds", "inputTokens", "outputTokens", "toolCalls", "transport"
        ]
        return metadata.reduce(into: [:]) { result, pair in
            if pair.key == "toolNames",
               let data = pair.value.data(using: .utf8),
               let names = try? JSONSerialization.jsonObject(with: data) as? [String],
               names.allSatisfy({ !$0.isEmpty && $0.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil }) {
                // Serialized provider tool identifiers only. Preserve the complete trace.
                result[pair.key] = pair.value
                return
            }
            guard safeKeys.contains(pair.key), !looksSensitive(pair.value) else { return }
            let redactedVal = SecretMasker.redactCredentials(pair.value)
            guard !looksSensitive(redactedVal) else { return }
            result[pair.key] = String(redactedVal.prefix(160))
        }
    }

    private func looksSensitive(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("authorization") ||
               lower.contains("bearer ") ||
               lower.contains("api key") ||
               lower.contains("sk-") ||
               lower.contains("ghp_") ||
               lower.contains("secret_")
    }

    private func sanitizeSummary(_ summary: String) -> String {
        let redacted = SecretMasker.redactCredentials(summary)
        return looksSensitive(redacted) ? "Runtime event" : String(redacted.prefix(160))
    }
}

extension RuntimeFailureClassification {
    static func classify(_ error: Error) -> RuntimeFailureClassification {
        if error is RuntimePersistenceError { return .persistence }
        if let ctxErr = error as? ContextLifecycleError {
            switch ctxErr {
            case .derivedStatePersistenceFailure:
                return .persistence
            case .commitAuthorityRevoked, .sourceMutatedDuringPlanning, .emptySummary:
                return .internalError
            case .protectedContextExhaustion, .noSafeCompactionBoundary, .recoveryExhaustion, .recentContextExceedsBudget, .nothingToCompact:
                return .context
            }
        }
        if error is CancellationError { return .cancellation }
        if let urlError = error as? URLError { return urlError.code == .cancelled ? .cancellation : .network }
        if let error = error as? ProviderClientError {
            switch error {
            case .http(let status, let message):
                if ProviderContextOverflowRecognizer.isOverflow(status: status, message: message) {
                    return .context
                }
                if status == 401 || status == 403 { return .authentication }
                if status == 429 { return .rateLimit }
                return .provider
            case .responsesFailed(let code, let message):
                if ProviderContextOverflowRecognizer.isOverflow(responsesCode: code, message: message) {
                    return .context
                }
                return .provider
            case .streamError:
                break
            default:
                return .provider
            }
        }
        switch ModelRoutingClassifier.classify(error) {
        case .contextCapacity, .providerContextOverflow: return .context
        case .toolExecution: return .tool
        case .providerInvocation: return .provider
        case .providerContentFiltered: return .provider
        case .providerRateLimit: return .rateLimit
        case .permanentProviderRejection(_, let statusCode):
            if statusCode == 401 || statusCode == 403 { return .authentication }
            return .provider
        case .cancellation: return .cancellation
        case .harness: return .internalError
        }
    }
}
