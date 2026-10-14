import Foundation

enum ProviderModelNotFoundRecognizer {
    static func code(status: Int, message: String) -> String? {
        guard status == 400 || status == 404 || status == 422 else { return nil }
        let lower = message.lowercased()
        if lower.contains("model_not_found") { return "model_not_found" }
        if lower.contains("unknown model") { return "unknown_model" }
        if !lower.contains("endpoint"), !lower.contains("route"), !lower.contains("url"),
           lower.contains("model"), lower.contains("does not exist") || lower.contains("model not found") {
            return "model_does_not_exist"
        }
        return nil
    }
}
