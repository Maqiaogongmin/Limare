import Foundation
import Observation

enum ProviderStoreError: LocalizedError, Equatable {
    case nameRequired
    case apiKeyRequired
    case apiKeyReplacementRequired
    case modelRequired
    case providerNotFound
    case duplicateModelID(String)
    case invalidHeader(String)

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            "Provider name is required."
        case .apiKeyRequired:
            "API key is required."
        case .apiKeyReplacementRequired:
            "The saved API key is unavailable. Open Settings → Providers and save it once in Limare private storage."
        case .modelRequired:
            "Select a model or enter a model ID."
        case .providerNotFound:
            "The selected provider no longer exists."
        case .duplicateModelID(let id):
            "A model with ID '\(id)' already exists in this provider."
        case .invalidHeader(let message):
            message
        }
    }
}

@MainActor
@Observable
final class ProviderStore {
    private(set) var providers: [ProviderConfiguration] = []
    private var isLoading = false
    var selectedProviderID: UUID? {
        didSet { if !isLoading { persist() } }
    }

    private let fileURL: URL
    private let secretStore: any SecretStoring
    private let client: OpenAICompatibleClient
    private let logs: DebugLogStore
    private var credentialStorageFailure: Error?
    private var configurationStorageFailure: Error?
    private var openAIHostIdentity: String?
    private var authenticationControllers: [UUID: ProviderAuthenticationService] = [:]
    private var refreshTasks: [String: Task<(token: String, archive: Data), Error>] = [:]

    init(
        fileManager: FileManager = .default,
        storageRootURL: URL? = nil,
        secretStore: (any SecretStoring)? = nil,
        client: OpenAICompatibleClient = OpenAICompatibleClient(),
        logs: DebugLogStore
    ) {
        let root = storageRootURL
            ?? LimareStorage.applicationSupport
                .appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        fileURL = root.appendingPathComponent("providers.json")
        self.secretStore = secretStore ?? ProviderSecretStore(storageRootURL: root, fileManager: fileManager)
        self.client = client
        self.logs = logs
        // Migration occurs after metadata is read, before credentials can be used.
        load()
        NotificationCenter.default.addObserver(
            forName: ModelsDevAPI.didRefreshNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                let networkSnapshot = ModelsDevAPI.loadRegistrySnapshot()
                self?.refreshModelCapabilities(snapshot: networkSnapshot)
            }
        }
        let bootstrapSnapshot = ModelsDevAPI.startFreshnessLifecycle()
        refreshModelCapabilities(snapshot: bootstrapSnapshot)
    }

    var networkClient: OpenAICompatibleClient {
        client.resolvingCredentials { [weak self] provider in
            guard let self else { throw ProviderStoreError.providerNotFound }
            let current = await self.providers.first(where: { $0.id == provider.id })
            guard current?.authenticationSelection == provider.authenticationSelection,
                  current?.protocolAdapter == provider.protocolAdapter,
                  current?.baseURL == provider.baseURL else { throw ProviderCredentialStorageError.concurrentIdentityChange }
            let token = try await self.resolveCredential(providerID: provider.id)
            let after = await self.providers.first(where: { $0.id == provider.id })
            guard after?.authenticationSelection == provider.authenticationSelection,
                  after?.protocolAdapter == provider.protocolAdapter,
                  after?.baseURL == provider.baseURL else { throw ProviderCredentialStorageError.concurrentIdentityChange }
            return token
        }
    }

    func resolveCredential(providerID: UUID) async throws -> String {
        if let credentialStorageFailure { throw credentialStorageFailure }
        guard let provider = providers.first(where: { $0.id == providerID }) else { throw ProviderStoreError.providerNotFound }
        try ProviderProductPolicy.validate(provider)
        guard provider.authenticationSelection.credentialKind == .oauthAccessToken else { return try apiKey(providerID: providerID) }
        guard let vault = secretStore as? ProviderSecretStore,
              var slot = try vault.slot(providerID: providerID, selection: provider.authenticationSelection),
              let archive = slot.oauthStateArchive,
              slot.oauthRegistration?.grantedScopes.contains("chatgpt.tokens.use.direct") == true else {
            throw ProviderCredentialStorageError.credentialMissing
        }
        let selection = provider.authenticationSelection
        let key = providerID.uuidString + ":" + selection.authenticationIdentityID
        let task: Task<(token: String, archive: Data), Error>
        let ownsTask = refreshTasks[key] == nil
        defer { if ownsTask { refreshTasks[key] = nil } }
        if let current = refreshTasks[key] { task = current }
        else {
            task = Task { try await ProviderAuthenticationService.freshToken(archive: archive) }
            refreshTasks[key] = task
        }
        let refreshed = try await task.value
        try Task.checkCancellation()
        guard providers.first(where: { $0.id == providerID })?.authenticationSelection == selection else {
            throw ProviderCredentialStorageError.concurrentIdentityChange
        }
        let current = try vault.slot(providerID: providerID, selection: selection)
        if current?.revision != slot.revision {
            guard let currentArchive = current?.oauthStateArchive else { throw ProviderCredentialStorageError.concurrentIdentityChange }
            return try ProviderAuthenticationService.currentToken(archive: currentArchive)
        }
        if refreshed.archive != archive {
            let revision = slot.revision
            slot.oauthStateArchive = refreshed.archive
            slot.revision += 1
            try vault.saveSlot(slot, providerID: providerID, selection: selection, expectedRevision: revision)
        }
        return refreshed.token
    }

    func authenticate(_ draft: ProviderConfiguration) async throws -> ProviderConfiguration {
        if let configurationStorageFailure { throw configurationStorageFailure }
        if let credentialStorageFailure { throw credentialStorageFailure }
        try ProviderProductPolicy.validate(draft)
        guard let vault = secretStore as? ProviderSecretStore else { throw ProviderAuthenticationError.unavailable }
        let old = providers.first(where: { $0.id == draft.id })
        let expected = try vault.slot(providerID: draft.id, selection: draft.authenticationSelection)
        let controller = ProviderAuthenticationService(selection: draft.authenticationSelection)
        cancelAuthentication(providerID: draft.id)
        authenticationControllers[draft.id] = controller
        defer { if authenticationControllers[draft.id] === controller { authenticationControllers[draft.id] = nil } }
        if draft.authenticationSelection.acquisitionMethod == .authorizationCodePKCE, openAIHostIdentity == nil {
            openAIHostIdentity = "urn:uuid:" + UUID().uuidString.lowercased()
            do { try persistSnapshot(providers: providers, selectedProviderID: selectedProviderID) }
            catch { openAIHostIdentity = nil; throw error }
        }
        let result = try await controller.authenticate(provider: draft, hostID: openAIHostIdentity ?? "", registration: expected?.oauthRegistration)
        try Task.checkCancellation()
        guard authenticationControllers[draft.id] === controller,
              providers.first(where: { $0.id == draft.id }) == old else {
            throw ProviderCredentialStorageError.concurrentIdentityChange
        }
        var slot: ProviderCredentialSlot
        if let key = result.apiKey {
            slot = ProviderCredentialSlot(apiKey: key, acquisition: .vendorWebAPIKey, revision: (expected?.revision ?? 0) + 1)
        } else if let archive = result.archive, let registration = result.registration {
            slot = ProviderCredentialSlot(archive: archive, registration: registration, revision: (expected?.revision ?? 0) + 1)
        } else { throw ProviderAuthenticationError.failedExchange }
        if let display = result.accountDisplay { slot.providerMetadata["accountDisplay"] = display }
        try vault.saveSlot(slot, providerID: draft.id, selection: draft.authenticationSelection, expectedRevision: expected?.revision)
        var updated = draft
        updated.hasStoredSecret = true
        do { try save(updated, apiKey: nil) }
        catch {
            do { try vault.restoreSlot(expected, providerID: draft.id, selection: draft.authenticationSelection, expectedRevision: slot.revision) }
            catch { credentialStorageFailure = error }
            throw error
        }
        return updated
    }

    func cancelAuthentication(providerID: UUID) {
        authenticationControllers.removeValue(forKey: providerID)?.cancel()
        for key in refreshTasks.keys.filter({ $0.hasPrefix(providerID.uuidString + ":") }) {
            refreshTasks.removeValue(forKey: key)?.cancel()
        }
    }

    func logout(providerID: UUID, selection: ProviderAuthenticationSelection? = nil) throws {
        guard let i = providers.firstIndex(where: { $0.id == providerID }), let vault = secretStore as? ProviderSecretStore else {
            throw ProviderStoreError.providerNotFound
        }
        let selected = selection ?? providers[i].authenticationSelection
        if authenticationControllers[providerID]?.selection == selected {
            authenticationControllers.removeValue(forKey: providerID)?.cancel()
        }
        refreshTasks.removeValue(forKey: providerID.uuidString + ":" + selected.authenticationIdentityID)?.cancel()
        try vault.logout(providerID: providerID, selection: selected)
        let stillConnected = try vault.slot(providerID: providerID, selection: providers[i].authenticationSelection) != nil
        if providers[i].hasStoredSecret != stillConnected {
            providers[i].hasStoredSecret = stillConnected
            persist()
        }
    }

    func hasCredential(providerID: UUID, selection: ProviderAuthenticationSelection) -> Bool {
        guard credentialStorageFailure == nil else { return false }
        if selection.credentialKind == .none { return true }
        if let vault = secretStore as? ProviderSecretStore {
            return (try? vault.slot(providerID: providerID, selection: selection)) != nil
        }
        return (try? secretStore.load(providerID: providerID))?.isEmpty == false
    }

    func authenticationSummary(providerID: UUID, selection: ProviderAuthenticationSelection) -> String? {
        guard let vault = secretStore as? ProviderSecretStore,
              let slot = try? vault.slot(providerID: providerID, selection: selection) else { return nil }
        // The OAuth subject is an opaque account ID: it is never shown, so it cannot pass for a secret.
        if let display = slot.providerMetadata["accountDisplay"] { return display }
        if let archive = slot.oauthStateArchive {
            return ProviderAuthenticationService.accountEmail(archive: archive) ?? "ChatGPT account"
        }
        return slot.apiKey == nil ? nil : "API Key stored"
    }

    var selectedProvider: ProviderConfiguration? {
        providers.first { $0.id == selectedProviderID }
    }

    func hasStoredAPIKey(providerID: UUID) -> Bool {
        providers.first { $0.id == providerID }?.hasStoredSecret ?? false
    }

    func apiKey(providerID: UUID) throws -> String {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            throw ProviderStoreError.providerNotFound
        }
        return try credential(for: provider)
    }

    /// The stored API Key of exactly this identity, for display. Never returns an OAuth token.
    func storedAPIKey(providerID: UUID, selection: ProviderAuthenticationSelection) throws -> String {
        if let credentialStorageFailure { throw credentialStorageFailure }
        guard [.apiKey, .azureAPIKey].contains(selection.credentialKind) else {
            throw ProviderConnectionError.invalidCredentialRoute
        }
        let key: String?
        if let vault = secretStore as? ProviderSecretStore {
            key = try vault.slot(providerID: providerID, selection: selection)?.apiKey
        } else {
            key = try secretStore.load(providerID: providerID)
        }
        guard let key, !key.isEmpty else { throw ProviderStoreError.apiKeyRequired }
        return key
    }

    /// Resolves the credential this configuration selects. An unsaved draft resolves its own
    /// selection and is validated as edited, so a saved OAuth slot never reaches a draft endpoint.
    func credential(for provider: ProviderConfiguration) throws -> String {
        let providerID = provider.id
        if let credentialStorageFailure { throw credentialStorageFailure }
        try ProviderProductPolicy.validate(provider)
        if provider.authenticationMode == .none {
            return ""
        }
        let selectedKey: String?
        if let vault = secretStore as? ProviderSecretStore {
            let slot = try vault.slot(providerID: providerID, selection: provider.authenticationSelection)
            if provider.authenticationSelection.credentialKind == .oauthAccessToken, let archive = slot?.oauthStateArchive {
                selectedKey = try ProviderAuthenticationService.currentToken(archive: archive)
            } else { selectedKey = slot?.apiKey }
        } else {
            selectedKey = try secretStore.load(providerID: providerID)
        }
        if let key = selectedKey, !key.isEmpty {
            return key
        }
        if let index = providers.firstIndex(where: { $0.id == providerID }), providers[index].hasStoredSecret,
           providers[index].authenticationSelection == provider.authenticationSelection {
            providers[index].hasStoredSecret = false
            persist()
            logs.error("Provider", "Saved credential is unavailable; Provider now requires a one-time secret replacement.")
            throw ProviderStoreError.apiKeyReplacementRequired
        }
        throw ProviderStoreError.apiKeyRequired
    }

    func save(_ provider: ProviderConfiguration, apiKey: String?) throws {
        if let configurationStorageFailure { throw configurationStorageFailure }
        if let credentialStorageFailure { throw credentialStorageFailure }
        var validated = provider
        validated.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        validated.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        validated.modelsURL = provider.modelsURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if validated.modelsURL?.isEmpty == true { validated.modelsURL = nil }
        // Selected wire identity is verbatim and never changed by discovery.
        validated.selectedModelID = provider.selectedModelID
        if let customUA = provider.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines) {
            validated.customUserAgent = customUA.isEmpty ? nil : customUA
        } else {
            validated.customUserAgent = nil
        }
        guard !validated.name.isEmpty else { throw ProviderStoreError.nameRequired }
        try ProviderProductPolicy.validate(validated)
        _ = try ProviderRequestConfigurator.modelsEndpoint(validated)
        _ = try EndpointBuilder.endpoint(
            baseURL: validated.baseURL,
            appendV1Suffix: validated.appendV1Suffix,
            endpoint: "models"
        )

        var cleanHeaders: [String: String] = [:]
        for (k, v) in validated.extraHeaders {
            let trimmedK = k.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedK.isEmpty else { throw ProviderStoreError.invalidHeader("Header name cannot be empty.") }
            guard !trimmedK.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) else {
                throw ProviderStoreError.invalidHeader("Header name cannot contain colons or newlines.")
            }
            guard !v.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw ProviderStoreError.invalidHeader("Header value cannot contain newlines.")
            }
            let duplicateKey = cleanHeaders.keys.first { $0.caseInsensitiveCompare(trimmedK) == .orderedSame }
            if duplicateKey != nil {
                throw ProviderStoreError.invalidHeader("Duplicate header name '\(trimmedK)'.")
            }
            cleanHeaders[trimmedK] = v
        }
        validated.extraHeaders = cleanHeaders

        let existing = providers.first(where: { $0.id == validated.id })
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let vault = secretStore as? ProviderSecretStore
        let previousSlot = try vault?.slot(providerID: validated.id, selection: validated.authenticationSelection)
        let previousLegacyKey = vault == nil ? try secretStore.load(providerID: validated.id) : nil
        var writtenSlotRevision: UInt64?
        if let trimmedKey, !trimmedKey.isEmpty {
            if let vault {
                try vault.saveKey(trimmedKey, providerID: validated.id, selection: validated.authenticationSelection)
                writtenSlotRevision = try vault.slot(providerID: validated.id, selection: validated.authenticationSelection)?.revision
            } else {
                try secretStore.save(trimmedKey, providerID: validated.id)
            }
            validated.hasStoredSecret = true
        } else if validated.authenticationMode == .none {
            validated.hasStoredSecret = false
        } else if previousSlot != nil || previousLegacyKey?.isEmpty == false {
            validated.hasStoredSecret = true
        } else {
            validated.hasStoredSecret = false
            throw ProviderStoreError.apiKeyRequired
        }

        let identityChanged: Bool
        if let existing = existing {
            identityChanged = (existing.baseURL != validated.baseURL || existing.appendV1Suffix != validated.appendV1Suffix) && !validated.models.isEmpty
        } else {
            identityChanged = !validated.models.isEmpty
        }

        if identityChanged {
            let snapshot = ModelsDevAPI.loadRegistrySnapshot()
            var reprojected: [ProviderModel] = []
            for model in validated.models {
                let enriched = ModelsDevAPI.enrichModel(
                    baseURL: validated.baseURL,
                    appendV1Suffix: validated.appendV1Suffix,
                    identity: validated.providerIdentity,
                    protocolAdapter: validated.protocolAdapter,
                    model: model,
                    snapshot: snapshot
                )
                var finalModel = enriched
                finalModel.overrides = model.overrides
                finalModel.isCustom = model.isCustom
                finalModel.isHidden = model.isHidden
                finalModel.discovery = model.discovery
                reprojected.append(finalModel)
            }
            validated.models = reprojected
        }

        var updatedProviders = providers
        if let index = updatedProviders.firstIndex(where: { $0.id == validated.id }) {
            updatedProviders[index] = validated
        } else {
            updatedProviders.append(validated)
        }
        do { try persistSnapshot(providers: updatedProviders, selectedProviderID: validated.id) }
        catch {
            if let writtenSlotRevision, let vault {
                do { try vault.restoreSlot(previousSlot, providerID: validated.id, selection: validated.authenticationSelection, expectedRevision: writtenSlotRevision) }
                catch { credentialStorageFailure = error }
            } else if let trimmedKey, !trimmedKey.isEmpty, vault == nil {
                do {
                    if let previousLegacyKey { try secretStore.save(previousLegacyKey, providerID: validated.id) }
                    else { try secretStore.delete(providerID: validated.id) }
                } catch { credentialStorageFailure = error }
            }
            throw error
        }
        providers = updatedProviders
        isLoading = true
        selectedProviderID = validated.id
        isLoading = false
        let customHeaderNames = validated.extraHeaders.keys.sorted().joined(separator: ", ")
        let headerSummary = customHeaderNames.isEmpty ? "" : " custom_headers=[\(customHeaderNames)]"
        logs.info("Provider", "Saved provider \(validated.name) (\(validated.kind.displayName)) auth=\(validated.authenticationMode.rawValue)\(headerSummary).")
    }

    func delete(providerID: UUID) throws {
        cancelAuthentication(providerID: providerID)
        try secretStore.delete(providerID: providerID)
        providers.removeAll { $0.id == providerID }
        if selectedProviderID == providerID {
            selectedProviderID = providers.first?.id
        }
        persist()
        logs.info("Provider", "Deleted provider metadata and its private credential.")
    }

    /// Discover models from provider API and enrich them with models.dev catalog data while preserving existing overrides and custom models.
    func discoverModels(
        provider: ProviderConfiguration,
        apiKey overrideAPIKey: String?
    ) async throws -> [ProviderModel] {
        try ProviderProductPolicy.validate(provider)
        if provider.providerIdentity == .kimiCode {
            let merged = ProviderOfficialCatalog.mergeKimi(existing: provider.models)
            if let index = providers.firstIndex(where: { $0.id == provider.id }) {
                providers[index].models = merged
                persist()
            }
            return merged
        }
        let key: String?
        if provider.authenticationMode == .none {
            key = nil
        } else if let overrideAPIKey, !overrideAPIKey.isEmpty {
            key = overrideAPIKey
        } else {
            key = try await resolveCredential(providerID: provider.id)
        }

        let endpoint = try ProviderRequestConfigurator.modelsEndpoint(provider)
        logs.info("Provider", "Fetching models from \(EndpointBuilder.displayPath(for: endpoint)).")
        do {
            let result = try await client.fetchModelDiscovery(provider: provider, apiKey: key)
            // A Settings draft may predate a runtime rejection. Preserve owner-held
            // discovery evidence while retaining draft user configuration.
            let storedModels = providers.first(where: { $0.id == provider.id })?.models ?? []
            var existingModels = provider.models.map { model in
                var updated = model
                if let stored = storedModels.first(where: { $0.id == model.id }) { updated.discovery = stored.discovery }
                return updated
            }
            let draftIDs = Set(existingModels.map(\.id))
            existingModels.append(contentsOf: storedModels.filter { !draftIDs.contains($0.id) })
            let completeness = Self.effectiveCompleteness(existing: existingModels, discovered: result.models, completeness: result.completeness)
            let snapshot = ModelsDevAPI.loadRegistrySnapshot()
            let merged = Self.mergeDiscoveredModels(
                existing: existingModels,
                discovered: result.models,
                completeness: completeness,
                now: result.fetchedAt,
                baseURL: provider.baseURL,
                appendV1Suffix: provider.appendV1Suffix,
                identity: provider.providerIdentity,
                protocolAdapter: provider.protocolAdapter,
                snapshot: snapshot
            )
            if let index = providers.firstIndex(where: { $0.id == provider.id }) {
                var observation = providers[index].lastDiscovery ?? ProviderDiscoveryObservation()
                observation.fetchedAt = result.fetchedAt
                observation.completeness = completeness
                observation.listedCount = Set(result.models.map(\.id)).count
                observation.lastFailureAt = nil; observation.lastFailure = nil
                providers[index].lastDiscovery = observation
                persist()
            }
            logs.info("Provider", "Fetched and enriched \(merged.count) models for \(provider.name).")
            return merged
        } catch {
            if let index = providers.firstIndex(where: { $0.id == provider.id }), !(error is CancellationError) {
                var observation = providers[index].lastDiscovery ?? ProviderDiscoveryObservation()
                observation.lastFailureAt = Date()
                observation.lastFailure = SecretMasker.redactCredentials(error.localizedDescription, secrets: key.map { [$0] } ?? [])
                providers[index].lastDiscovery = observation
                persist()
            }
            let maskingList = key.map { [$0] } ?? []
            logs.error(
                "Provider",
                "Model discovery failed for \(provider.name): \(error.localizedDescription)",
                masking: maskingList
            )
            throw error
        }
    }

    /// Pure merge function combining newly discovered API models with existing user overrides and custom models.
    static func effectiveCompleteness(existing: [ProviderModel], discovered: [ProviderModel], completeness: ModelDiscoveryCompleteness) -> ModelDiscoveryCompleteness {
        if completeness.isComplete && discovered.isEmpty && existing.contains(where: { !$0.isCustom }) { return .emptyAfterNonEmpty }
        return completeness
    }

    func recordModelRejection(providerID: UUID, modelID: String, status: Int, message: String, at: Date = Date()) {
        guard let code = ProviderModelNotFoundRecognizer.code(status: status, message: message),
              let p = providers.firstIndex(where: { $0.id == providerID }),
              let m = providers[p].models.firstIndex(where: { $0.id == modelID }), !providers[p].models[m].isCustom else { return }
        providers[p].models[m].discovery.providerRejection = ProviderModelRejection(at: at, httpStatus: status, code: code)
        persist()
    }

    func removeUnlistedModels(providerID: UUID) {
        guard let p = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[p].models.removeAll { !$0.isCustom && $0.discovery.isAbsent }
        persist()
    }

    public static func mergeDiscoveredModels(
        existing: [ProviderModel],
        discovered: [ProviderModel],
        completeness: ModelDiscoveryCompleteness = .complete,
        now: Date = Date(),
        baseURL: String,
        appendV1Suffix: Bool,
        identity: ProviderIdentity? = nil,
        protocolAdapter: ProviderAPIFormat? = nil,
        snapshot: ModelsDevAPI.RegistrySnapshot? = nil
    ) -> [ProviderModel] {
        let activeSnapshot = snapshot ?? ModelsDevAPI.loadRegistrySnapshot()
        let completeness = effectiveCompleteness(existing: existing, discovered: discovered, completeness: completeness)
        var existingByID: [String: ProviderModel] = [:]
        for m in existing {
            existingByID[m.id] = m
        }

        var result: [ProviderModel] = []
        var seenIDs: Set<String> = []

        // 1. Process discovered models
        for raw in discovered {
            let id = raw.id
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            // Enrich raw model from models.dev catalog using single snapshot
            var enriched = ModelsDevAPI.enrichModel(
                baseURL: baseURL,
                appendV1Suffix: appendV1Suffix,
                identity: identity,
                protocolAdapter: protocolAdapter,
                model: raw,
                snapshot: activeSnapshot
            )

            // Overlay existing overrides and flags if present
            if let prior = existingByID[id] {
                enriched.overrides = prior.overrides
                enriched.isHidden = prior.isHidden
                enriched.isCustom = prior.isCustom
                enriched.discovery = prior.discovery
            }
            enriched.discovery.lastSeenAt = now
            if completeness.isComplete && !enriched.isCustom {
                enriched.discovery.lastCompleteListedAt = now
                enriched.discovery.notListedSince = nil
                enriched.discovery.consecutiveMisses = 0
                enriched.discovery.providerRejection = nil
            }
            result.append(enriched)
        }

        // Only complete snapshots establish absence. User configuration survives every response.
        for prior in existing {
            if !seenIDs.contains(prior.id) {
                seenIDs.insert(prior.id)
                var preserved = prior
                if !prior.isCustom && completeness.isComplete {
                    preserved.discovery.notListedSince = preserved.discovery.notListedSince ?? now
                    preserved.discovery.consecutiveMisses += 1
                }
                result.append(preserved)
            }
        }

        return result
    }

    public static func mergeDiscoveredModels(
        existing: [ProviderModel],
        discovered: [ProviderModel],
        baseURL: String,
        snapshot: ModelsDevAPI.RegistrySnapshot? = nil
    ) -> [ProviderModel] {
        mergeDiscoveredModels(
            existing: existing,
            discovered: discovered,
            baseURL: baseURL,
            appendV1Suffix: true,
            snapshot: snapshot
        )
    }

    // MARK: - Custom Model & Overrides Management

    /// Re-evaluates model capabilities against current models.dev / catalog data
    /// while strictly preserving all explicit user overrides and custom models.
    func refreshModelCapabilities(snapshot: ModelsDevAPI.RegistrySnapshot? = nil) {
        let activeSnapshot = snapshot ?? ModelsDevAPI.loadRegistrySnapshot()
        var didChange = false
        for pIndex in providers.indices {
            let provider = providers[pIndex]
            var updatedModels: [ProviderModel] = []
            for model in provider.models {
                let enriched = ModelsDevAPI.enrichModel(
                    baseURL: provider.baseURL,
                    appendV1Suffix: provider.appendV1Suffix,
                    identity: provider.providerIdentity,
                    protocolAdapter: provider.protocolAdapter,
                    model: model,
                    snapshot: activeSnapshot
                )
                var finalModel = enriched
                finalModel.overrides = model.overrides
                finalModel.isHidden = model.isHidden
                finalModel.discovery = model.discovery
                finalModel.isCustom = model.isCustom

                if finalModel != model {
                    didChange = true
                }
                updatedModels.append(finalModel)
            }
            providers[pIndex].models = updatedModels
        }
        if didChange {
            persist()
            logs.info("Provider", "Refreshed model capabilities across \(providers.count) providers from models.dev catalog.")
        }
    }

    func addCustomModel(providerID: UUID, model: ProviderModel) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw ProviderStoreError.providerNotFound
        }
        let cleanId = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { throw ProviderStoreError.modelRequired }
        if providers[index].models.contains(where: { $0.id == cleanId }) {
            throw ProviderStoreError.duplicateModelID(cleanId)
        }

        var custom = model
        custom.isCustom = true
        // Enrich from catalog if known
        custom = ModelsDevAPI.enrichModel(
            baseURL: providers[index].baseURL,
            appendV1Suffix: providers[index].appendV1Suffix,
            identity: providers[index].providerIdentity,
            protocolAdapter: providers[index].protocolAdapter,
            model: custom
        )

        providers[index].models.append(custom)
        if providers[index].selectedModelID.isEmpty {
            providers[index].selectedModelID = cleanId
        }
        persist()
        logs.info("Provider", "Added custom model '\(cleanId)' to provider '\(providers[index].name)'.")
    }

    func updateModel(providerID: UUID, model: ProviderModel) throws {
        guard let pIndex = providers.firstIndex(where: { $0.id == providerID }) else {
            throw ProviderStoreError.providerNotFound
        }
        guard let mIndex = providers[pIndex].models.firstIndex(where: { $0.id == model.id }) else {
            throw ProviderStoreError.modelRequired
        }
        providers[pIndex].models[mIndex] = model
        persist()
        logs.info("Provider", "Updated model '\(model.id)' in provider '\(providers[pIndex].name)'.")
    }

    func deleteModel(providerID: UUID, modelID: String) throws {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { throw ProviderStoreError.providerNotFound }
        providers[index].models.removeAll { $0.id == modelID }
        // Explicit deletion leaves existing bindings for the user to resolve.
        persist()
    }

    func deleteCustomModel(providerID: UUID, modelID: String) throws {
        guard let pIndex = providers.firstIndex(where: { $0.id == providerID }) else {
            throw ProviderStoreError.providerNotFound
        }
        providers[pIndex].models.removeAll { $0.id == modelID && $0.isCustom }
        if providers[pIndex].selectedModelID == modelID {
            providers[pIndex].selectedModelID = providers[pIndex].models.first?.id ?? ""
        }
        persist()
        logs.info("Provider", "Deleted custom model '\(modelID)' from provider '\(providers[pIndex].name)'.")
    }

    func updateSelectedModel(providerID: UUID, modelID: String) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[index].selectedModelID = modelID
        persist()
    }

    func selectProvider(providerID: UUID) {
        guard providers.contains(where: { $0.id == providerID }) else { return }
        selectedProviderID = providerID
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: fileURL) else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                configurationStorageFailure = ProviderCredentialStorageError.invalidRecord
                return
            }
            if let vault = secretStore as? ProviderSecretStore {
                do { try vault.migrateLegacy(providers: []) }
                catch { credentialStorageFailure = error }
            }
            return
        }
        do {
            let file = try JSONDecoder().decode(ProviderConfigurationFile.self, from: data)
            providers = file.providers
            openAIHostIdentity = file.openAIHostIdentity
            selectedProviderID = file.selectedProviderID
            if let vault = secretStore as? ProviderSecretStore {
                do { try vault.migrateLegacy(providers: providers) }
                catch {
                    credentialStorageFailure = error
                    logs.error("Provider", "Credential migration failed; original secrets preserved.")
                    return
                }
            }
            var secretStateChanged = false
            for index in providers.indices {
                let actualHasSecret: Bool
                if let vault = secretStore as? ProviderSecretStore {
                    actualHasSecret = (try? vault.slot(providerID: providers[index].id, selection: providers[index].authenticationSelection)) != nil
                } else {
                    actualHasSecret = (try? secretStore.load(providerID: providers[index].id))?.isEmpty == false
                }
                if providers[index].hasStoredSecret != actualHasSecret {
                    providers[index].hasStoredSecret = actualHasSecret
                    secretStateChanged = true
                }
            }
            if selectedProvider == nil {
                selectedProviderID = providers.first?.id
            }
            if secretStateChanged {
                persist()
            }
        } catch {
            configurationStorageFailure = error
            logs.error("Provider", "Could not load provider configuration: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do { try persistSnapshot(providers: providers, selectedProviderID: selectedProviderID) }
        catch { logs.error("Provider", "Could not save provider configuration: \(error.localizedDescription)") }
    }

    private func persistSnapshot(providers: [ProviderConfiguration], selectedProviderID: UUID?) throws {
        if let configurationStorageFailure { throw configurationStorageFailure }
        var file = ProviderConfigurationFile(
            providers: providers,
            selectedProviderID: selectedProviderID
        )
        file.openAIHostIdentity = openAIHostIdentity
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
        )
    }
}
