import Foundation

struct HookConfigLoader {
    enum LoadError: LocalizedError, Equatable {
        case fileNotFound(URL)
        case invalidDirectoryStructure(URL)
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "Hooks config not found at: \(url.path)"
            case .invalidDirectoryStructure(let url):
                return "No hooks.json or hooks/hooks.json found in: \(url.path)"
            case .parseError(let message):
                return "Failed to parse hooks configuration: \(message)"
            }
        }
    }

    static func resolvePaths(from targetURL: URL) throws -> (configURL: URL, packageRootURL: URL) {
        let standardURL = targetURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardURL.path, isDirectory: &isDir) else {
            throw LoadError.fileNotFound(standardURL)
        }

        if isDir.boolValue {
            let nestedHooks = standardURL.appendingPathComponent("hooks").appendingPathComponent("hooks.json")
            if FileManager.default.fileExists(atPath: nestedHooks.path) {
                return (configURL: nestedHooks, packageRootURL: standardURL)
            }
            let directHooks = standardURL.appendingPathComponent("hooks.json")
            if FileManager.default.fileExists(atPath: directHooks.path) {
                return (configURL: directHooks, packageRootURL: standardURL)
            }
            throw LoadError.invalidDirectoryStructure(standardURL)
        } else {
            let configURL = standardURL
            let parent = standardURL.deletingLastPathComponent()
            if parent.lastPathComponent.lowercased() == "hooks" {
                let grandParent = parent.deletingLastPathComponent()
                return (configURL: configURL, packageRootURL: grandParent)
            } else {
                return (configURL: configURL, packageRootURL: parent)
            }
        }
    }

    static func inferPackageName(packageRootURL: URL, configURL: URL) -> String {
        // Try plugin.json
        let pluginJSONURL = packageRootURL.appendingPathComponent("plugin.json")
        if let data = try? Data(contentsOf: pluginJSONURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }

        // Try package.json
        let packageJSONURL = packageRootURL.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageJSONURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return name
        }

        let folderName = packageRootURL.lastPathComponent
        if folderName.isEmpty || folderName == "/" {
            return configURL.deletingLastPathComponent().lastPathComponent
        }
        return folderName
    }

    static func loadConfig(from configURL: URL) throws -> HookSourceConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            throw LoadError.fileNotFound(configURL)
        }

        do {
            let config = try JSONDecoder().decode(HookSourceConfig.self, from: data)
            return config
        } catch {
            throw LoadError.parseError(error.localizedDescription)
        }
    }

    static func loadSource(
        from targetURL: URL,
        sourceKind: HookSourceKind,
        nameOverride: String? = nil
    ) throws -> HookSource {
        let (configURL, packageRootURL) = try resolvePaths(from: targetURL)
        let config = try loadConfig(from: configURL)
        let name = nameOverride ?? inferPackageName(packageRootURL: packageRootURL, configURL: configURL)
        let hash = HookTrustStore.computeDefinitionHash(config: config, configURL: configURL, packageRootURL: packageRootURL)

        return HookSource(
            name: name,
            configURL: configURL,
            packageRootURL: packageRootURL,
            sourceKind: sourceKind,
            isEnabled: true,
            definitionHash: hash,
            lastLoadedAt: Date(),
            loadError: nil,
            config: config
        )
    }

    static func discoverCodexUserHooks() -> HookSource? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userHooks = home.appendingPathComponent(".codex").appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: userHooks.path) {
            return try? loadSource(from: userHooks, sourceKind: .codexUser, nameOverride: "Codex User Config")
        }
        return nil
    }

    static func discoverCodexProjectHooks(workspaceURL: URL) -> HookSource? {
        let projectHooks = workspaceURL.appendingPathComponent(".codex").appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: projectHooks.path) {
            return try? loadSource(from: projectHooks, sourceKind: .codexProject, nameOverride: "Codex Project Config")
        }
        return nil
    }
}
