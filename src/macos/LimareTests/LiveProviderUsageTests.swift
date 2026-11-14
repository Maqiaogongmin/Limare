import XCTest
@testable import Limare

/// Explicit opt-in only. Requests are minimal, and the isolated ledger and credential copy are removed afterwards.
@MainActor
final class LiveProviderUsageTests: XCTestCase {
    func testAvailableAccounts() async throws {
        guard ProcessInfo.processInfo.environment["LIMARE_LIVE"] == "1" else { throw XCTSkip("Set LIMARE_LIVE=1 for real provider checks.") }
        let fm = FileManager.default
        guard let sourcePath = ProcessInfo.processInfo.environment["LIMARE_LIVE_ROOT"] else {
            throw XCTSkip("Set LIMARE_LIVE_ROOT to the Limare data directory for real provider checks.")
        }
        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let directory = fm.temporaryDirectory.appendingPathComponent("limare-live-usage-\(UUID().uuidString)")
        try fm.createDirectory(at: directory.appendingPathComponent("secrets"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let providerData = try Data(contentsOf: source.appendingPathComponent("providers.json"))
        let configurations = try JSONDecoder().decode(ProviderConfigurationFile.self, from: providerData)
        let selectedIDs = Set(configurations.providers.filter { provider in
            let host = URLComponents(string: provider.baseURL)?.host?.lowercased() ?? ""
            return provider.authenticationSelection.credentialKind == .apiKey
                && (host == "api.deepseek.com" || host == "generativelanguage.googleapis.com" || provider.apiFormat == .chatCompletions)
        }.map { $0.id.uuidString })
        try providerData.write(to: directory.appendingPathComponent("providers.json"))
        let secretCopy = directory.appendingPathComponent("secrets/provider-secrets.json")
        let sourceSecrets = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: source.appendingPathComponent("secrets/provider-secrets.json")))
        let selectedSecrets = sourceSecrets.filter { $0.key == ProviderSecretStore.versionKey || selectedIDs.contains($0.key) }
        try JSONEncoder().encode(selectedSecrets).write(to: secretCopy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretCopy.path)
        let logs = DebugLogStore(storageRootURL: directory)
        let status = UsageRecordingStatus()
        let recorder = try UsageRecorder(storageRootURL: directory, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45; config.urlCache = nil
        let session = URLSession(configuration: config)
        let store = ProviderStore(storageRootURL: directory, client: OpenAICompatibleClient(session: session).recordingUsage(recorder), logs: logs)
        let quota = ProviderQuotaService(providers: store, session: session)
        var results: [String: String] = [:]
        for provider in store.providers {
            let host = URLComponents(string: provider.baseURL)?.host?.lowercased() ?? ""
            guard selectedIDs.contains(provider.id.uuidString) else { continue }
            if host == "api.deepseek.com" {
                await quota.refresh(provider, force: true)
                let snapshot = quota.state(for: provider.id)
                if let part = snapshot.account, let endpoint = ProviderQuotaService.endpoint(provider, path: "/user/balance"),
                   let key = try? await store.resolveCredential(providerID: provider.id) {
                    var request = URLRequest(url: endpoint)
                    ProviderRequestConfigurator.configureBearerHeaders(request: &request, provider: provider, apiKey: key)
                    do {
                        let (data, response) = try await session.data(for: request, delegate: TransportMetricsRecorder(restrictToOriginalOrigin: true))
                        if (response as? HTTPURLResponse)?.statusCode == 200,
                           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let rows = json["balance_infos"] as? [[String: Any]],
                           let raw = rows.first?["total_balance"] as? String,
                           let balance = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) {
                            results["deepseek_balance"] = part.amounts.first?.value == balance ? "matched" : "mismatch"
                        } else { results["deepseek_balance"] = "independent response unavailable" }
                    } catch { results["deepseek_balance"] = "independent request failed" }
                } else { results["deepseek_balance"] = "unavailable: \(snapshot.accountError ?? "no data")" }
            }
            let preferred: [String]
            switch host {
            case "generativelanguage.googleapis.com": preferred = ["gemini-flash-latest", "gemini-3.5-flash"]
            case "api.deepseek.com": preferred = []
            default: preferred = ["gpt-6.1-sol", "minimax-m3"]
            }
            let ids = [provider.selectedModelID] + preferred
            var seen = Set<String>()
            let candidates = ids.compactMap { id -> ProviderModel? in
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                return provider.models.first(where: { $0.id == id })
            }
            guard !candidates.isEmpty else {
                results[host] = "no model"; continue
            }
            for model in candidates {
                let resultKey = host + "/" + model.id
                do {
                    let key = try await store.resolveCredential(providerID: provider.id)
                    let capture = UsageAttemptCapture()
                    let stream = store.networkClient.streamChat(provider: provider, apiKey: key, modelID: model.id,
                        messages: [ChatRequestMessage(role: "user", content: "Reply with OK.")],
                        options: ChatInferenceOptions(thinkingLevel: .off, maxOutputTokens: 64, model: model, usageKind: .quickTest),
                        onDiagnostics: { capture.update($0) })
                    for try await _ in stream {}
                    let report = try await recorder.report(since: nil, kind: .quickTest, providerID: provider.id)
                    let usage = NormalizedUsage.from(capture.diagnostics?.usage, format: provider.apiFormat, finished: capture.diagnostics?.completedReceived == true)
                    if report.totals.requests > 0, usage.status == .complete {
                        results[resultKey] = "received complete usage"; break
                    }
                    results[resultKey] = usage.status == .partial ? "received partial usage" : "request completed without usage"
                } catch let error as ProviderClientError {
                    if case .http(let code, let message) = error {
                        let lower = message.lowercased()
                        results[resultKey] = code == 404 && lower.contains("model") && lower.contains("not found") ? "HTTP 404 model not found" : "HTTP \(code)"
                    } else { results[resultKey] = "provider stream failed" }
                } catch { results[resultKey] = "request failed" }
            }
        }
        let output = URL(fileURLWithPath: "/tmp/limare-live-usage-acceptance.json")
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
