import Foundation

public enum VoiceTextSanitizer {
    public static func sanitize(_ text: String) -> String {
        var result = text

        // 1. Remove fenced code blocks (``` ... ```)
        let fencedCodeRegex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: [])
        if let regex = fencedCodeRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }

        // 2. Inline code (`code` -> code)
        let inlineCodeRegex = try? NSRegularExpression(pattern: "`([^`]+)`", options: [])
        if let regex = inlineCodeRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }

        // 3. Markdown links [text](url) -> text
        let linkRegex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", options: [])
        if let regex = linkRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }

        // 4. Bare URLs (https://... or http://...) -> remove
        let urlRegex = try? NSRegularExpression(pattern: "https?://\\S+", options: [])
        if let regex = urlRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }

        // 5. Line-by-line cleanup: headings, blockquotes, list markers, table rows
        let lines = result.components(separatedBy: .newlines)
        var cleanedLines: [String] = []

        for line in lines {
            var l = line.trimmingCharacters(in: .whitespaces)

            // Table separator lines (e.g. |---|---| or |:---:|) -> drop
            if l.hasPrefix("|") && l.contains("-") && (l.contains("---") || l.hasSuffix("|")) {
                let withoutPipes = l.replacingOccurrences(of: "|", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                if withoutPipes.isEmpty {
                    continue
                }
            }

            // Headings (# Heading) -> drop leading '#'
            while l.hasPrefix("#") {
                l.removeFirst()
            }
            l = l.trimmingCharacters(in: .whitespaces)

            // Blockquotes (> Quote) -> drop leading '>'
            while l.hasPrefix(">") {
                l.removeFirst()
            }
            l = l.trimmingCharacters(in: .whitespaces)

            // Unordered list markers (* , - , + )
            if l.hasPrefix("* ") || l.hasPrefix("- ") || l.hasPrefix("+ ") {
                l.removeFirst(2)
            }

            // Ordered list markers (1. , 2. , etc.)
            let listRegex = try? NSRegularExpression(pattern: "^\\d+\\.\\s+", options: [])
            if let regex = listRegex {
                l = regex.stringByReplacingMatches(in: l, options: [], range: NSRange(location: 0, length: l.utf16.count), withTemplate: "")
            }

            // Table pipe removal (| col1 | col2 | -> col1 col2)
            if l.contains("|") {
                let parts = l.components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                l = parts.joined(separator: " ")
            }

            if !l.isEmpty {
                cleanedLines.append(l)
            }
        }

        result = cleanedLines.joined(separator: "\n")

        // 6. Emphasis markers (**bold**, *italic*, ~~strike~~)
        // Bold: **text** or __text__
        let boldAsteriskRegex = try? NSRegularExpression(pattern: "\\*\\*([^\\*]+)\\*\\*", options: [])
        if let regex = boldAsteriskRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }
        let boldUnderscoreRegex = try? NSRegularExpression(pattern: "(?<!\\w)__([^_]+)__(?!\\w)", options: [])
        if let regex = boldUnderscoreRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }

        // Italic: *text* or (word-boundary)_text_(word-boundary)
        let italicAsteriskRegex = try? NSRegularExpression(pattern: "\\*([^\\*\\s][^\\*]*)\\*", options: [])
        if let regex = italicAsteriskRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }
        let italicUnderscoreRegex = try? NSRegularExpression(pattern: "(?<=\\s|^)_([^_\\s][^_]*)_(?=\\s|$|[.,!?;:])", options: [])
        if let regex = italicUnderscoreRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }

        // Strikethrough ~~text~~
        let strikeRegex = try? NSRegularExpression(pattern: "~~([^~]+)~~", options: [])
        if let regex = strikeRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "$1")
        }

        // 7. Remove Emojis & Pictographs
        result = result.unicodeScalars.filter { scalar in
            !isEmojiOrPictograph(scalar)
        }.reduce("") { $0 + String($1) }

        // 8. Collapse extra whitespace and clean up
        let multiNewlineRegex = try? NSRegularExpression(pattern: "\\n{3,}", options: [])
        if let regex = multiNewlineRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "\n\n")
        }

        let multiSpaceRegex = try? NSRegularExpression(pattern: "[ \\t]{2,}", options: [])
        if let regex = multiSpaceRegex {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isEmojiOrPictograph(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        // Emoticons, Miscellaneous Symbols, Dingbats, Supplemental Symbols, Transport/Map
        return (0x1F600...0x1F64F).contains(v) // Emoticons
            || (0x1F300...0x1F5FF).contains(v) // Misc Symbols and Pictographs
            || (0x1F680...0x1F6FF).contains(v) // Transport and Map
            || (0x1F700...0x1F77F).contains(v) // Alchemical Symbols
            || (0x1F780...0x1F7FF).contains(v) // Geometric Shapes Extended
            || (0x1F800...0x1F8FF).contains(v) // Supplemental Arrows-C
            || (0x1F900...0x1F9FF).contains(v) // Supplemental Symbols and Pictographs
            || (0x1FA00...0x1FA6F).contains(v) // Chess Symbols
            || (0x1FA70...0x1FAFF).contains(v) // Symbols and Pictographs Extended-A
            || (0x2600...0x26FF).contains(v)   // Misc Symbols
            || (0x2700...0x27BF).contains(v)   // Dingbats
            || (0xFE00...0xFE0F).contains(v)   // Variation Selectors
            || (0x1F1E6...0x1F1FF).contains(v) // Regional Indicator Symbols (Flags)
    }
}
