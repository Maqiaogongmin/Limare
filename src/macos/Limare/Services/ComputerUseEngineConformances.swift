import Foundation

extension ComputerUseActivationStore: ComputerUseActivationProviding {
    public func isActivated(conversationID: UUID) async -> Bool {
        await MainActor.run {
            self.claimReleasedSession(conversationID: conversationID)
            return self.isActivated && self.activeConversationID == conversationID
        }
    }

    public func unavailableReason(conversationID: UUID) async -> String? {
        await MainActor.run { self.refusalReason(conversationID: conversationID) }
    }

    public func currentGeneration(conversationID: UUID, runID: UUID) async -> Int {
        await MainActor.run {
            Int(self.currentGeneration(conversationID: conversationID, runID: runID))
        }
    }
}

extension ComputerUseAppAuthorizationStore: ComputerUseAppAuthorizing {
    public func getAuthorizationStatus(conversationID: UUID, bundleID: String) async -> ComputerUseAppAuthorizationState {
        await MainActor.run {
            self.authorizationStatus(conversationID: conversationID, bundleID: bundleID)
        }
    }

    public func requestAppApproval(conversationID: UUID, bundleID: String, appLocalizedName: String) async -> ComputerUseAppAuthorizationState {
        let res = await self.requestAppApprovalWithResolution(conversationID: conversationID, bundleID: bundleID, appLocalizedName: appLocalizedName)
        switch res {
        case .allowedForConversation: return .allowedForConversation
        case .blockedForConversation: return .blockedForConversation
        @unknown default: return .unknown
        }
    }

    public func unattendedRefusal(conversationID: UUID, appName: String) async -> String? {
        await MainActor.run {
            // Only an app the run would have asked about; one the user blocked keeps the plain denial.
            let status = self.authorizationStatus(conversationID: conversationID, bundleID: appName)
            guard self.isUnattendedConversation?(conversationID) == true,
                  status != .allowedForConversation, status != .blockedForConversation else { return nil }
            return "This is an unattended scheduled run, so access to \(appName) cannot be granted now. Do not retry; continue without it, and say in your final reply that this app needs approval in a manual run."
        }
    }
}

extension ComputerUseV2Engine {
    convenience init(
        driver: any ComputerUseDriver,
        targetStore: ComputerUseTargetStore = ComputerUseTargetStore(),
        elementRegistry: ComputerUseElementRegistry = ComputerUseElementRegistry(),
        activationStore: ComputerUseActivationStore,
        appAuthorizationStore: ComputerUseAppAuthorizationStore,
        logs: DebugLogStore? = nil,
        runtimeEvents: RuntimeEventStore? = nil
    ) {
        self.init(
            driver: driver,
            targetStore: targetStore,
            elementRegistry: elementRegistry,
            activationProvider: activationStore,
            appAuthorizer: appAuthorizationStore,
            onLog: { category, message in
                Task { @MainActor [logs] in
                    logs?.info(category, message)
                }
            },
            onEvent: { conversationID, runID, kind, summary in
                Task { @MainActor [runtimeEvents] in
                    runtimeEvents?.record(
                        conversationID: conversationID,
                        runID: runID,
                        domain: .tool,
                        kind: kind,
                        severity: .info,
                        summary: summary
                    )
                }
            }
        )
    }
}
