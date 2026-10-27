import Foundation

enum PermissionEvaluator {
    static func evaluate(
        _ request: ToolPermissionRequest,
        allowedReadDirectories: [URL] = [],
        memoryLocations: [URL] = []
    ) -> PermissionEvaluation {
        // A shell command runs in the sandbox without asking, as under Codex's on-request
        // policy: the sandbox confines it. Only running outside it (require_escalated) asks.
        if request.toolName == "shell_execute" {
            guard request.leavesSandbox else { return .allowed }
            let trigger = PermissionTrigger(reason: .boundarySensitiveTool, detail: String(localized: "Runs outside the sandbox."))
            return .requiresApproval(reason: trigger.detail, triggers: [trigger])
        }

        var triggers: [PermissionTrigger] = []

        // 1. Check for sensitive files / credential paths in affected URLs
        for url in request.affectedURLs {
            if isSensitivePath(url) {
                triggers.append(PermissionTrigger(
                    reason: .sensitivePath,
                    detail: String(localized: "Targets sensitive data or credential path (\(url.lastPathComponent)).")
                ))
            }
        }

        // 2. High-risk command / destructive operation
        if request.isHighRisk {
            triggers.append(PermissionTrigger(
                reason: .highRiskCommand,
                detail: String(localized: "Contains a high-risk or destructive command.")
            ))
        }

        // 3. Network access request
        if request.requestsNetwork {
            triggers.append(PermissionTrigger(
                reason: .networkAccess,
                detail: String(localized: "Requests access to external network resources.")
            ))
        }

        // 4. Workspace boundary
        if let workspaceURL = request.workspaceURL {
            let outsideWorkspace = request.affectedURLs.filter {
                !WorkspacePathResolver.isInsideWorkspace($0, workspaceURL: workspaceURL)
            }
            if !outsideWorkspace.isEmpty {
                let allAllowedReads = request.toolName == "file_read" && outsideWorkspace.allSatisfy { url in
                    allowedReadDirectories.contains(where: { isInsideDirectory(url, directoryURL: $0) })
                }
                let memoryTools: Set<String> = ["file_read", "file_list", "file_search", "file_write", "file_edit"]
                let allMemoryPaths = memoryTools.contains(request.toolName) && outsideWorkspace.allSatisfy { url in
                    memoryLocations.contains { isInsideDirectory(url, directoryURL: $0) }
                }
                if !allAllowedReads && !allMemoryPaths {
                    triggers.append(PermissionTrigger(
                        reason: .outsideWorkspace,
                        detail: String(localized: "Accesses a path outside the current Project Workspace folder.")
                    ))
                }
            }
        }

        if triggers.isEmpty {
            return .allowed
        } else {
            let primaryReason = triggers.map(\.detail).joined(separator: " ")
            return .requiresApproval(reason: primaryReason, triggers: triggers)
        }
    }

    // Backwards compatibility helper for older call sites
    static func evaluate(
        _ request: ToolPermissionRequest,
        mode: PermissionMode,
        allowedReadDirectories: [URL] = [],
        memoryLocations: [URL] = []
    ) -> PermissionEvaluation {
        if mode == .fullAccess { return .allowed }
        return evaluate(request, allowedReadDirectories: allowedReadDirectories, memoryLocations: memoryLocations)
    }

    static func isInsideDirectory(_ url: URL, directoryURL: URL) -> Bool {
        let root = WorkspacePathResolver.canonicalPath(directoryURL)
        let target = WorkspacePathResolver.canonicalPath(url)
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isSensitivePath(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let sensitiveDirectories: Set<String> = [".ssh", ".gnupg", ".aws", ".azure", ".kube"]
        if components.contains(where: sensitiveDirectories.contains) { return true }

        let name = url.lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") { return true }
        let sensitiveNames: Set<String> = [
            "id_rsa", "id_ed25519", "credentials.json", "secrets.json",
            "service-account.json", ".netrc", ".npmrc", ".pypirc", ".git-credentials"
        ]
        if sensitiveNames.contains(name) { return true }
        let sensitiveExtensions: Set<String> = ["pem", "key", "p12", "pfx"]
        return sensitiveExtensions.contains(url.pathExtension.lowercased())
    }
}
