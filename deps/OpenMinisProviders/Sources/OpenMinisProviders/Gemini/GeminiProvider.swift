import Foundation
enum GeminiConversation {

    /// Build a user message with text content.
    static func userMessage(_ text: String) -> [String: Any] {
        ["role": "user", "parts": [["text": text]]]
    }

    /// Build a user message with multiple content objects (for tool results).
    static func userMessage(parts: [[String: Any]]) -> [String: Any] {
        ["role": "user", "parts": parts]
    }

    /// Build a model message with text.
    static func modelMessage(_ text: String) -> [String: Any] {
        ["role": "model", "parts": [["text": text]]]
    }

    /// Build a model message with parts (text + function calls).
    static func modelMessage(parts: [[String: Any]]) -> [String: Any] {
        ["role": "model", "parts": parts]
    }

    /// Build a function call part for a model message.
    /// Includes `thoughtSignature` when present (required by Gemini 3 models).
    static func functionCallPart(name: String, args: [String: Any], thoughtSignature: String? = nil) -> [String: Any] {
        var part: [String: Any] = ["functionCall": ["name": name, "args": args]]
        if let sig = thoughtSignature {
            part["thoughtSignature"] = sig
        }
        return part
    }

    /// Build a function response part for a user message.
    static func functionResponsePart(name: String, response: [String: Any]) -> [String: Any] {
        ["functionResponse": ["name": name, "response": response]]
    }

    /// Build a tool definition for the Gemini API.
    static func toolDefinition(
        name: String,
        description: String,
        parameters: [String: Any]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": parameters,
        ]
    }
}
