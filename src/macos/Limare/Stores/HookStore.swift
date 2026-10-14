import Foundation
import Observation

@MainActor
@Observable
final class HookStore {
    struct PersistedSourceMetadata: Codable {
        let id: UUID
        var name: String
        var configPath: String
        var packageRootPath: String
        var sourceKind: HookSourceKind
        var isEnabled: Bool
        var disabledHandlerIDs: [String]
    }

    private(set) var sources: [HookSource] = []
    private(set) var recentExecutions: [HookExecutionSummary] = []
    var runningStatus: String?

    let trustStore: HookTrustStore
    let runtime: HookRuntime
    private let logs: DebugLogStore
    private let storageURL: URL

    init(
        trustStore: HookTrustStore? = nil,
        logs: DebugLogStore,
        storageDirectory: URL? = nil
    ) {
        let ts = trustStore ?? HookTrustStore(storageDirectory: storageDirectory)
        self.trustStore = ts

        let directory: URL
        if let storageDirectory {
            directory = storageDirectory
        } else {
            let appSupport = LimareStorage.applicationSupport
            directory = appSupport.appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        }
        let policy = HookContainmentPolicy(protectedStorageURL: directory)
        let runner = HookCommandRunner(containmentPolicy: policy)
        self.runtime = HookRuntime(trustStore: ts, runner: runner, logs: logs, storageDirectory: directory)
        self.logs = logs

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storageURL = directory.appendingPathComponent("hook_sources.json")

        loadSources()
    }

    func isTrusted(source: HookSource) -> Bool {
        trustStore.isTrusted(source: source)
    }

    func importPackage(from targetURL: URL) throws -> HookSource {
        let source = try HookConfigLoader.loadSource(from: targetURL, sourceKind: .manualImport)
        if let existingIndex = sources.firstIndex(where: { $0.configURL.path == source.configURL.path }) {
            let existingID = sources[existingIndex].id
            let updated = HookSource(
                id: existingID,
                name: source.name,
                configURL: source.configURL,
                packageRootURL: source.packageRootURL,
                sourceKind: source.sourceKind,
                description: source.description,
                isEnabled: sources[existingIndex].isEnabled,
                disabledHandlerIDs: cleanDisabledIDs(sources[existingIndex].disabledHandlerIDs, for: source.config),
                definitionHash: source.definitionHash,
                lastLoadedAt: Date(),
                loadError: nil,
                config: source.config
            )
            sources[existingIndex] = updated
            saveSources()
            logs.info("Hooks", "Reloaded hook package '\(updated.name)' from \(updated.configURL.path).")
            return updated
        } else {
            sources.append(source)
            saveSources()
            logs.info("Hooks", "Imported hook package '\(source.name)' (Pending Review) from \(source.configURL.path).")
            return source
        }
    }

    func trustAndEnable(sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        sources[index].isEnabled = true
        trustStore.trust(source: sources[index])
        saveSources()
        logs.info("Hooks", "Trusted and enabled hook package '\(sources[index].name)'.")
    }

    func revokeTrust(sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        trustStore.revoke(source: sources[index])
        saveSources()
        logs.info("Hooks", "Revoked trust for hook package '\(sources[index].name)'.")
    }

    func toggleSource(sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        let source = sources[index]
        if !source.isEnabled && (!trustStore.isTrusted(source: source) || source.loadError != nil) {
            logs.info("Hooks", "Cannot enable untrusted or broken hook package '\(source.name)' without review.")
            return
        }
        sources[index].isEnabled.toggle()
        saveSources()
        logs.info("Hooks", "Toggled source '\(sources[index].name)' enabled=\(sources[index].isEnabled).")
    }

    func toggleHandler(sourceID: UUID, handlerID: String) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        if sources[index].disabledHandlerIDs.contains(handlerID) {
            sources[index].disabledHandlerIDs.remove(handlerID)
        } else {
            sources[index].disabledHandlerIDs.insert(handlerID)
        }
        saveSources()
        logs.info("Hooks", "Toggled handler '\(handlerID)' in '\(sources[index].name)'.")
    }

    func reloadSource(sourceID: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == sourceID }) else { return }
        let current = sources[index]
        do {
            let reloaded = try HookConfigLoader.loadSource(
                from: current.configURL,
                sourceKind: current.sourceKind,
                nameOverride: current.name
            )
            let updated = HookSource(
                id: current.id,
                name: reloaded.name,
                configURL: reloaded.configURL,
                packageRootURL: reloaded.packageRootURL,
                sourceKind: reloaded.sourceKind,
                description: reloaded.description,
                isEnabled: current.isEnabled,
                disabledHandlerIDs: cleanDisabledIDs(current.disabledHandlerIDs, for: reloaded.config),
                definitionHash: reloaded.definitionHash,
                lastLoadedAt: Date(),
                loadError: nil,
                config: reloaded.config
            )
            sources[index] = updated
            saveSources()
            logs.info("Hooks", "Successfully reloaded '\(updated.name)'. Hash: \(updated.definitionHash)")
        } catch {
            sources[index].loadError = error.localizedDescription
            logs.error("Hooks", "Failed to reload '\(current.name)': \(error.localizedDescription)")
        }
    }

    func reloadAll() {
        for source in sources {
            reloadSource(sourceID: source.id)
        }
    }

    func removeSource(sourceID: UUID) {
        if let index = sources.firstIndex(where: { $0.id == sourceID }) {
            let removed = sources.remove(at: index)
            trustStore.revoke(source: removed)
            saveSources()
            logs.info("Hooks", "Removed hook source '\(removed.name)'.")
        }
    }

    func recordExecutions(_ executions: [HookExecutionSummary]) {
        for exec in executions {
            recentExecutions.insert(exec, at: 0)
        }
        if recentExecutions.count > 50 {
            recentExecutions.removeSubrange(50..<recentExecutions.count)
        }
    }

    private func loadSources() {
        guard let data = try? Data(contentsOf: storageURL),
              let metadataList = try? JSONDecoder().decode([PersistedSourceMetadata].self, from: data) else {
            return
        }

        var loaded: [HookSource] = []
        for meta in metadataList {
            let configURL = URL(fileURLWithPath: meta.configPath)
            let rootURL = URL(fileURLWithPath: meta.packageRootPath)
            do {
                let config = try HookConfigLoader.loadConfig(from: configURL)
                let hash = HookTrustStore.computeDefinitionHash(config: config, configURL: configURL, packageRootURL: rootURL)
                let source = HookSource(
                    id: meta.id,
                    name: meta.name,
                    configURL: configURL,
                    packageRootURL: rootURL,
                    sourceKind: meta.sourceKind,
                    isEnabled: meta.isEnabled,
                    disabledHandlerIDs: cleanDisabledIDs(Set(meta.disabledHandlerIDs), for: config),
                    definitionHash: hash,
                    lastLoadedAt: Date(),
                    loadError: nil,
                    config: config
                )
                loaded.append(source)
            } catch {
                let broken = HookSource(
                    id: meta.id,
                    name: meta.name,
                    configURL: configURL,
                    packageRootURL: rootURL,
                    sourceKind: meta.sourceKind,
                    isEnabled: meta.isEnabled,
                    disabledHandlerIDs: Set(meta.disabledHandlerIDs),
                    definitionHash: "",
                    lastLoadedAt: Date(),
                    loadError: error.localizedDescription,
                    config: HookSourceConfig()
                )
                loaded.append(broken)
            }
        }
        self.sources = loaded
    }

    private func cleanDisabledIDs(_ disabled: Set<String>, for config: HookSourceConfig) -> Set<String> {
        var validIDs = Set<String>()
        for groups in config.hooks.values {
            for g in groups {
                for h in g.hooks {
                    validIDs.insert(h.id)
                }
            }
        }
        return disabled.intersection(validIDs)
    }

    private func saveSources() {
        let metadataList = sources.map {
            PersistedSourceMetadata(
                id: $0.id,
                name: $0.name,
                configPath: $0.configURL.path,
                packageRootPath: $0.packageRootURL.path,
                sourceKind: $0.sourceKind,
                isEnabled: $0.isEnabled,
                disabledHandlerIDs: Array($0.disabledHandlerIDs)
            )
        }
        guard let data = try? JSONEncoder().encode(metadataList) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
