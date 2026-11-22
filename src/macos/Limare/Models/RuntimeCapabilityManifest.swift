import Foundation

/// Immutable, request-scoped composition input. It deliberately stores only
/// derived prompt/tool projections; owning stores retain all capability truth.
struct RuntimeCapabilityManifest: Sendable {
    static let dynamicBoundaryMarker = "<!-- LIMARE_PROMPT_DYNAMIC_BOUNDARY -->"

    static func strippingDynamicBoundary(_ prompt: String) -> String {
        guard let range = prompt.range(of: dynamicBoundaryMarker) else { return prompt }
        let prefix = prompt[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = prompt[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return tail }
        if tail.isEmpty { return prefix }
        return prefix + "\n\n" + tail
    }

    let systemPrompt: String
    let toolDefinitions: [ChatToolDefinition]
}
