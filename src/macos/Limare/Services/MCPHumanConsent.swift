import Foundation
import LocalAuthentication

/// Short-lived Human ticket from LocalAuthentication, minted for one Host operation (a Settings save,
/// an import, a sign-in or token replacement) and passed only to that operation's commit. It never
/// comes from model JSON, environment or process claims.
struct MCPHumanConsent: Sendable {
    typealias Provider = @MainActor (_ operationID: UUID, _ reason: String) async throws -> MCPHumanConsent

    let operationID: UUID
    private let expiresAt: Date
    private init(operationID: UUID) {
        self.operationID = operationID
        expiresAt = Date().addingTimeInterval(300)
    }
    var isValid: Bool { Date() < expiresAt }

    static func authorize(operationID: UUID, reason: String) async throws -> MCPHumanConsent {
        let context = LAContext()
        let accepted: Bool
        do { accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            throw MCPOAuthError.cancelled
        }
        guard accepted else { throw MCPOAuthError.cancelled }
        return MCPHumanConsent(operationID: operationID)
    }

    #if DEBUG
    static func forTesting(operationID: UUID = UUID()) -> MCPHumanConsent { MCPHumanConsent(operationID: operationID) }
    #endif
}
