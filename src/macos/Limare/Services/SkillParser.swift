import Foundation

enum SkillParser {
    static let defaultSkillName = "Untitled Skill"

    struct ParsedSkillMD: Equatable {
        var name: String = SkillParser.defaultSkillName
        var description: String = ""
        var version: String = "1.0.0"
        var body: String = ""
        var icon: String? = nil
        var color: ExtensionCardColor? = nil
        var examples: [String] = []
        var mcpServers: [String] = []
        var isHidden: Bool = false
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

            let isListKey = (key == "examples" || key == "mcp_servers" || key == "mcpservers")
            if isListKey, rawValue.isEmpty, i + 1 < endIdx {
                var items: [String] = []
                var j = i + 1
                while j < endIdx {
                    let next = lines[j]
                    let trimmedNext = next.trimmingCharacters(in: .whitespaces)
                    if trimmedNext.isEmpty {
                        j += 1
                        continue
                    }
                    if trimmedNext.hasPrefix("- ") || trimmedNext == "-" {
                        let itemRaw = trimmedNext.dropFirst(1).trimmingCharacters(in: .whitespaces)
                        let item = strippedQuotes(itemRaw)
                        if !item.isEmpty {
                            items.append(item)
                        }
                        j += 1
                    } else if next.first?.isWhitespace == true {
                        j += 1
                    } else {
                        break
                    }
                }
                i = j
                if key == "examples" {
                    result.examples = Array(items.prefix(3))
                } else {
                    result.mcpServers = deduplicatePreservingOrder(items)
                }
                continue
            }

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
            case "icon":
                let trimmedIcon = resolvedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                result.icon = trimmedIcon.isEmpty ? nil : trimmedIcon
            case "color":
                let loweredColor = resolvedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                result.color = ExtensionCardColor(rawValue: loweredColor)
            case "hidden":
                let lowered = resolvedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                result.isHidden = (lowered == "true" || lowered == "yes")
            case "examples":
                let items = parseInlineList(rawValue, allowSemicolon: true)
                result.examples = Array(items.prefix(3))
            case "mcp_servers", "mcpservers":
                let items = parseInlineList(rawValue, allowSemicolon: false)
                result.mcpServers = deduplicatePreservingOrder(items)
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

    private static func parseInlineList(_ rawValue: String, allowSemicolon: Bool) -> [String] {
        var trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed
                .components(separatedBy: ",")
                .map { strippedQuotes($0) }
                .filter { !$0.isEmpty }
        }
        if allowSemicolon && trimmed.contains(";") {
            return trimmed
                .components(separatedBy: ";")
                .map { strippedQuotes($0) }
                .filter { !$0.isEmpty }
        }
        let single = strippedQuotes(trimmed)
        return single.isEmpty ? [] : [single]
    }

    private static func deduplicatePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
