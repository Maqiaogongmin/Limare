import Foundation

/// How long a tool call took, as its row shows it: nothing under a second, where the time says
/// nothing to the reader; the exact milliseconds stay in the call's details.
enum ToolCallDurationFormat {
    static func compact(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds >= 1_000 else { return nil }
        return detail(milliseconds: milliseconds)
    }

    /// The same format for any duration, as the call's details show it: tenths of a second
    /// under a minute, minutes and seconds after.
    static func detail(milliseconds: Int) -> String {
        if milliseconds < 100 { return "< 0.1s" }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 {
            return String(format: "%.1fs", (seconds * 10).rounded(.down) / 10)
        }
        let whole = milliseconds / 1_000
        return "\(whole / 60)m \(String(format: "%02d", whole % 60))s"
    }
}
