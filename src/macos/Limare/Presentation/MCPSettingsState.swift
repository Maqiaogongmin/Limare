import Foundation
import Observation

public enum MCPManagementRoute: Hashable, Sendable {
    case overview
    case edit
    case tools
}

@MainActor
@Observable
final class MCPSettingsState {
    var presentedServerID: String?
    var managementRoute: MCPManagementRoute = .overview
    var showAddSheet: Bool = false
    var pendingDeleteServerID: String?
    var searchText: String = ""
    var deleteErrorMessage: String? = nil

    init(
        presentedServerID: String? = nil,
        managementRoute: MCPManagementRoute = .overview,
        showAddSheet: Bool = false,
        pendingDeleteServerID: String? = nil,
        searchText: String = "",
        deleteErrorMessage: String? = nil
    ) {
        self.presentedServerID = presentedServerID
        self.managementRoute = managementRoute
        self.showAddSheet = showAddSheet
        self.pendingDeleteServerID = pendingDeleteServerID
        self.searchText = searchText
        self.deleteErrorMessage = deleteErrorMessage
    }

    func resetSheetState() {
        presentedServerID = nil
        managementRoute = .overview
        showAddSheet = false
        pendingDeleteServerID = nil
        deleteErrorMessage = nil
    }

    func filteredServers(from allServers: [MCPServerConfig]) -> [MCPServerConfig] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return allServers }
        return allServers.filter { server in
            server.id.localizedCaseInsensitiveContains(query)
                || (server.note ?? "").localizedCaseInsensitiveContains(query)
                || server.transportSummary.localizedCaseInsensitiveContains(query)
        }
    }

    func statusDisplayText(for status: MCPServerStatus, isEnabled: Bool) -> String {
        guard isEnabled else { return "Off" }
        switch status {
        case .connected(let count):
            return "Connected · \(count) \(count == 1 ? "tool" : "tools")"
        case .connecting:
            return "Connecting…"
        case .credentialRequired:
            return "Credential required"
        case .signInRequired:
            return "Sign-in required"
        case .signingIn:
            return "Signing in…"
        case .configSaved:
            return "Config saved"
        case .failed:
            return "Needs attention"
        case .disconnected:
            return "Not connected"
        }
    }

    func statusColorKind(for status: MCPServerStatus, isEnabled: Bool) -> InlineStatusKind {
        guard isEnabled else { return .info }
        switch status {
        case .connected: return .success
        case .connecting: return .warning
        case .credentialRequired: return .warning
        case .signInRequired, .signingIn: return .warning
        case .configSaved: return .info
        case .failed: return .error
        case .disconnected: return .info
        }
    }

    func connectionTypeDisplayName(for server: MCPServerConfig) -> String {
        server.isHTTP ? "Remote Server" : "Local Command"
    }
}
