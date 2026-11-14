import Foundation
import Observation

struct QuotaAmount: Identifiable, Sendable {
    var id: String { label + "|" + currency }
    var label: String
    var value: Decimal?
    var currency: String
    var unlimited = false
    var text: String? = nil
    var subtitle: String? = nil
    var usedFraction: Double? = nil
}

struct QuotaPart: Sendable {
    var amounts: [QuotaAmount]
    var updatedAt: Date = Date()
    var insufficient = false
}

struct ProviderQuotaState {
    var account: QuotaPart?
    var key: QuotaPart?
    var accountError: String?
    var keyError: String?
    var accountPermissionDenied = false
    var unsupported = false
    var loading = false
}

enum QuotaFailure: LocalizedError, Sendable, Equatable {
    case unsupported, missingCredential, unauthorized, forbidden, notFound, rateLimited, timedOut, tooLarge, invalidResponse, business, network
    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Remote balance is not supported for this provider.")
        case .missingCredential: String(localized: "A saved API key is required to query balance.")
        case .unauthorized: String(localized: "The credential cannot access this endpoint (HTTP 401).")
        case .forbidden: String(localized: "The credential lacks permission for this endpoint (HTTP 403).")
        case .notFound: String(localized: "The balance endpoint was not found (HTTP 404).")
        case .rateLimited: String(localized: "The balance service is rate limited (HTTP 429).")
        case .timedOut: String(localized: "The balance request timed out.")
        case .tooLarge: String(localized: "The balance response exceeded 1 MiB.")
        case .invalidResponse: String(localized: "The balance service returned an invalid response.")
        case .business: String(localized: "The balance service reported an error.")
        case .network: String(localized: "The balance request failed. Check the connection and try again.")
        }
    }
}

@MainActor @Observable
final class ProviderQuotaService {
    private(set) var states: [UUID: ProviderQuotaState] = [:]
    @ObservationIgnored private let providers: ProviderStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var relayKinds: [UUID: RelayKind] = [:]
    private var generations: [UUID: Int] = [:]

    enum RelayKind { case sub2api, newAPIOrBilling }

    init(providers: ProviderStore, session: URLSession? = nil) {
        self.providers = providers
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    func state(for id: UUID) -> ProviderQuotaState { states[id] ?? ProviderQuotaState() }
    func generation(for id: UUID) -> Int { generations[id, default: 0] }

    func invalidate(providerID: UUID) {
        generations[providerID, default: 0] += 1
        tasks.removeValue(forKey: providerID)?.cancel()
        relayKinds.removeValue(forKey: providerID)
        states.removeValue(forKey: providerID)
    }

    func refresh(_ provider: ProviderConfiguration, force: Bool = false) async {
        if let task = tasks[provider.id] { await task.value; return }
        guard let kind = Self.kind(provider) else {
            states[provider.id] = ProviderQuotaState(unsupported: true)
            return
        }
        let old = state(for: provider.id)
        let newest = [old.account?.updatedAt, old.key?.updatedAt].compactMap { $0 }.max()
        if !force, let newest, Date().timeIntervalSince(newest) < 600 { return }
        let generation = generations[provider.id, default: 0]
        var loading = old; loading.loading = true; states[provider.id] = loading
        let task = Task { [weak self] in
            guard let self else { return }
            let token: String
            do { token = try await self.providers.resolveCredential(providerID: provider.id) }
            catch {
                guard self.generations[provider.id, default: 0] == generation else { return }
                var state = self.state(for: provider.id); state.loading = false
                state.accountError = QuotaFailure.missingCredential.localizedDescription
                if kind == .openRouter { state.keyError = QuotaFailure.missingCredential.localizedDescription }
                self.states[provider.id] = state; return
            }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                guard self.generations[provider.id, default: 0] == generation else { return }
                var state = self.state(for: provider.id); state.loading = false
                state.accountError = QuotaFailure.missingCredential.localizedDescription
                self.states[provider.id] = state; return
            }
            let management = try? self.providers.managementKey(providerID: provider.id)
            var account: Result<QuotaPart, QuotaFailure>?
            var key: Result<QuotaPart, QuotaFailure>?
            var unsupportedRelay = false
            switch kind {
            case .deepSeek:
                account = await Self.fetch(provider, path: "/user/balance", key: token, session: self.session, parser: .deepSeek)
            case .moonshot:
                account = await Self.fetch(provider, path: "/v1/users/me/balance", key: token, session: self.session, parser: .moonshot)
            case .openRouter:
                async let keyResult = Self.fetch(provider, path: "/api/v1/key", key: token, session: self.session, parser: .routerKey)
                async let accountResult = Self.fetch(provider, path: "/api/v1/credits", key: management ?? token, session: self.session, parser: .routerCredits)
                let (acc, k) = await (accountResult, keyResult)
                account = acc; key = k
            case .codexSubscription:
                account = await Self.fetchCodexSubscription(provider, resolvedToken: token, session: self.session)
            case .relay:
                let hint = self.relayKinds[provider.id]
                let outcome = await Self.fetchRelay(provider, key: token, session: self.session, hint: hint)
                if let matched = outcome.matchedKind { self.relayKinds[provider.id] = matched }
                account = outcome.account; key = outcome.key; unsupportedRelay = outcome.unsupported
            }
            guard !Task.isCancelled, self.generations[provider.id, default: 0] == generation else { return }
            if unsupportedRelay {
                self.states[provider.id] = ProviderQuotaState(unsupported: true)
                return
            }
            var state = self.state(for: provider.id); state.loading = false; state.unsupported = false
            let anySucceeded = (try? account?.get()) != nil || (try? key?.get()) != nil
            if let account {
                switch account {
                case .success(let part): state.account = part; state.accountError = nil; state.accountPermissionDenied = false
                case .failure(let error):
                    state.accountError = error.localizedDescription
                    state.accountPermissionDenied = error == .unauthorized || error == .forbidden
                }
            } else if anySucceeded {
                state.account = nil; state.accountError = nil; state.accountPermissionDenied = false
            }
            if let key {
                switch key {
                case .success(let part): state.key = part; state.keyError = nil
                case .failure(let error): state.keyError = error.localizedDescription
                }
            } else if anySucceeded {
                state.key = nil; state.keyError = nil
            }
            self.states[provider.id] = state
        }
        tasks[provider.id] = task
        await task.value
        if generations[provider.id, default: 0] == generation { tasks[provider.id] = nil }
    }

    enum Kind: Equatable { case deepSeek, moonshot, openRouter, codexSubscription, relay }
    enum Parser { case deepSeek, moonshot, routerKey, routerCredits, codexUsage, sub2api, newAPIToken, openAIBilling(usage: [String: Any]?) }

    private static let officialUnsupportedHosts: Set<String> = [
        "api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com",
        "api.siliconflow.cn", "api.siliconflow.com", "api.x.ai",
        "api.minimax.io", "api.minimaxi.com", "api.xiaomimimo.com",
        "api.kimi.com", "api.kimi.ai", "dashscope.aliyuncs.com",
        "ark.cn-beijing.volces.com", "open.bigmodel.cn"
    ]

    static func kind(_ provider: ProviderConfiguration) -> Kind? {
        if provider.authenticationSelection.credentialKind == .oauthAccessToken {
            guard let c = URLComponents(string: provider.baseURL),
                  c.scheme?.lowercased() == "https",
                  c.user == nil, c.password == nil,
                  c.host?.lowercased() == "api.openai.com" else { return nil }
            return .codexSubscription
        }
        guard provider.authenticationSelection.credentialKind == .apiKey,
              let c = URLComponents(string: provider.baseURL),
              let scheme = c.scheme?.lowercased(), (scheme == "https" || scheme == "http"),
              c.user == nil, c.password == nil, let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        switch host {
        case "api.deepseek.com": return scheme == "https" ? .deepSeek : nil
        case "api.moonshot.cn", "api.moonshot.ai": return scheme == "https" ? .moonshot : nil
        case "openrouter.ai": return scheme == "https" ? .openRouter : nil
        default:
            if officialUnsupportedHosts.contains(host) { return nil }
            return relayRoot(provider) != nil ? .relay : nil
        }
    }

    static func relayRoot(_ provider: ProviderConfiguration) -> URL? {
        var raw = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        if raw.lowercased().hasSuffix("/v1") { raw.removeLast(3) }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var c = URLComponents(string: raw),
              let scheme = c.scheme?.lowercased(), (scheme == "https" || scheme == "http"),
              c.user == nil, c.password == nil, let host = c.host, !host.isEmpty else { return nil }
        c.query = nil; c.fragment = nil
        return c.url
    }

    static func relayEndpoint(_ provider: ProviderConfiguration, path: String) -> URL? {
        guard let root = relayRoot(provider), var c = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        let subPath = path.hasPrefix("/") ? path : "/" + path
        c.path = basePath + subPath
        return c.url
    }

    static func endpoint(_ provider: ProviderConfiguration, path: String) -> URL? {
        guard let k = kind(provider) else { return nil }
        if k == .relay { return relayEndpoint(provider, path: path) }
        if k == .codexSubscription {
            let subPath = path.hasPrefix("/") ? path : "/" + path
            return URL(string: "https://chatgpt.com" + subPath)
        }
        guard var c = URLComponents(string: provider.baseURL) else { return nil }
        c.path = path; c.query = nil; c.fragment = nil
        return c.url
    }

    private struct CodexQuotaCredential: Sendable {
        var token: String
        var accountID: String?
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func extractAccountID(from claims: [String: Any]) -> String? {
        if let direct = claims["chatgpt_account_id"] as? String, !direct.isEmpty { return direct }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let nested = auth["chatgpt_account_id"] as? String, !nested.isEmpty {
            return nested
        }
        return nil
    }

    private static func resolveCodexCredential(resolvedToken: String, session: URLSession) async -> CodexQuotaCredential {
        guard let claims = decodeJWTPayload(resolvedToken) else {
            return CodexQuotaCredential(token: resolvedToken, accountID: nil)
        }
        if let accountID = extractAccountID(from: claims) {
            return CodexQuotaCredential(token: resolvedToken, accountID: accountID)
        }
        let authURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if let data = try? Data(contentsOf: authURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = root["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty {
            let storedAccountID = tokens["account_id"] as? String
            let codexClaims = decodeJWTPayload(accessToken)
            let derivedAccountID = storedAccountID ?? codexClaims.flatMap(extractAccountID(from:))
            if let exp = (codexClaims?["exp"] as? NSNumber)?.doubleValue,
               Date().timeIntervalSince1970 + 60 < exp {
                return CodexQuotaCredential(token: accessToken, accountID: derivedAccountID)
            }
            if let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty,
               let tokenURL = URL(string: "https://auth.openai.com/oauth/token") {
                var request = URLRequest(url: tokenURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: String] = [
                    "grant_type": "refresh_token",
                    "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
                    "refresh_token": refreshToken,
                    "scope": "openid profile email offline_access",
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                if let (respData, resp) = try? await session.data(for: request, delegate: TransportMetricsRecorder(restrictToOriginalOrigin: true)),
                   let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let refreshed = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                   let newAccess = refreshed["access_token"] as? String, !newAccess.isEmpty {
                    let refreshedAccountID = decodeJWTPayload(newAccess).flatMap(extractAccountID(from:)) ?? derivedAccountID
                    return CodexQuotaCredential(token: newAccess, accountID: refreshedAccountID)
                }
            }
        }
        return CodexQuotaCredential(token: resolvedToken, accountID: nil)
    }

    private static func fetchCodexSubscription(_ provider: ProviderConfiguration, resolvedToken: String, session: URLSession) async -> Result<QuotaPart, QuotaFailure> {
        let cred = await resolveCodexCredential(resolvedToken: resolvedToken, session: session)
        var headers = [
            "User-Agent": "codex_cli_rs/0.159.0 (macOS; arm64)",
            "Originator": "codex_cli_rs",
        ]
        if let accountID = cred.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return await fetch(provider, path: "/backend-api/wham/usage", key: cred.token, extraHeaders: headers, session: session, parser: .codexUsage)
    }

    private struct RelayOutcome {
        var account: Result<QuotaPart, QuotaFailure>?
        var key: Result<QuotaPart, QuotaFailure>?
        var matchedKind: RelayKind?
        var unsupported = false
    }

    private static func fetchRelay(_ provider: ProviderConfiguration, key: String, session: URLSession, hint: RelayKind?) async -> RelayOutcome {
        var errors: [QuotaFailure] = []
        if hint == nil || hint == .sub2api {
            let sub2 = await fetch(provider, path: "/v1/usage", key: key, session: session, parser: .sub2api)
            switch sub2 {
            case .success:
                return RelayOutcome(account: sub2, key: nil, matchedKind: .sub2api)
            case .failure(let err):
                if hint == .sub2api { return RelayOutcome(account: .failure(err), key: nil, matchedKind: .sub2api) }
                errors.append(err)
            }
        }
        async let tokenResult = fetch(provider, path: "/api/usage/token", key: key, session: session, parser: .newAPIToken)
        async let billingTask = fetchBilling(provider, key: key, session: session)
        let (tokenQuota, billingResult) = await (tokenResult, billingTask)
        let billingOK = (try? billingResult.get()) != nil
        let tokenOK = (try? tokenQuota.get()) != nil
        if billingOK || tokenOK {
            return RelayOutcome(
                account: billingOK ? billingResult : nil,
                key: tokenOK ? tokenQuota : nil,
                matchedKind: .newAPIOrBilling
            )
        }
        if case .failure(let e1) = billingResult { errors.append(e1) }
        if case .failure(let e2) = tokenQuota { errors.append(e2) }
        if hint == .newAPIOrBilling {
            return RelayOutcome(account: billingResult, key: nil, matchedKind: .newAPIOrBilling)
        }
        if let transient = errors.first(where: { $0 == .timedOut || $0 == .rateLimited || $0 == .tooLarge }) {
            return RelayOutcome(account: .failure(transient))
        }
        if let firstAuth = errors.first, !errors.isEmpty, errors.allSatisfy({ $0 == .unauthorized || $0 == .forbidden }) {
            return RelayOutcome(account: .failure(firstAuth))
        }
        return RelayOutcome(unsupported: true)
    }

    private static func fetchBilling(_ provider: ProviderConfiguration, key: String, session: URLSession) async -> Result<QuotaPart, QuotaFailure> {
        switch await fetchJSON(provider, path: "/v1/dashboard/billing/subscription", key: key, session: session) {
        case .success(let sub):
            let usageJSON = try? await fetchJSON(provider, path: "/v1/dashboard/billing/usage", key: key, session: session).get()
            do { return .success(try parse(sub, parser: .openAIBilling(usage: usageJSON))) }
            catch let err as QuotaFailure { return .failure(err) }
            catch { return .failure(.invalidResponse) }
        case .failure(let err):
            return .failure(err)
        }
    }

    private static func fetchJSON(_ provider: ProviderConfiguration, path: String, key: String, extraHeaders: [String: String] = [:], session: URLSession) async -> Result<[String: Any], QuotaFailure> {
        guard let url = endpoint(provider, path: path) else { return .failure(.unsupported) }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        ProviderRequestConfigurator.configureBearerHeaders(request: &request, provider: provider, apiKey: key)
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request, delegate: TransportMetricsRecorder(restrictToOriginalOrigin: true))
            guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
            switch http.statusCode {
            case 200..<300: break
            case 401: return .failure(.unauthorized)
            case 403: return .failure(.forbidden)
            case 404: return .failure(.notFound)
            case 429: return .failure(.rateLimited)
            default: return .failure(.network)
            }
            guard data.count <= 1_048_576 else { return .failure(.tooLarge) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(.invalidResponse) }
            return .success(json)
        } catch let error as QuotaFailure { return .failure(error) }
        catch let error as URLError where error.code == .timedOut { return .failure(.timedOut) }
        catch { return .failure(.network) }
    }

    private static func fetch(_ provider: ProviderConfiguration, path: String, key: String, extraHeaders: [String: String] = [:], session: URLSession, parser: Parser) async -> Result<QuotaPart, QuotaFailure> {
        switch await fetchJSON(provider, path: path, key: key, extraHeaders: extraHeaders, session: session) {
        case .success(let json):
            do { return .success(try parse(json, parser: parser)) }
            catch let error as QuotaFailure { return .failure(error) }
            catch { return .failure(.invalidResponse) }
        case .failure(let error):
            return .failure(error)
        }
    }

    static func parse(_ json: [String: Any], parser: Parser) throws -> QuotaPart {
        func decimal(_ value: Any?) -> Decimal? {
            if let number = value as? NSNumber { return number.decimalValue }
            if let value = value as? String { return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) }
            return nil
        }
        func roundUSD(_ value: Decimal) -> Decimal {
            var input = value
            var output = Decimal()
            let scale: Int16 = (value > 0 && value < Decimal(string: "0.01")!) ? 4 : 2
            NSDecimalRound(&output, &input, Int(scale), .plain)
            return output
        }
        func amount(_ label: String, _ value: Any?, _ currency: String) -> QuotaAmount {
            QuotaAmount(label: label, value: decimal(value), currency: currency)
        }
        switch parser {
        case .deepSeek:
            guard let rows = json["balance_infos"] as? [[String: Any]], !rows.isEmpty else { throw QuotaFailure.invalidResponse }
            let amounts = rows.flatMap { row -> [QuotaAmount] in
                let currency = row["currency"] as? String ?? ""
                return [amount(String(localized: "Available balance"), row["total_balance"], currency),
                        amount(String(localized: "Granted balance"), row["granted_balance"], currency),
                        amount(String(localized: "Topped-up balance"), row["topped_up_balance"], currency)]
            }
            return QuotaPart(amounts: amounts, insufficient: json["is_available"] as? Bool == false)
        case .moonshot:
            if let code = json["code"], !(code is NSNull), decimal(code) != 0 { throw QuotaFailure.business }
            if let status = json["status"] as? Bool, !status { throw QuotaFailure.business }
            guard let data = json["data"] as? [String: Any] else { throw QuotaFailure.invalidResponse }
            let currency = json["currency"] as? String ?? data["currency"] as? String ?? ""
            return QuotaPart(amounts: [amount(String(localized: "Available balance"), data["available_balance"], currency),
                                       amount(String(localized: "Cash balance"), data["cash_balance"], currency),
                                       amount(String(localized: "Voucher balance"), data["voucher_balance"], currency)])
        case .routerKey:
            guard let data = json["data"] as? [String: Any] else { throw QuotaFailure.invalidResponse }
            var limit = amount(String(localized: "Key limit"), data["limit"], "USD")
            limit.unlimited = data.keys.contains("limit") && data["limit"] is NSNull
            var values = [amount(String(localized: "Key usage"), data["usage"], "USD"), limit,
                          amount(String(localized: "Key remaining"), data["limit_remaining"], "USD")]
            for (field, label) in [("usage_daily", String(localized: "Today")), ("usage_weekly", String(localized: "This week")),
                                   ("usage_monthly", String(localized: "This month"))] where data[field] != nil {
                values.append(amount(label, data[field], "USD"))
            }
            return QuotaPart(amounts: values)
        case .routerCredits:
            guard let data = json["data"] as? [String: Any] else { throw QuotaFailure.invalidResponse }
            let credits = decimal(data["total_credits"]); let used = decimal(data["total_usage"])
            let balance = credits.flatMap { c in used.map { c - $0 } }
            return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Account balance"), value: balance, currency: "USD"),
                                       amount(String(localized: "Total credits"), data["total_credits"], "USD"),
                                       amount(String(localized: "Total account usage"), data["total_usage"], "USD")])
        case .codexUsage:
            var amounts: [QuotaAmount] = []
            if let rawPlan = (json["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPlan.isEmpty {
                let planDisplay = switch rawPlan.lowercased() {
                case "plus": "ChatGPT Plus"
                case "pro": "ChatGPT Pro"
                case "team": "ChatGPT Team"
                case "enterprise": "ChatGPT Enterprise"
                case "edu": "ChatGPT Edu"
                case "free": "ChatGPT Free"
                default: "ChatGPT (\(rawPlan.capitalized))"
                }
                amounts.append(QuotaAmount(label: String(localized: "Subscription plan"), value: nil, currency: "plan", text: planDisplay))
            }
            var hasQuotaData = false
            var insufficient = false
            func windowTitle(_ key: String, _ w: [String: Any], prefix: String?) -> String {
                let base: String
                if let seconds = decimal(w["limit_window_seconds"]).map({ NSDecimalNumber(decimal: $0).intValue }), seconds > 0 {
                    switch seconds {
                    case 18000: base = String(localized: "5-hour window")
                    case 604800: base = String(localized: "7-day window")
                    default:
                        let minutes = max(1, seconds / 60)
                        if minutes % 1440 == 0 { base = "\(minutes / 1440)d" }
                        else if minutes % 60 == 0 { base = "\(minutes / 60)h" }
                        else { base = "\(minutes)m" }
                    }
                } else {
                    base = key == "primary_window" ? String(localized: "5-hour window") : String(localized: "7-day window")
                }
                if let prefix, !prefix.isEmpty { return "\(prefix) · \(base)" }
                return base
            }
            func appendWindows(from rateLimit: [String: Any], prefix: String?) {
                for key in ["primary_window", "secondary_window"] {
                    guard let w = rateLimit[key] as? [String: Any], let used = decimal(w["used_percent"]) else { continue }
                    let remaining = max(0, Decimal(100) - used)
                    let usedStr = NSDecimalNumber(decimal: used).stringValue
                    let remStr = NSDecimalNumber(decimal: remaining).stringValue
                    let text = String(format: String(localized: "%@%% used (%@%% remaining)"), usedStr, remStr)
                    let resetDate: Date? = {
                        if let at = decimal(w["reset_at"]) {
                            return Date(timeIntervalSince1970: NSDecimalNumber(decimal: at).doubleValue)
                        }
                        if let after = decimal(w["reset_after_seconds"]) {
                            return Date().addingTimeInterval(NSDecimalNumber(decimal: after).doubleValue)
                        }
                        return nil
                    }()
                    let subtitle = resetDate.map { String(format: String(localized: "Resets %@"), $0.formatted(date: .abbreviated, time: .shortened)) }
                    let usedFraction = min(max(NSDecimalNumber(decimal: used).doubleValue / 100.0, 0), 1)
                    amounts.append(QuotaAmount(label: windowTitle(key, w, prefix: prefix), value: remaining, currency: "%", text: text, subtitle: subtitle, usedFraction: usedFraction))
                    hasQuotaData = true
                }
            }
            if let rl = json["rate_limit"] as? [String: Any] {
                appendWindows(from: rl, prefix: nil)
                if (rl["limit_reached"] as? Bool) == true || (rl["allowed"] as? Bool) == false {
                    insufficient = true
                }
            }
            for extra in (json["additional_rate_limits"] as? [[String: Any]]) ?? [] {
                guard let name = extra["limit_name"] as? String, !name.isEmpty,
                      let rl = extra["rate_limit"] as? [String: Any] else { continue }
                appendWindows(from: rl, prefix: name)
            }
            if let credits = json["credits"] as? [String: Any], (credits["has_credits"] as? Bool) == true {
                let unlimited = (credits["unlimited"] as? Bool) == true
                let balance = decimal(credits["balance"])
                if balance != nil || unlimited {
                    amounts.append(QuotaAmount(label: String(localized: "Credits"), value: balance, currency: "credits", unlimited: unlimited))
                    hasQuotaData = true
                }
            }
            guard hasQuotaData else { throw QuotaFailure.invalidResponse }
            return QuotaPart(amounts: amounts, insufficient: insufficient)
        case .sub2api:
            guard json["isValid"] is Bool else { throw QuotaFailure.invalidResponse }
            let insufficient = (json["isValid"] as? Bool) == false
            let keyUsed = ((json["usage"] as? [String: Any])?["total"] as? [String: Any]).flatMap { decimal($0["actual_cost"]) }
            if (json["mode"] as? String) == "quota_limited" {
                let q = json["quota"] as? [String: Any] ?? [:]
                let limit = decimal(q["limit"])
                let remaining = decimal(q["remaining"]).map { max(0, $0) }
                let used = json["quota"] != nil ? decimal(q["used"]) : keyUsed
                guard remaining != nil || limit != nil else { throw QuotaFailure.invalidResponse }
                return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Available balance"), value: remaining, currency: "USD"),
                                           QuotaAmount(label: String(localized: "Key limit"), value: limit, currency: "USD"),
                                           QuotaAmount(label: String(localized: "Key usage"), value: used, currency: "USD")],
                                 insufficient: insufficient)
            } else if json.keys.contains("balance") {
                guard let balance = decimal(json["balance"]) else { throw QuotaFailure.invalidResponse }
                return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Available balance"), value: balance, currency: "USD")],
                                 insufficient: insufficient)
            } else {
                guard let remaining = decimal(json["remaining"]) else { throw QuotaFailure.invalidResponse }
                if remaining < 0 {
                    let limit = QuotaAmount(label: String(localized: "Key limit"), value: nil, currency: "USD", unlimited: true)
                    return QuotaPart(amounts: [limit, QuotaAmount(label: String(localized: "Key usage"), value: keyUsed, currency: "USD")],
                                     insufficient: insufficient)
                }
                return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Available balance"), value: remaining, currency: "USD"),
                                           QuotaAmount(label: String(localized: "Key usage"), value: keyUsed, currency: "USD")],
                                 insufficient: insufficient)
            }
        case .newAPIToken:
            guard let data = json["data"] as? [String: Any],
                  data["total_granted"] != nil || data["total_available"] != nil else { throw QuotaFailure.invalidResponse }
            let granted = decimal(data["total_granted"])
            let used = decimal(data["total_used"])
            let available = decimal(data["total_available"])
            let unlimited = (data["unlimited_quota"] as? Bool) == true || (granted.map { $0 < 0 } ?? false)
            if unlimited {
                let limit = QuotaAmount(label: String(localized: "Key limit"), value: nil, currency: "quota", unlimited: true)
                return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Key usage"), value: used, currency: "quota"), limit])
            }
            return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Key remaining"), value: available, currency: "quota"),
                                       QuotaAmount(label: String(localized: "Key usage"), value: used, currency: "quota"),
                                       QuotaAmount(label: String(localized: "Key limit"), value: granted, currency: "quota")])
        case .openAIBilling(let usage):
            let sub = (json["data"] as? [String: Any]) ?? json
            let use = (usage?["data"] as? [String: Any]) ?? usage ?? [:]
            let usedUSD = decimal(use["total_usage"]).map { roundUSD($0 / 100) } ?? decimal(use["used_usd"]).map(roundUSD)
            if let balance = decimal(sub["balance"]).map(roundUSD) {
                var amounts = [QuotaAmount(label: String(localized: "Available balance"), value: balance, currency: "USD")]
                if let usedUSD { amounts.append(QuotaAmount(label: String(localized: "Total account usage"), value: usedUSD, currency: "USD")) }
                return QuotaPart(amounts: amounts)
            } else if let hard = decimal(sub["hard_limit_usd"]).map(roundUSD) {
                if hard >= 100_000_000 {
                    let limit = QuotaAmount(label: String(localized: "Total credits"), value: nil, currency: "USD", unlimited: true)
                    return QuotaPart(amounts: [limit, QuotaAmount(label: String(localized: "Total account usage"), value: usedUSD, currency: "USD")])
                }
                let remaining = usedUSD.map { max(0, roundUSD(hard - $0)) }
                return QuotaPart(amounts: [QuotaAmount(label: String(localized: "Available balance"), value: remaining, currency: "USD"),
                                           QuotaAmount(label: String(localized: "Total credits"), value: hard, currency: "USD"),
                                           QuotaAmount(label: String(localized: "Total account usage"), value: usedUSD, currency: "USD")])
            }
            throw QuotaFailure.invalidResponse
        }
    }
}
