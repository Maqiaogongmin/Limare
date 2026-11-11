import Foundation

enum ShellRunPresentation {
    static func isShell(_ call: ToolCallRecord) -> Bool {
        call.name == "shell_execute" && MCPToolNamespace.parse(exposedName: call.name) == nil
    }

    static func duration(_ seconds: Int) -> String {
        let value = max(0, seconds)
        if value < 60 { return "\(value)s" }
        return "\(value / 60)m\(String(format: "%02d", value % 60))s"
    }

    static func silenceSeconds(_ call: ToolCallRecord, now: Date) -> Int? {
        guard call.state == .running, let start = call.shellStartedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(call.shellLastOutputAt ?? start)))
    }

    static func timeoutMessage(_ call: ToolCallRecord) -> String? {
        guard isShell(call), call.state == .timedOut, let duration = call.durationMilliseconds else { return nil }
        let json = call.errorMessage.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let elapsed = self.duration((json?["elapsed_ms_at_timeout"] as? Int ?? duration) / 1_000)
        let advice = String(localized: "Increase timeout_seconds, or run in the background and redirect output to a file.")
        if let silence = json?["silent_ms_at_timeout"] as? Int {
            let quiet = self.duration(silence / 1_000)
            return String(localized: "The command timed out after \(elapsed). No output for \(quiet) at timeout. \(advice)")
        }
        return String(localized: "The command timed out after \(elapsed). \(advice)")
    }
}
