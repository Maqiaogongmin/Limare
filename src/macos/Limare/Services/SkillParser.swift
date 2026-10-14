import Foundation

enum SkillParser {
    static let defaultSkillName = "Untitled Skill"

    struct ParsedSkillMD: Equatable {
        var name: String = SkillParser.defaultSkillName
        var description: String = ""
        var version: String = "1.0.0"
        var body: String = ""
    }

    static func parse(skillMD content: String, fallbackName: String? = nil) -> ParsedSkillMD {
        var result = ParsedSkillMD()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = content.components(separatedBy: "\n")
        let hasOpeningFence = trimmed.hasPrefix("---")

        var frontmatterEnd: Int?
        let scanStart = hasOpeningFence ? 1 : 0
        if scanStart < lines.count {
            for i in scanStart..<lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    frontmatterEnd = i
                    break
                }
            }
        }

        guard let endIdx = frontmatterEnd else {
            result.body = content
            if let fallbackName, !fallbackName.isEmpty {
                result.name = fallbackName
            }
            return result
        }

        if !hasOpeningFence {
            var sawRecognizedKey = false
            let looksLikeFrontmatter = (scanStart..<endIdx).allSatisfy { idx in
                let line = lines[idx]
                let stripped = line.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty { return true }
                if line.first?.isWhitespace == true { return true }
                guard let colon = line.firstIndex(of: ":") else { return false }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty,
                      key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    return false
                }
                let lowered = key.lowercased()
                if lowered == "name" || lowered == "description" || lowered == "version" {
                    sawRecognizedKey = true
                }
                return true
            }
            guard looksLikeFrontmatter, sawRecognizedKey else {
                result.body = content
                if let fallbackName, !fallbackName.isEmpty {
                    result.name = fallbackName
                }
                return result
            }
        }

        var i = scanStart
        while i < endIdx {
            let line = lines[i]
            guard let colonIdx = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            let value = strippedQuotes(rawValue)

            let isBlockScalar: Bool = {
                guard let first = rawValue.first, first == "|" || first == ">" else { return false }
                let rest = rawValue.dropFirst()
                return rest.allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
            }()

            let resolvedValue: String
            if isBlockScalar, i + 1 < endIdx {
                let fold = (rawValue.first == ">")
                var blockLines: [String] = []
                var j = i + 1
                while j < endIdx {
                    let next = lines[j]
                    if next.isEmpty || next.first?.isWhitespace == true {
                        blockLines.append(next.trimmingCharacters(in: .whitespaces))
                    } else {
                        break
                    }
                    j += 1
                }
                if fold {
                    resolvedValue = blockLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                } else {
                    resolvedValue = blockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                i = j
            } else {
                resolvedValue = value
                i += 1
            }

            switch key {
            case "name": result.name = resolvedValue
            case "description": result.description = resolvedValue
            case "version": result.version = resolvedValue
            default: break
            }
        }

        if (result.name == defaultSkillName || result.name.isEmpty), let fallbackName, !fallbackName.isEmpty {
            result.name = fallbackName
        }

        let bodyLines = Array(lines[(endIdx + 1)...])
        result.body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return result
    }

    private static func strippedQuotes(_ str: String) -> String {
        var s = str.trimmingCharacters(in: .whitespaces)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")), s.count >= 2 {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }
}
