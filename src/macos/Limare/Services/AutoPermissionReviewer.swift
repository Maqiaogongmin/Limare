import Foundation


@MainActor
final class AutoPermissionReviewer: PermissionReviewing {
    private let client: any ProviderClient
    private let providerResolver: (@MainActor () -> (provider: ProviderConfiguration, apiKey: String, modelID: String)?)?
    private let staticContext: PermissionReviewContext?
    private let logs: DebugLogStore
    private let timeoutSeconds: TimeInterval

    init(
        client: any ProviderClient = OpenAICompatibleClient(),
        providerResolver: @escaping @MainActor () -> (provider: ProviderConfiguration, apiKey: String, modelID: String)?,
        logs: DebugLogStore,
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.client = client
        self.providerResolver = providerResolver
        self.staticContext = nil
        self.logs = logs
        self.timeoutSeconds = timeoutSeconds
    }

    init(
        context: PermissionReviewContext,
        client: any ProviderClient = OpenAICompatibleClient(),
        logs: DebugLogStore,
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.client = client
        self.providerResolver = nil
        self.staticContext = context
        self.logs = logs
        self.timeoutSeconds = timeoutSeconds
    }

    func review(request: ToolPermissionRequest, reason: String) async -> AutoReviewDecision {
        let resolved = staticContext.map { ($0.provider, $0.apiKey, $0.modelID) } ?? providerResolver?()
        guard let (provider, apiKey, modelID) = resolved else {
            logs.info("Permission", "Auto-reviewer: no active provider configured; delegating to human.")
            return .needsUserReview(reason: String(localized: "No active model provider configured for auto-review"))
        }
        guard !apiKey.isEmpty else {
            logs.info("Permission", "Auto-reviewer: active provider lacks API key; delegating to human.")
            return .needsUserReview(reason: String(localized: "Active model provider lacks API key for auto-review"))
        }

        let sanitizedBaseURL: String = {
            if let comp = URLComponents(string: provider.baseURL),
               let scheme = comp.scheme, let host = comp.host {
                var safeComp = URLComponents()
                safeComp.scheme = scheme
                safeComp.host = host
                safeComp.path = comp.path
                if let port = comp.port { safeComp.port = port }
                return safeComp.string ?? "\(scheme)://\(host)\(comp.path)"
            }
            return provider.name
        }()

        logs.info("Permission", "Auto-reviewer reviewing request using provider '\(provider.name)' endpoint '\(sanitizedBaseURL)' model '\(modelID)' (turnContext: \(staticContext != nil ? "bound" : "ambient")).")

        let systemPrompt = """
        You are an automated security reviewer for a macOS coding assistant.
        Your task is to review a requested tool action that crosses normal workspace or safety boundaries.
        Analyze whether this action appears safe, routine, and constructive, or if it poses risks of data loss, credential theft, unintended network communication, or system disruption.

        Respond with ONLY a JSON object in this exact schema:
        {
          "decision": "approve" | "deny" | "user_review",
          "rationale": "one sentence explanation"
        }
        Do not output any markdown formatting, backticks, or extra text.
        """

        var details: [String: String] = [
            "tool": request.toolName,
            "summary": request.summary,
            "boundary_reason": reason,
            "requests_network": request.requestsNetwork ? "true" : "false",
            "is_high_risk": request.isHighRisk ? "true" : "false"
        ]
        if let cmd = request.reviewerSafeCommand ?? request.command {
            // Ensure any active provider API key or literal secrets are also redacted
            let safeCmd = SecretMasker.redact(cmd, secrets: [apiKey].filter { !$0.isEmpty })
            details["command"] = safeCmd
        }
        if !request.affectedURLs.isEmpty {
            details["affected_paths"] = request.affectedURLs.map(\.path).joined(separator: ", ")
        }
        if !request.environmentKeys.isEmpty {
            details["environment_keys"] = request.environmentKeys.joined(separator: ", ")
        }
        if let ws = request.workspaceURL {
            details["workspace_path"] = ws.path
        }

        guard let payloadData = try? JSONSerialization.data(withJSONObject: details, options: [.sortedKeys]),
              let payloadStr = String(data: payloadData, encoding: .utf8) else {
            return .needsUserReview(reason: String(localized: "Failed to serialize review payload"))
        }

        let messages = [
            ChatRequestMessage(role: "system", content: systemPrompt),
            ChatRequestMessage(role: "user", content: "Review this action:\n\(payloadStr)")
        ]

        let client = self.client
        let timeout = self.timeoutSeconds
        do {
            return try await withThrowingTaskGroup(of: AutoReviewDecision.self) { group in
                group.addTask {
                    var fullResponse = ""
                    let stream = client.streamChat(
                        provider: provider,
                        apiKey: apiKey,
                        modelID: modelID,
                        messages: messages,
                        tools: []
                    )
                    for try await event in stream {
                        if case .textDelta(let delta) = event {
                            fullResponse += delta
                        }
                    }
                    return Self.parseDecision(fullResponse)
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return .needsUserReview(reason: String(localized: "Auto-review timed out after \(Int(timeout))s"))
                }

                guard let first = try await group.next() else {
                    return .needsUserReview(reason: String(localized: "No response from reviewer"))
                }
                group.cancelAll()
                return first
            }
        } catch {
            logs.info("Permission", "Auto-reviewer call failed with error: \(error.localizedDescription)")
            return .needsUserReview(reason: String(localized: "Reviewer error: \(error.localizedDescription)"))
        }
    }

    nonisolated static func parseDecision(_ text: String) -> AutoReviewDecision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var clean = trimmed
        if clean.hasPrefix("```") {
            let lines = clean.components(separatedBy: "\n")
            clean = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = clean.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let decisionStr = json["decision"] as? String else {
            return .needsUserReview(reason: String(localized: "Failed to parse reviewer JSON response"))
        }
        let rationale = (json["rationale"] as? String) ?? "Auto-review completed."
        switch decisionStr.lowercased() {
        case "approve":
            return .approve(rationale: rationale)
        case "deny":
            return .deny(rationale: rationale)
        case "user_review":
            return .needsUserReview(reason: rationale)
        default:
            return .needsUserReview(reason: String(localized: "Unrecognized decision '\(decisionStr)' from reviewer"))
        }
    }
}
