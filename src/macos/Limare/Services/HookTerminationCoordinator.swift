import Foundation
import AppKit

private final class TerminationResumedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

@MainActor
final class HookTerminationCoordinator {
    private var terminationTask: Task<Void, Never>?
    private(set) var hasTerminated = false

    func terminateSession(
        coordinator: HookSessionCoordinator,
        conversationID: UUID,
        workspaceURL: URL,
        timeoutSeconds: Double = 3.0
    ) async {
        if hasTerminated { return }
        if let existing = terminationTask {
            await existing.value
            return
        }

        let task = Task<Void, Never> { @MainActor in
            let sessionTask = Task { @MainActor in
                await coordinator.onSessionEnd(conversationID: conversationID, reason: "exit", workspaceURL: workspaceURL)
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            }

            let flag = TerminationResumedFlag()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    Task {
                        _ = await sessionTask.value
                        if flag.testAndSet() {
                            cont.resume()
                        }
                    }
                    Task {
                        _ = await timeoutTask.value
                        if flag.testAndSet() {
                            cont.resume()
                        }
                    }
                }
            } onCancel: {
                sessionTask.cancel()
                timeoutTask.cancel()
            }
            sessionTask.cancel()
            timeoutTask.cancel()
            self.hasTerminated = true
        }
        self.terminationTask = task
        await task.value
    }

    static func terminateSession(
        coordinator: HookSessionCoordinator,
        conversationID: UUID,
        workspaceURL: URL,
        timeoutSeconds: Double = 3.0
    ) async {
        let oneShot = HookTerminationCoordinator()
        await oneShot.terminateSession(coordinator: coordinator, conversationID: conversationID, workspaceURL: workspaceURL, timeoutSeconds: timeoutSeconds)
    }
}
