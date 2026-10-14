import Foundation
import CryptoKit

final class HookTrustStore: Sendable {
    private let storageURL: URL
    private let lock = NSLock()

    init(storageDirectory: URL? = nil) {
        let directory: URL
        if let storageDirectory {
            directory = storageDirectory
        } else {
            let appSupport = LimareStorage.applicationSupport
            directory = appSupport.appendingPathComponent(LimareStorage.bundleIdentifier, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storageURL = directory.appendingPathComponent("trusted_hooks.json")
    }

    static func computeDefinitionHash(config: HookSourceConfig, configURL: URL, packageRootURL: URL) -> String {
        var components: [String] = []
        components.append("config:\(configURL.standardizedFileURL.path)")
        components.append("root:\(packageRootURL.standardizedFileURL.path)")

        for eventKey in config.hooks.keys.sorted() {
            components.append("event:\(eventKey)")
            let matcherGroups = config.hooks[eventKey] ?? []
            for group in matcherGroups {
                components.append("matcher:\(group.matcher ?? "*")")
                for hook in group.hooks {
                    components.append("hook:type=\(hook.type.rawValue);cmd=\(hook.command ?? "");timeout=\(hook.timeout ?? 0);status=\(hook.statusMessage ?? "");limit=\(hook.additionalContextLimit ?? 0);async=\(hook.isAsync ?? false);enabled=\(hook.enabled ?? true)")
                }
            }
        }

        let combined = components.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    func isTrusted(definitionHash: String) -> Bool {
        guard !definitionHash.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let trustedHashes = loadTrustedHashes()
        return trustedHashes.contains(definitionHash)
    }

    func isTrusted(source: HookSource) -> Bool {
        isTrusted(definitionHash: source.definitionHash)
    }

    func trust(definitionHash: String) {
        guard !definitionHash.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var trustedHashes = loadTrustedHashes()
        trustedHashes.insert(definitionHash)
        saveTrustedHashes(trustedHashes)
    }

    func trust(source: HookSource) {
        trust(definitionHash: source.definitionHash)
    }

    func revoke(definitionHash: String) {
        guard !definitionHash.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var trustedHashes = loadTrustedHashes()
        trustedHashes.remove(definitionHash)
        saveTrustedHashes(trustedHashes)
    }

    func revoke(source: HookSource) {
        revoke(definitionHash: source.definitionHash)
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        saveTrustedHashes([])
    }

    private func loadTrustedHashes() -> Set<String> {
        guard let data = try? Data(contentsOf: storageURL),
              let hashes = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return hashes
    }

    private func saveTrustedHashes(_ hashes: Set<String>) {
        guard let data = try? JSONEncoder().encode(hashes) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
