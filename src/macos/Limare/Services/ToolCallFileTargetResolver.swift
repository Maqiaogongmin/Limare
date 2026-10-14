import Foundation

/// Resolves target file paths from file tool calls (`file_read`, `file_write`, `file_edit`)
/// and validates containment within the active workspace.
enum ToolCallFileTargetResolver {

    /// Extracts the raw target file path from a tool call's JSON input.
    static func extractPath(from toolCall: ToolCallRecord) -> String? {
        let name = toolCall.name
        guard name == "file_read" || name.hasSuffix("file_read") ||
              name == "file_write" || name.hasSuffix("file_write") ||
              name == "file_edit" || name.hasSuffix("file_edit") else {
            return nil
        }

        guard !toolCall.input.isEmpty,
              let data = toolCall.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String else {
            return nil
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Resolves the target file URL relative to the active workspace URL and ensures workspace containment.
    static func resolveTargetURL(for toolCall: ToolCallRecord, in workspaceURL: URL?) -> URL? {
        guard let workspaceURL, let rawPath = extractPath(from: toolCall) else {
            return nil
        }

        guard let resolved = try? WorkspacePathResolver.resolve(rawPath, relativeTo: workspaceURL, mustExist: false) else {
            return nil
        }

        guard WorkspacePathResolver.isInsideWorkspace(resolved, workspaceURL: workspaceURL) else {
            return nil
        }

        return resolved
    }
}
