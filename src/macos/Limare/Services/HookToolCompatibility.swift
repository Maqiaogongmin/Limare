import Foundation

enum MatcherError: LocalizedError, Equatable {
    case invalidRegex(String)

    var errorDescription: String? {
        switch self {
        case .invalidRegex(let message):
            return message
        }
    }
}

struct HookToolCompatibility {
    static func codexToolName(for nativeToolName: String) -> String {
        switch nativeToolName {
        case "file_read":
            return "Read"
        case "file_write":
            return "Write"
        case "file_edit":
            return "Edit"
        case "shell_execute":
            return "Bash"
        case "browser_use":
            return "browser_use"
        case "read_image":
            return "read_image"
        case "model_use":
            return "model_use"
        case "ask_user_question":
            return "AskUserQuestion"
        default:
            return nativeToolName
        }
    }

    static func candidateNames(for nativeToolName: String) -> Set<String> {
        var names: Set<String> = [nativeToolName]
        let codexName = codexToolName(for: nativeToolName)
        names.insert(codexName)
        return names
    }

    static func matches(matcher: String?, nativeToolName: String) -> Result<Bool, MatcherError> {
        guard let matcher, !matcher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .success(true)
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: matcher, options: [])
        } catch {
            return .failure(.invalidRegex("Invalid regex pattern '\(matcher)': \(error.localizedDescription)"))
        }

        let candidates = candidateNames(for: nativeToolName)
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            if regex.firstMatch(in: candidate, options: [], range: range) != nil {
                return .success(true)
            }
        }

        return .success(false)
    }
}
