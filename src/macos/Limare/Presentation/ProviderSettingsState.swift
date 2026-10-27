import SwiftUI
import Observation

// MARK: - Presentation Types

enum ProviderOperationState: Equatable, Sendable {
    case idle
    case saving
    case connecting
    case fetchingModels
    case refreshingModels
    case authenticating

    var isWorking: Bool {
        self != .idle
    }

    var label: String {
        switch self {
        case .idle: ""
        case .saving: String(localized: "Saving settings…")
        case .connecting: String(localized: "Connecting to provider…")
        case .fetchingModels: String(localized: "Discovering models…")
        case .refreshingModels: String(localized: "Refreshing models…")
        case .authenticating: String(localized: "Waiting for browser authorization…")
        }
    }
}

enum ModelDiscoveryStatus: Equatable, Sendable {
    case notRequested
    case loaded(count: Int)
    case empty
    case failed(message: String)
}

struct UserFacingError: Equatable, Identifiable, Sendable {
    let id = UUID()
    let explanation: String
    let recommendedAction: String?
    let technicalDetails: String?

    init(explanation: String, recommendedAction: String? = nil, technicalDetails: String? = nil) {
        self.explanation = explanation
        self.recommendedAction = recommendedAction
        self.technicalDetails = technicalDetails
    }
}

struct ProviderHeaderRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var value: String
    var isLegacyReserved: Bool

    init(id: UUID = UUID(), name: String, value: String, isLegacyReserved: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isLegacyReserved = isLegacyReserved
    }
}

// MARK: - Provider Settings State (Layer 2 Presentation Model)

@Observable
@MainActor
final class ProviderSettingsState {
    var selection: UUID?
    var isNew: Bool = false
    var draft: ProviderConfiguration = .empty()
    var pendingAPIKey: String?
    var modelSearchText: String = ""
    var activeOperation: ProviderOperationState = .idle
    var discoveryStatus: ModelDiscoveryStatus = .notRequested
    var userError: UserFacingError?
    var userStatusMessage: String?
    var isAdvancedExpanded: Bool = false
    var headerRows: [ProviderHeaderRow] = []

    // Sheets
    var inspectingModel: ProviderModel?
    var quickTestingModel: ProviderModel?
    var showAddCustomModel: Bool = false
    var pendingDeletionID: UUID?

    // Async safety & synchronization
    private var operationTask: Task<Void, Never>?
    private var currentOpToken: UUID = UUID()
    private var lastSyncedHeadersProviderID: UUID?

    init() {}

    func selectPreset(_ identity: ProviderIdentity) {
        guard isNew else { return }
        cancelOperation()
        draft.providerIdentity = identity
        draft.name = identity == .custom ? "" : identity.displayName
        draft.baseURL = identity.defaultBaseURL
        draft.modelsURL = nil
        draft.protocolAdapter = identity.defaultProtocol
        draft.appendV1Suffix = identity != .gemini
        draft.authenticationSelection = .legacy(.bearer)
        draft.hasStoredSecret = false
        draft.models = identity == .kimiCode ? ProviderOfficialCatalog.kimiModels : []
        draft.selectedModelID = ""
        pendingAPIKey = ""
    }

    /// A protocol change keeps the acquisition only while the policy still offers it for that protocol.
    func selectProtocol(_ format: ProviderAPIFormat) {
        draft.protocolAdapter = format
        let allowed = ProviderProductPolicy.acquisitions(for: draft.providerIdentity, protocol: format)
        if !allowed.contains(draft.authenticationSelection.acquisitionMethod), let fallback = allowed.first {
            selectAcquisition(fallback)
        }
    }

    func selectAcquisition(_ method: CredentialAcquisitionMethod) {
        cancelOperation()
        let kind: ProviderCredentialKind = switch method {
        case .manualAPIKey, .vendorWebAPIKey: .apiKey
        case .authorizationCodePKCE: .oauthAccessToken
        case .azureAPIKey: .azureAPIKey
        case .none: .none
        }
        let id = method == .vendorWebAPIKey ? "openrouter-web-key" : method == .authorizationCodePKCE ? "chatgpt-account" : "legacy-api-key"
        draft.authenticationSelection = .init(credentialKind: kind, acquisitionMethod: method, authenticationIdentityID: id)
        draft.hasStoredSecret = false
        pendingAPIKey = nil
    }

    func authenticate(store: ProviderStore, newAccount: Bool = false) {
        if newAccount { draft.authenticationSelection.authenticationIdentityID = "account-" + UUID().uuidString.lowercased() }

        cancelOperation()
        let snapshot = draft
        let token = currentOpToken
        activeOperation = .authenticating
        operationTask = Task { [weak self] in
            do {
                let result = try await store.authenticate(snapshot)
                guard let self, !Task.isCancelled, self.currentOpToken == token, self.draft.id == snapshot.id else { return }
                self.draft = result
                self.isNew = false
                self.selection = result.id
                self.userStatusMessage = String(localized: "Account authorized. Fetch models to choose one.")
                self.activeOperation = .idle
            } catch {
                guard let self, !Task.isCancelled, self.currentOpToken == token else { return }
                self.userError = UserFacingError(explanation: error.localizedDescription)
                self.activeOperation = .idle
            }
        }
    }

    func logout(store: ProviderStore) {
        do {
            try store.logout(providerID: draft.id, selection: draft.authenticationSelection)
            draft.hasStoredSecret = false
            userStatusMessage = String(localized: "This authentication identity was disconnected. Other credentials were preserved.")
        } catch { userError = UserFacingError(explanation: error.localizedDescription) }
    }

    // MARK: - Filtered Models

    var filteredModels: [ProviderModel] {
        let trimmed = modelSearchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return draft.models }
        let query = trimmed.lowercased()
        return draft.models.filter {
            $0.displayName.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var normalizedAPIKey: String? {
        guard let pendingAPIKey else { return nil }
        let trimmed = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var headerValidationError: String? {
        var seen = Set<String>()
        for row in headerRows {
            let trimmed = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return String(localized: "Header name cannot be empty.")
            }
            if trimmed.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) {
                return String(localized: "Header name '\(trimmed)' contains illegal characters (colons or newlines).")
            }
            if ProviderRequestConfigurator.isReservedHeader(trimmed) && !row.isLegacyReserved {
                return String(localized: "'\(trimmed)' is a reserved header name managed by Harness.")
            }
            let lower = trimmed.lowercased()
            if seen.contains(lower) {
                return String(localized: "Duplicate header name '\(trimmed)'.")
            }
            seen.insert(lower)
            if row.value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
                return String(localized: "Header value for '\(trimmed)' contains newlines.")
            }
        }
        return nil
    }

    var legacyReservedWarning: String? {
        let legacyNames = headerRows.filter { $0.isLegacyReserved && ProviderRequestConfigurator.isReservedHeader($0.name) }.map { $0.name }
        if !legacyNames.isEmpty {
            return String(localized: "Legacy reserved headers present (\(legacyNames.joined(separator: ", "))). Handled according to system precedence.")
        }
        return nil
    }

    var canConnectOrSave: Bool {
        let hasName = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSecret = draft.authenticationMode == .none
            || draft.hasStoredSecret
            || !(pendingAPIKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasSecret && headerValidationError == nil && !activeOperation.isWorking
    }

    // MARK: - Lifecycle & Selection

    func selectInitialProvider(store: ProviderStore) {
        guard selection == nil else { return }
        selection = store.selectedProviderID ?? store.providers.first?.id
        loadSelection(store: store)
    }

    func selectProvider(id: UUID?, store: ProviderStore) {
        guard selection != id else { return }
        selection = id
        loadSelection(store: store)
    }

    func beginNewProvider() {
        cancelOperation()
        draft = .empty()
        pendingAPIKey = ""
        modelSearchText = ""
        isNew = true
        activeOperation = .idle
        selection = draft.id
        userError = nil
        userStatusMessage = nil
        discoveryStatus = .notRequested
        syncDraftToHeaders()
    }

    func loadSelection(store: ProviderStore) {
        cancelOperation()
        guard let selection else { return }
        if isNew && selection == draft.id { return }
        guard let provider = store.providers.first(where: { $0.id == selection }) else { return }
        draft = provider
        pendingAPIKey = nil
        modelSearchText = ""
        activeOperation = .idle
        draft.hasStoredSecret = store.hasStoredAPIKey(providerID: provider.id)
        isNew = false
        userError = nil
        userStatusMessage = nil
        discoveryStatus = provider.models.isEmpty ? .notRequested : .loaded(count: provider.models.count)
        syncDraftToHeaders()
    }

    // MARK: - Async Operations

    func connect(store: ProviderStore) {
        guard canConnectOrSave else { return }
        syncHeadersToDraft()

        let targetID = draft.id
        let providerSnapshot = draft
        let submittedKey = normalizedAPIKey
        let opToken = UUID()
        currentOpToken = opToken

        activeOperation = .connecting
        userError = nil
        userStatusMessage = nil

        // Step 1: Persist configuration and credentials
        do {
            try store.save(providerSnapshot, apiKey: submittedKey)
        } catch {
            // Case A: Save failure
            self.userError = UserFacingError(
                explanation: String(localized: "Provider settings could not be saved."),
                recommendedAction: String(localized: "Check that the Provider name and Base URL are valid, and try saving again."),
                technicalDetails: error.localizedDescription
            )
            self.activeOperation = .idle
            return
        }

        // Persist succeeded: commit presentation state
        self.isNew = false
        self.selection = targetID
        self.pendingAPIKey = nil
        if let saved = store.providers.first(where: { $0.id == targetID }) {
            self.draft.models = saved.models
        }
        self.draft.hasStoredSecret = store.hasStoredAPIKey(providerID: targetID)
        self.activeOperation = .fetchingModels

        // Step 2: Discover models
        operationTask?.cancel()
        operationTask = Task {
            do {
                let models = try await store.discoverModels(provider: providerSnapshot, apiKey: submittedKey)

                guard !Task.isCancelled, self.currentOpToken == opToken, self.selection == targetID else { return }

                self.updateDraft(with: models)
                self.discoveryStatus = models.isEmpty ? .empty : .loaded(count: models.count)

                var updated = providerSnapshot
                updated.lastDiscovery = store.providers.first(where: { $0.id == targetID })?.lastDiscovery
                self.draft.lastDiscovery = updated.lastDiscovery
                updated.models = self.draft.models
                updated.selectedModelID = self.draft.selectedModelID
                try? store.save(updated, apiKey: nil)

                self.userStatusMessage = models.isEmpty
                    ? String(localized: "Provider connected. The models endpoint returned no model IDs.")
                    : String(localized: "Provider connected and \(models.count) models discovered.")
                if updated.providerIdentity == .kimiCode { self.userStatusMessage = String(localized: "Loaded four official Kimi models (2026-10-08). Account access requires Quick Test; catalog loading does not verify it.") }
                if updated.lastDiscovery?.completeness?.isComplete == false { self.userStatusMessage = String(localized: "The provider list may be incomplete. Existing models and settings were preserved.") }
                self.activeOperation = .idle
            } catch is CancellationError {
                return
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                guard !Task.isCancelled, self.currentOpToken == opToken, self.selection == targetID else { return }

                // Case B: Save succeeded, but model discovery failed
                self.discoveryStatus = .failed(message: error.localizedDescription)
                self.userError = UserFacingError(
                    explanation: String(localized: "Provider settings were saved, but models could not be discovered."),
                    recommendedAction: String(localized: "Check your endpoint URL, authentication mode, or network connection. You can retry discovery or add models manually."),
                    technicalDetails: error.localizedDescription
                )
                self.activeOperation = .idle
            }
        }
    }

    func saveChanges(store: ProviderStore) {
        guard canConnectOrSave else { return }
        syncHeadersToDraft()

        let providerSnapshot = draft
        let submittedKey = normalizedAPIKey
        activeOperation = .saving
        userError = nil
        userStatusMessage = nil

        do {
            try store.save(providerSnapshot, apiKey: submittedKey)
            isNew = false
            selection = providerSnapshot.id
            pendingAPIKey = nil
            if let saved = store.providers.first(where: { $0.id == providerSnapshot.id }) {
                draft.models = saved.models
            }
            draft.hasStoredSecret = store.hasStoredAPIKey(providerID: providerSnapshot.id)
            userStatusMessage = String(localized: "Provider settings saved.")
        } catch {
            draft.hasStoredSecret = store.hasStoredAPIKey(providerID: draft.id)
            userError = UserFacingError(
                explanation: String(localized: "Failed to save provider settings."),
                recommendedAction: String(localized: "Verify required fields and try saving again."),
                technicalDetails: error.localizedDescription
            )
        }
        activeOperation = .idle
    }

    func refreshModels(store: ProviderStore) {
        guard !activeOperation.isWorking else { return }
        syncHeadersToDraft()

        let targetID = draft.id
        let providerSnapshot = draft
        let submittedKey = normalizedAPIKey
        let opToken = UUID()
        currentOpToken = opToken

        activeOperation = .refreshingModels
        userError = nil
        userStatusMessage = nil

        operationTask?.cancel()
        operationTask = Task {
            do {
                let models = try await store.discoverModels(provider: providerSnapshot, apiKey: submittedKey)

                guard !Task.isCancelled, self.currentOpToken == opToken, self.selection == targetID, self.draft.id == targetID else { return }

                self.updateDraft(with: models)
                self.discoveryStatus = models.isEmpty ? .empty : .loaded(count: models.count)

                var updated = providerSnapshot
                updated.lastDiscovery = store.providers.first(where: { $0.id == targetID })?.lastDiscovery
                self.draft.lastDiscovery = updated.lastDiscovery
                updated.models = self.draft.models
                updated.selectedModelID = self.draft.selectedModelID
                try store.save(updated, apiKey: submittedKey)

                if submittedKey != nil {
                    self.pendingAPIKey = nil
                }
                self.draft.hasStoredSecret = store.hasStoredAPIKey(providerID: targetID)
                self.userStatusMessage = models.isEmpty
                    ? String(localized: "The models endpoint returned no model IDs.")
                    : String(localized: "Fetched and enriched \(models.count) models.")
                if updated.providerIdentity == .kimiCode { self.userStatusMessage = String(localized: "Loaded four official Kimi models (2026-10-08). Account access requires Quick Test; catalog loading does not verify it.") }
                if updated.lastDiscovery?.completeness?.isComplete == false { self.userStatusMessage = String(localized: "The provider list may be incomplete. Existing models and settings were preserved.") }
                self.activeOperation = .idle
            } catch is CancellationError {
                return
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                guard !Task.isCancelled, self.currentOpToken == opToken, self.selection == targetID, self.draft.id == targetID else { return }

                self.draft.hasStoredSecret = store.hasStoredAPIKey(providerID: targetID)
                self.discoveryStatus = .failed(message: error.localizedDescription)
                self.userError = UserFacingError(
                    explanation: String(localized: "Failed to refresh models."),
                    recommendedAction: String(localized: "Check your connection or API Key and try again."),
                    technicalDetails: error.localizedDescription
                )
                self.activeOperation = .idle
            }
        }
    }

    func addCustomModel(model: ProviderModel, store: ProviderStore) {
        var enriched = model
        enriched = ModelsDevAPI.enrichModel(
            baseURL: draft.baseURL,
            appendV1Suffix: draft.appendV1Suffix,
            identity: draft.providerIdentity,
            protocolAdapter: draft.protocolAdapter,
            model: enriched
        )
        draft.models.append(enriched)
        if draft.selectedModelID.isEmpty {
            draft.selectedModelID = enriched.id
        }
        if !isNew {
            try? store.addCustomModel(providerID: draft.id, model: enriched)
        }
        discoveryStatus = .loaded(count: draft.models.count)
        showAddCustomModel = false
        inspectingModel = enriched
    }

    func updateModel(model: ProviderModel, store: ProviderStore) {
        if let idx = draft.models.firstIndex(where: { $0.id == model.id }) {
            draft.models[idx] = model
            if !isNew {
                try? store.updateModel(providerID: draft.id, model: model)
            }
        }
        inspectingModel = nil
    }

    func deleteCustomModel(model: ProviderModel, store: ProviderStore) {
        draft.models.removeAll { $0.id == model.id }
        if draft.selectedModelID == model.id {
            draft.selectedModelID = draft.models.first?.id ?? ""
        }
        if !isNew {
            try? store.deleteModel(providerID: draft.id, modelID: model.id)
        }
        discoveryStatus = draft.models.isEmpty ? .empty : .loaded(count: draft.models.count)
        inspectingModel = nil
    }

    func deleteProvider(id: UUID, store: ProviderStore) {
        cancelOperation()
        do {
            try store.delete(providerID: id)
            pendingDeletionID = nil
            selection = store.selectedProviderID ?? store.providers.first?.id
            if selection == nil { draft = .empty() }
            loadSelection(store: store)
        } catch {
            userError = UserFacingError(
                explanation: String(localized: "Failed to delete provider."),
                recommendedAction: String(localized: "Try again or check permissions."),
                technicalDetails: error.localizedDescription
            )
        }
    }

    func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        currentOpToken = UUID()
        activeOperation = .idle
    }

    // MARK: - Private Helpers

    private func updateDraft(with models: [ProviderModel]) {
        draft.models = models
        if draft.selectedModelID.isEmpty {
            draft.selectedModelID = models.first?.id ?? ""
        }
    }

    private func syncDraftToHeaders() {
        if lastSyncedHeadersProviderID != draft.id {
            headerRows = draft.extraHeaders.map {
                let isReserved = ProviderRequestConfigurator.isReservedHeader($0.key)
                return ProviderHeaderRow(name: $0.key, value: $0.value, isLegacyReserved: isReserved)
            }
            .sorted(by: { $0.name < $1.name })
            lastSyncedHeadersProviderID = draft.id
        }
    }

    func syncHeadersToDraft() {
        var clean: [String: String] = [:]
        for row in headerRows {
            let trimmed = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                clean[trimmed] = row.value
            }
        }
        draft.extraHeaders = clean
    }
}
