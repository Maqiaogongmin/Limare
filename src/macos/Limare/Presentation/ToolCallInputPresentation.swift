import Foundation

/// A tool call's arguments as a reader sees them. The recorded input stays the canonical text;
/// this only re-serializes it for display.
enum ToolCallInputPresentation {
    /// A JSON object or array is parsed and written out again, indented, with keys sorted and
    /// slashes left as they are. Anything that does not parse as one is shown unchanged.
    static func formatted(_ input: String) -> String {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any],
              let output = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: output, encoding: .utf8) else {
            return input
        }
        return text
    }
}
