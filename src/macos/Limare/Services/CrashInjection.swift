import Foundation

/// Named points where the crash-recovery tests kill the process (SIGKILL) to prove every step
/// of recording, restoring and retracting survives an abrupt stop. Compiled in only
/// with `-D LIMARE_CRASH_INJECTION` (the crash matrix test); app builds contain no hook.
enum CrashInjection {
    @inline(__always)
    static func point(_ label: String) {
        #if LIMARE_CRASH_INJECTION
        if ProcessInfo.processInfo.environment["LIMARE_TEST_CRASH_AT"] == label {
            kill(getpid(), SIGKILL)
        }
        #endif
    }
}
