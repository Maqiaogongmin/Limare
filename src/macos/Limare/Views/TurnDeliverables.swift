import Foundation

/// The files a turn delivered to the user: what its tools registered or produced as output.
/// A finished turn folds its tool calls away, so these are shown on its final answer.
enum TurnDeliverables {
    /// Artifacts of `messages`' tool calls that are for the user, first appearance first:
    /// whatever `artifact_register` registered, a tool's `deliverable` output, and generated
    /// images. Screenshots and images a tool handed the model to look at are not.
    static func artifactIDs(in messages: [ChatMessage]) -> [UUID] {
        var seen = Set<UUID>()
        var ids: [UUID] = []
        for message in messages where message.role == .assistant {
            for call in message.toolCalls where call.state == .completed {
                let registers = call.name == "artifact_register"
                for case let .artifact(id, role, _) in call.resultParts ?? []
                where registers || role == .deliverable || role == .generatedImage {
                    if seen.insert(id).inserted { ids.append(id) }
                }
            }
        }
        return ids
    }
}
