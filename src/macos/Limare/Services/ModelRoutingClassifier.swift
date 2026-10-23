import Foundation

enum ProviderContextOverflowRecognizer {
    static func isOverflow(status: Int, message: String) -> Bool {
        guard status == 400 else { return false }
        let lower = message.lowercased()
        if lower.contains("context_length_exceeded") ||
           lower.contains("maximum context length") ||
           lower.contains("context window exceeded") ||
           lower.contains("prompt is too long") ||
           lower.contains("exceeds the context window") ||
           lower.contains("context length exceeded") {
            return true
        }
        return false
    }

    static func isOverflow(responsesCode: String, message: String) -> Bool {
        let codeLower = responsesCode.lowercased()
        let msgLower = message.lowercased()
        if codeLower == "context_length_exceeded" ||
           codeLower == "context_window_exceeded" ||
           msgLower.contains("context_length_exceeded") ||
           msgLower.contains("maximum context length") ||
           msgLower.contains("context window exceeded") ||
           msgLower.contains("exceeds the context window") {
            return true
        }
        return false
    }
}

enum ModelRoutingFailureClass: Equatable, Sendable {
    case providerInvocation(reason: String, isTransient: Bool, statusCode: Int?)
    case providerContentFiltered(reason: String)
    case providerRateLimit(reason: String)
    case permanentProviderRejection(reason: String, statusCode: Int?)
    case providerContextOverflow(reason: String, statusCode: Int?)
    case contextCapacity(reason: String)
    case harness(reason: String)
    case toolExecution(reason: String)
    case cancellation

    var label: String {
        switch self {
        case .providerInvocation(_, let isTransient, let statusCode):
            let code = statusCode.map { " (HTTP \($0))" } ?? ""
            let trans = isTransient ? " [transient]" : ""
            return "providerInvocation\(code)\(trans)"
        case .providerContentFiltered: return "providerContentFiltered"
        case .providerRateLimit:
            return "providerRateLimit (HTTP 429)"
        case .permanentProviderRejection(_, let statusCode):
            let code = statusCode.map { " (HTTP \($0))" } ?? ""
            return "permanentProviderRejection\(code)"
        case .providerContextOverflow(_, let statusCode):
            let code = statusCode.map { " (HTTP \($0))" } ?? ""
            return "providerContextOverflow\(code)"
        case .contextCapacity:
            return "contextCapacity"
        case .harness:
            return "harness"
        case .toolExecution:
            return "toolExecution"
        case .cancellation:
            return "cancellation"
        }
    }
}

enum RoutingDecision: Equatable, Sendable {
    case retryCurrent(attempt: Int, delaySeconds: Double, reason: String)
    case fallbackNext(reason: String)
    case stop(reason: String)
}

extension RoutingDecision {
    var eventDecision: String {
        switch self {
        case .retryCurrent: return "retry"
        case .fallbackNext: return "fallback"
        case .stop: return "stop"
        }
    }
}

struct ModelRoutingClassifier {
    static func classify(_ error: Error) -> ModelRoutingFailureClass {
        if error is CancellationError {
            return .cancellation
        }
        if let turn = error as? AssistantTurnError {
            if turn.outcome == .contentFiltered { return .providerContentFiltered(reason: turn.localizedDescription) }
            return .providerInvocation(reason: turn.localizedDescription, isTransient: turn.isTransient, statusCode: nil)
        }
        if let ctxErr = error as? ContextLifecycleError {
            if ctxErr.isCapacityFailure {
                return .contextCapacity(reason: ctxErr.userFacingMessage)
            } else {
                return .harness(reason: ctxErr.userFacingMessage)
            }
        }
        if let clientError = error as? ProviderClientError {
            switch clientError {
            case .http(let status, let message):
                let sanitizedMsg = SecretMasker.redactCredentials(message)
                if ProviderContextOverflowRecognizer.isOverflow(status: status, message: message) {
                    let msg = sanitizedMsg.isEmpty ? "HTTP status 400 (context length exceeded)" : sanitizedMsg
                    return .providerContextOverflow(reason: msg, statusCode: status)
                }
                let msg = sanitizedMsg.isEmpty ? "HTTP status \(status)" : sanitizedMsg
                if status == 429 {
                    return .providerRateLimit(reason: msg)
                }
                if (500...599).contains(status) || status == 408 {
                    return .providerInvocation(reason: msg, isTransient: true, statusCode: status)
                }
                if status == 400, ProviderHTTPRetrySignal.delayFromMessage(message) != nil {
                    return .providerInvocation(reason: msg, isTransient: true, statusCode: status)
                }
                if status == 400 || status == 401 || status == 403 || status == 404 || status == 422 {
                    return .permanentProviderRejection(reason: msg, statusCode: status)
                }
                return .providerInvocation(reason: msg, isTransient: false, statusCode: status)
            case .invalidResponse:
                return .providerInvocation(reason: "Invalid HTTP response from provider", isTransient: false, statusCode: nil)
            case .invalidModelsPayload:
                return .providerInvocation(reason: "Invalid models payload", isTransient: false, statusCode: nil)
            case .emptyStream:
                return .providerInvocation(reason: "Provider stream finished with no content", isTransient: true, statusCode: nil)
            case .incompleteToolCall(let message):
                return .providerInvocation(reason: SecretMasker.redactCredentials(message), isTransient: false, statusCode: nil)
            case .responsesFailed(let code, let message):
                let sanitizedMsg = SecretMasker.redactCredentials(message)
                if ProviderContextOverflowRecognizer.isOverflow(responsesCode: code, message: message) {
                    let msg = sanitizedMsg.isEmpty ? "Responses API context overflow [\(code)]" : "Responses API context overflow [\(code)]: \(sanitizedMsg)"
                    return .providerContextOverflow(reason: msg, statusCode: 400)
                }
                let codeLower = code.lowercased()
                let msg = sanitizedMsg.isEmpty ? "Responses API error [\(code)]" : "Responses API error [\(code)]: \(sanitizedMsg)"
                if codeLower == "rate_limit_exceeded" {
                    return .providerRateLimit(reason: msg)
                }
                if codeLower == "server_error" {
                    return .providerInvocation(reason: msg, isTransient: true, statusCode: 500)
                }
                return .permanentProviderRejection(reason: msg, statusCode: nil)
            case .streamError(let code, let message):
                // Like Codex for a failed stream: only a code naming a cause a retry cannot change
                // stops it; anything else is the provider dropping an accepted stream.
                let msg = SecretMasker.redactCredentials(clientError.localizedDescription)
                if ProviderContextOverflowRecognizer.isOverflow(responsesCode: code ?? "", message: message) {
                    return .providerContextOverflow(reason: msg, statusCode: nil)
                }
                switch code?.lowercased() {
                case "rate_limit_exceeded", "rate_limit_error", "resource_exhausted", "429":
                    return .providerRateLimit(reason: msg)
                case "insufficient_quota", "authentication_error", "permission_error", "unauthenticated", "permission_denied", "401", "403":
                    return .permanentProviderRejection(reason: msg, statusCode: nil)
                default:
                    return .providerInvocation(reason: msg, isTransient: true, statusCode: nil)
                }
            case .responsesIncomplete(let reason):
                if reason == "content_filter" { return .providerContentFiltered(reason: "Provider filtered the response") }
                return .providerInvocation(reason: "Responses stream incomplete: \(SecretMasker.redactCredentials(reason))", isTransient: false, statusCode: nil)
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return .cancellation
            }
            return .providerInvocation(reason: SecretMasker.redactCredentials(urlError.localizedDescription), isTransient: true, statusCode: nil)
        }
        if let providerStoreError = error as? ProviderStoreError {
            return .providerInvocation(reason: SecretMasker.redactCredentials(providerStoreError.localizedDescription), isTransient: false, statusCode: nil)
        }
        if let termReason = error as? AgentLoopTerminationReason {
            return .harness(reason: SecretMasker.redactCredentials(termReason.localizedDescription))
        }
        if let persistenceError = error as? RuntimePersistenceError {
            return .harness(reason: SecretMasker.redactCredentials(persistenceError.localizedDescription))
        }
        if let toolError = error as? ToolExecutorError {
            return .toolExecution(reason: SecretMasker.redactCredentials(toolError.localizedDescription))
        }
        if let shellError = error as? ShellRunnerError {
            return .toolExecution(reason: SecretMasker.redactCredentials(shellError.localizedDescription))
        }
        if let fileError = error as? FileToolError {
            return .toolExecution(reason: SecretMasker.redactCredentials(fileError.localizedDescription))
        }
        if let wsError = error as? WorkspacePathError {
            return .toolExecution(reason: SecretMasker.redactCredentials(wsError.localizedDescription))
        }
        return .harness(reason: SecretMasker.redactCredentials(error.localizedDescription))
    }

    static func decide(
        failureClass: ModelRoutingFailureClass,
        strategy: FallbackStrategy,
        toolExecutionOccurred: Bool,
        hasCommittedToolCheckpoint: Bool = false,
        currentRetryCount: Int = 0,
        maxRetries: Int = 2,
        baseRetryDelay: Double = 0.5
    ) -> RoutingDecision {
        if failureClass == .cancellation {
            return .stop(reason: "User cancelled request")
        }
        if case .providerContentFiltered = failureClass { return .stop(reason: "Provider filtered the response") }
        if toolExecutionOccurred {
            if hasCommittedToolCheckpoint,
               strategy == .limited,
               case .providerInvocation(_, let isTransient, _) = failureClass,
               isTransient {
                if currentRetryCount < maxRetries {
                    let nextAttempt = currentRetryCount + 1
                    let delay = baseRetryDelay * Double(nextAttempt)
                    return .retryCurrent(attempt: nextAttempt, delaySeconds: delay, reason: "Retrying transient provider error from committed tool checkpoint")
                } else {
                    return .stop(reason: "Fallback suppressed because tool side effects already occurred")
                }
            }
            return .stop(reason: "Fallback suppressed because tool side effects already occurred")
        }
        switch failureClass {
        case .providerContentFiltered: return .stop(reason: "Provider filtered the response")
        case .contextCapacity:
            return .fallbackNext(reason: "Context capacity failure")
        case .providerContextOverflow:
            return .fallbackNext(reason: "Provider context overflow")
        case .harness:
            return .stop(reason: "Harness internal error")
        case .toolExecution:
            return .stop(reason: "Tool execution or permission failure")
        case .cancellation:
            return .stop(reason: "User cancelled request")
        case .providerRateLimit:
            return .fallbackNext(reason: "Immediate fallback for provider rate limit (HTTP 429)")
        case .permanentProviderRejection:
            return .fallbackNext(reason: "Immediate fallback for permanent provider rejection")
        case .providerInvocation(_, let isTransient, _):
            if isTransient {
                switch strategy {
                case .always:
                    return .fallbackNext(reason: "Always strategy: immediate fallback on transient provider error")
                case .limited:
                    if currentRetryCount < maxRetries {
                        let nextAttempt = currentRetryCount + 1
                        let delay = baseRetryDelay * Double(nextAttempt)
                        return .retryCurrent(attempt: nextAttempt, delaySeconds: delay, reason: "Limited strategy: retrying transient error")
                    } else {
                        return .fallbackNext(reason: "Limited strategy: retries exhausted (\(maxRetries)) for current member, advancing fallback")
                    }
                }
            } else {
                return .fallbackNext(reason: "Immediate fallback for non-transient provider rejection")
            }
        }
    }

    static func isFallbackAllowed(
        failureClass: ModelRoutingFailureClass,
        strategy: FallbackStrategy,
        toolExecutionOccurred: Bool
    ) -> (allowed: Bool, suppressedReason: String?) {
        let decision = decide(
            failureClass: failureClass,
            strategy: strategy,
            toolExecutionOccurred: toolExecutionOccurred,
            currentRetryCount: 999,
            maxRetries: 0
        )
        switch decision {
        case .fallbackNext, .retryCurrent:
            return (true, nil)
        case .stop(let reason):
            return (false, reason)
        }
    }
}
