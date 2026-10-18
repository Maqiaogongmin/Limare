import Foundation

struct ToolCallChangeNotice: Equatable {
    let paths: [String]
    let ownerMessageID: UUID
}

enum ToolCallChangeTruth {
    /// File changes recorded for a tool call that did not end in success.
    static func notice(
        toolState: ToolExecutionState,
        providerCallID: String,
        records: [UndoChangeRecord]
    ) -> ToolCallChangeNotice? {
        switch toolState {
        case .failed, .timedOut, .cancelled, .interrupted:
            break
        case .queued, .awaitingApproval, .running, .completed, .denied:
            return nil
        }
        guard !providerCallID.isEmpty else { return nil }
        let matching = records.filter { $0.toolCallID == providerCallID && $0.status == .applied }
        guard let first = matching.first else { return nil }
        return ToolCallChangeNotice(
            paths: Array(Set(matching.map(\.path))).sorted(),
            ownerMessageID: first.ownerMessageID
        )
    }
}
