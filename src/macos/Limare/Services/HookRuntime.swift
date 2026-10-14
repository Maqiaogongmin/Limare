import Foundation

@MainActor
final class HookRuntime {
    private let trustStore: HookTrustStore
    private let runner: HookCommandRunner
    private let logs: DebugLogStore

    init(
        trustStore: HookTrustStore,
        runner: HookCommandRunner? = nil,
        logs: DebugLogStore,
        storageDirectory: URL? = nil
    ) {
        self.trustStore = trustStore
        if let runner {
            self.runner = runner
        } else {
            let policy = HookContainmentPolicy(protectedStorageURL: storageDirectory)
            self.runner = HookCommandRunner(containmentPolicy: policy)
        }
        self.logs = logs
    }

    struct HookCandidate: Sendable {
        let index: Int
        let source: HookSource
        let handler: HookHandlerConfig
        let eventName: String
        let timeoutSeconds: Int
    }

    func executeEvent(
        eventName: HookEventName,
        sources: [HookSource],
        workspaceURL: URL?,
        sessionID: String,
        nativeToolName: String? = nil,
        stdinPayload: [String: Any]
    ) async -> HookAggregatedResult {
        guard eventName.isSupported else {
            logs.info("Hooks", "Hook event '\(eventName.rawValue)' is unsupported in current Limare; skipping execution.")
            return HookAggregatedResult()
        }

        var candidates: [HookCandidate] = []
        var candidateIndex = 0

        for source in sources {
            guard source.isEnabled else {
                logs.info("Hooks", "Hook source '\(source.name)' is disabled; skipping.")
                continue
            }
            guard trustStore.isTrusted(source: source) else {
                logs.info("Hooks", "Hook source '\(source.name)' is untrusted or definition changed; skipping.")
                continue
            }

            guard let matcherGroups = source.config.hooks[eventName.rawValue] else { continue }

            for group in matcherGroups {
                if let tool = nativeToolName {
                    let matchResult = HookToolCompatibility.matches(matcher: group.matcher, nativeToolName: tool)
                    switch matchResult {
                    case .success(let matched):
                        if !matched { continue }
                    case .failure(let error):
                        logs.error("Hooks", "Invalid matcher in '\(source.name)': \(error.localizedDescription)")
                        continue
                    }
                }

                for hook in group.hooks {
                    if hook.isAsync == true {
                        logs.info("Hooks", "Unsupported option 'async=true' in '\(source.name)'; skipping handler.")
                        continue
                    }

                    guard hook.type.isSupported else {
                        logs.info("Hooks", "Unsupported handler type '\(hook.type.rawValue)' in '\(source.name)'; skipping.")
                        continue
                    }

                    guard source.isHandlerRunnable(hook: hook) else {
                        if source.isHandlerConfigDisabled(hook: hook) {
                            logs.info("Hooks", "Handler is disabled by package configuration in '\(source.name)'; skipping.")
                        } else if source.isHandlerUserDisabled(id: hook.id) {
                            logs.info("Hooks", "Handler disabled by user in source '\(source.name)' for event '\(eventName.rawValue)'; skipping.")
                        }
                        continue
                    }

                    let timeout = eventName == .sessionEnd ? hook.effectiveSessionEndTimeout : hook.effectiveTimeout
                    candidates.append(HookCandidate(
                        index: candidateIndex,
                        source: source,
                        handler: hook,
                        eventName: eventName.rawValue,
                        timeoutSeconds: timeout
                    ))
                    candidateIndex += 1
                }
            }
        }

        if candidates.isEmpty {
            return HookAggregatedResult()
        }

        logs.info("Hooks", "Executing \(candidates.count) hook(s) for event '\(eventName.rawValue)'.")

        let stdinData: Data
        do {
            stdinData = try JSONSerialization.data(withJSONObject: stdinPayload, options: [.fragmentsAllowed])
        } catch {
            logs.error("Hooks", "Failed to serialize hook stdin JSON: \(error.localizedDescription)")
            return HookAggregatedResult()
        }

        let runner = self.runner
        let rawResults = await withTaskGroup(of: (Int, HookExecutionSummary).self, returning: [(Int, HookExecutionSummary)].self) { group in
            for candidate in candidates {
                group.addTask {
                    let cmd = candidate.handler.command ?? ""
                    let output = await runner.run(
                        command: cmd,
                        packageRootURL: candidate.source.packageRootURL,
                        workspaceURL: workspaceURL,
                        sessionID: sessionID,
                        stdinData: stdinData,
                        timeoutSeconds: candidate.timeoutSeconds
                    )
                    let summary = HookCommandRunner.parseExecutionResult(
                        eventName: candidate.eventName,
                        output: output,
                        handler: candidate.handler,
                        source: candidate.source
                    )
                    return (candidate.index, summary)
                }
            }

            var collected: [(Int, HookExecutionSummary)] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        // Sort by candidate index to preserve stable definition order
        let sortedSummaries = rawResults.sorted(by: { $0.0 < $1.0 }).map(\.1)

        var shouldDeny = false
        var denyReason: String?
        var shouldBlockTurn = false
        var blockTurnReason: String?
        var contextFragments: [String] = []

        for summary in sortedSummaries {
            logs.info("Hooks", "Hook completed: source='\(summary.sourceName)', event='\(summary.eventName)', exit=\(summary.exitCode), duration=\(String(format: "%.1f", summary.durationMilliseconds))ms, timeout=\(summary.isTimeout), cancelled=\(summary.isCancelled), denied=\(summary.permissionDecision == "deny").")

            if summary.permissionDecision == "deny" {
                shouldDeny = true
                if denyReason == nil {
                    denyReason = summary.permissionDecisionReason ?? "Denied by hook '\(summary.sourceName)'"
                }
                if eventName == .userPromptSubmit {
                    shouldBlockTurn = true
                    if blockTurnReason == nil {
                        blockTurnReason = summary.permissionDecisionReason ?? "Blocked by hook '\(summary.sourceName)'"
                    }
                }
            }

            if summary.continueTurn == false {
                shouldBlockTurn = true
                if blockTurnReason == nil {
                    blockTurnReason = summary.stopReason ?? "Blocked by hook '\(summary.sourceName)'"
                }
            }

            if let ctx = summary.additionalContext, !ctx.isEmpty {
                contextFragments.append(ctx)
            }
        }

        let combinedContext = contextFragments.isEmpty ? nil : contextFragments.joined(separator: "\n\n")

        return HookAggregatedResult(
            shouldDeny: shouldDeny,
            denyReason: denyReason,
            shouldBlockTurn: shouldBlockTurn,
            blockTurnReason: blockTurnReason,
            additionalContext: combinedContext,
            executions: sortedSummaries
        )
    }
}
