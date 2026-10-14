import Foundation

/// Immutable, request-scoped composition input. It deliberately stores only
/// derived prompt/tool projections; owning stores retain all capability truth.
struct RuntimeCapabilityManifest: Sendable {
    let systemPrompt: String
    let toolDefinitions: [ChatToolDefinition]
}
