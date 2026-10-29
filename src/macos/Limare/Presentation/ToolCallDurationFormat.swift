import Foundation

/// How long a tool call took, as its row shows it: nothing under a second, where the time says
/// nothing to the reader; tenths of a second under a minute, minutes and seconds after.
enum ToolCallDurationFormat {
    static func compact(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds >= 1_000 else { return nil }
        let seconds = Double(milliseconds) / 1_000
        if seconds < 60 {
            return String(format: "%.1fs", (seconds * 10).rounded(.down) / 10)
        }
        let whole = milliseconds / 1_000
        return "\(whole / 60)m \(String(format: "%02d", whole % 60))s"
    }
}
