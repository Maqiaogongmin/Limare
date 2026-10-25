import Foundation

public enum VoiceTextChunker {
    public static let maxChunkCharacters: Int = VoiceOutputDefaults.maxChunkCharacters

    public static func chunk(
        _ text: String,
        maxCharacters: Int = maxChunkCharacters,
        maxBytes: Int? = nil
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= maxCharacters && (maxBytes == nil || trimmed.utf8.count <= maxBytes!) {
            return [trimmed]
        }

        var chunks: [String] = []
        var remaining = trimmed

        while !remaining.isEmpty {
            if remaining.count <= maxCharacters && (maxBytes == nil || remaining.utf8.count <= maxBytes!) {
                let finalChunk = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalChunk.isEmpty {
                    chunks.append(finalChunk)
                }
                break
            }

            let splitIndex = findSplitIndex(in: remaining, maxCharacters: maxCharacters, maxBytes: maxBytes)
            let chunkText = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                chunks.append(chunkText)
            }

            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return chunks
    }

    /// Splits like `chunk`, but the first chunk is at most `firstCharacters` and each later one
    /// at most `growthFactor` times the previous limit, capped at `maxCharacters`/`maxBytes`.
    public static func progressiveChunk(
        _ text: String,
        firstCharacters: Int = VoiceOutputDefaults.firstChunkCharacters,
        growthFactor: Int = VoiceOutputDefaults.chunkGrowthFactor,
        maxCharacters: Int = maxChunkCharacters,
        maxBytes: Int? = nil
    ) -> [String] {
        var chunks: [String] = []
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var limit = max(1, min(firstCharacters, maxCharacters))

        while !remaining.isEmpty {
            if remaining.count <= limit && (maxBytes == nil || remaining.utf8.count <= maxBytes!) {
                chunks.append(remaining)
                break
            }
            let splitIndex = findSplitIndex(in: remaining, maxCharacters: limit, maxBytes: maxBytes)
            let chunkText = String(remaining[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                chunks.append(chunkText)
            }
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            limit = min(maxCharacters, limit * max(1, growthFactor))
        }

        return chunks
    }

    private static func findSplitIndex(
        in text: String,
        maxCharacters: Int,
        maxBytes: Int? = nil
    ) -> String.Index {
        var upperBoundIndex = text.index(text.startIndex, offsetBy: min(maxCharacters, text.count))
        if let maxBytes = maxBytes {
            while upperBoundIndex > text.startIndex && text[..<upperBoundIndex].utf8.count > maxBytes {
                upperBoundIndex = text.index(before: upperBoundIndex)
            }
            if upperBoundIndex == text.startIndex && !text.isEmpty {
                upperBoundIndex = text.index(after: text.startIndex)
            }
        }
        let searchSubstring = text[..<upperBoundIndex]

        // 1. Paragraph boundary (\n\n)
        if let range = searchSubstring.range(of: "\n\n", options: .backwards) {
            if range.upperBound > text.startIndex {
                return range.upperBound
            }
        }

        // 2. Single newline (\n)
        if let range = searchSubstring.range(of: "\n", options: .backwards) {
            if range.upperBound > text.startIndex {
                return range.upperBound
            }
        }

        // 3. Sentence punctuation (。！？.!? followed by space or punctuation)
        let punctuationChars: [Character] = ["。", "！", "？", ".", "!", "?", "；", ";"]
        var bestPunctIndex: String.Index?

        for p in punctuationChars {
            if let r = searchSubstring.range(of: String(p), options: .backwards) {
                if bestPunctIndex == nil || r.upperBound > bestPunctIndex! {
                    bestPunctIndex = r.upperBound
                }
            }
        }

        if let punct = bestPunctIndex, punct > text.startIndex {
            return punct
        }

        // 4. Whitespace
        if let range = searchSubstring.range(of: " ", options: .backwards) {
            if range.upperBound > text.startIndex {
                return range.upperBound
            }
        }

        // 5. Hard split fallback
        return upperBoundIndex
    }
}
