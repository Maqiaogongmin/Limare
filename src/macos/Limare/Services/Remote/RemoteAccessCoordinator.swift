import Foundation
import Observation

/// The tunnel token, in the app's private secret vault (never UserDefaults, never logs).
struct RemoteAccessSecrets: Sendable {
    private static let tunnelTokenKey = "cloudflareTunnelToken"
    private let vault: AppSecretFileVault

    init(storageRootURL: URL) {
        vault = AppSecretFileVault(storageRootURL: storageRootURL, fileName: "remote-secrets.json")
    }

    var tunnelToken: String? {
        vault.value(for: Self.tunnelTokenKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    func setTunnelToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try vault.removeValue(for: Self.tunnelTokenKey)
        } else {
            try vault.setValue(trimmed, for: Self.tunnelTokenKey)
        }
    }
}

/// Remote Access for the life of the app: the session hub, the embedded server and the
/// cloudflared tunnel, started at launch when enabled and stopped at quit. Owns no Limare state.
@MainActor
@Observable
final class RemoteAccessCoordinator {
    enum ServerStatus: Equatable {
        case off
        case starting
        case serving(port: Int)
        case failed(String)
    }

    private(set) var configuration: RemoteAccessConfiguration
    private(set) var serverStatus: ServerStatus = .off

    @ObservationIgnored let hub: RemoteSessionHub
    let tunnel: CloudflareTunnelSupervisor
    @ObservationIgnored let secrets: RemoteAccessSecrets
    @ObservationIgnored private let logs: DebugLogStore
    @ObservationIgnored private let defaults: UserDefaults
    /// False for test runs and isolated storage roots: only the real app ever serves.
    @ObservationIgnored private let mayServe: Bool
    @ObservationIgnored private let webRoot: URL
    @ObservationIgnored private var host: RemoteTransportHost?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?

    init(hub: RemoteSessionHub, tunnel: CloudflareTunnelSupervisor, secrets: RemoteAccessSecrets, logs: DebugLogStore, mayServe: Bool,
         defaults: UserDefaults = .standard, webRoot: URL? = nil) {
        self.hub = hub
        self.tunnel = tunnel
        self.secrets = secrets
        self.logs = logs
        self.mayServe = mayServe
        self.defaults = defaults
        self.webRoot = webRoot ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("RemoteWeb", isDirectory: true)
        self.configuration = RemoteAccessConfiguration.load(from: defaults)
    }

    func start() {
        guard lifecycle == nil else { return }
        let configuration = self.configuration
        guard mayServe, configuration.isEnabled else {
            serverStatus = .off
            return
        }
        var missing = configuration.missingSettings
        let token = secrets.tunnelToken
        if token == nil { missing.append("tunnel token") }
        guard missing.isEmpty, let token else {
            serverStatus = .failed("Missing: \(missing.joined(separator: ", "))")
            return
        }
        guard let host = Self.makeHost(configuration: configuration, endpoint: hub, webRoot: webRoot, logs: logs) else {
            serverStatus = .failed("The remote server is not part of this build.")
            return
        }
        serverStatus = .starting
        hub.start()
        self.host = host
        lifecycle = Task { [weak self] in
            do {
                let port = try await host.start()
                guard let self else { return }
                self.serverStatus = .serving(port: port)
                self.logs.info("Remote", "Serving on 127.0.0.1:\(port).")
                // The tunnel only once something listens behind it.
                await self.tunnel.start(token: token)
            } catch {
                guard let self else { return }
                self.serverStatus = .failed("Could not listen on 127.0.0.1:\(configuration.port): \(error.localizedDescription)")
                self.logs.error("Remote", "Server start failed on port \(configuration.port): \(error.localizedDescription)")
                self.hub.stop()
                self.host = nil
            }
        }
    }

    func stop() async {
        let task = lifecycle
        lifecycle = nil
        await task?.value
        await tunnel.stop()
        hub.stop()
        if let host {
            self.host = nil
            await host.stop()
        }
        serverStatus = .off
    }

    var hasTunnelToken: Bool { secrets.tunnelToken != nil }

    /// Saves new settings (and, when given, a new tunnel token; empty removes it) and restarts with them.
    func apply(_ configuration: RemoteAccessConfiguration, tunnelToken: String? = nil) async throws {
        if let tunnelToken { try secrets.setTunnelToken(tunnelToken) }
        configuration.save(to: defaults)
        await stop()
        self.configuration = configuration.normalized
        start()
    }

    private static func makeHost(configuration: RemoteAccessConfiguration, endpoint: RemoteSessionHub, webRoot: URL, logs: DebugLogStore) -> RemoteTransportHost? {
        #if canImport(Vapor) && canImport(JWTKit)
        return RemoteHTTPHost(
            configuration: configuration,
            verifier: CloudflareAccessVerifier(configuration: configuration),
            endpoint: endpoint,
            webRoot: webRoot,
            report: { message in Task { @MainActor in logs.info("Remote", message) } }
        )
        #else
        return nil
        #endif
    }
}
