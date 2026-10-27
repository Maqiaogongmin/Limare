import Foundation

public enum VoiceOutputDefaults {
    public static let cloudVoice = "alloy"
    public static let responseFormat = "mp3"
    public static let maxChunkCharacters = 3500
    /// The first cloud chunk is kept short so audio starts after one quick request; each later
    /// chunk may grow by `chunkGrowthFactor` (up to the provider limit) because it is
    /// synthesized in the background while the previous one plays.
    public static let firstChunkCharacters = 200
    public static let chunkGrowthFactor = 2
    public static let maxSegmentBytes: Int64 = 25 * 1024 * 1024 // 25 MB
}

/// Errors occurring during text sanitization, cloud synthesis, or audio playback.
public enum VoiceOutputError: LocalizedError, Equatable, Sendable {
    case noSpeakableText
    case invalidAudioResponse(String)
    case audioTooLarge(Int64)
    case synthesisFailed(String)
    case networkError(String)
    case playbackFailed(String)
    /// A later chunk failed after earlier parts were already spoken.
    case partFailed(part: Int, total: Int, reason: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noSpeakableText:
            return String(localized: "No speakable text found in message.")
        case .invalidAudioResponse(let reason):
            return String(localized: "Invalid audio response from TTS provider: \(reason)")
        case .audioTooLarge(let bytes):
            return String(localized: "Synthesized audio exceeded maximum size limit (\(bytes) bytes).")
        case .synthesisFailed(let reason):
            return String(localized: "Voice synthesis failed: \(reason)")
        case .networkError(let reason):
            return String(localized: "Network error during voice synthesis: \(reason)")
        case .playbackFailed(let reason):
            return String(localized: "Audio playback failed: \(reason)")
        case .partFailed(let part, let total, let reason):
            return String(localized: "Stopped reading at part \(part)/\(total): \(reason)")
        case .cancelled:
            return String(localized: "Voice output was cancelled.")
        }
    }
}

/// Current state of the voice output playback.
public enum VoiceOutputState: Equatable, Sendable {
    case idle
    case preparing(messageID: UUID)
    case playing(messageID: UUID, engineLabel: String)
    case paused(messageID: UUID, engineLabel: String)
    case failed(messageID: UUID, message: String)

    public var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var activeMessageID: UUID? {
        switch self {
        case .preparing(let id), .playing(let id, _), .paused(let id, _):
            return id
        case .idle, .failed:
            return nil
        }
    }
}

/// A cloud candidate that synthesized the first chunk. The remaining chunks are synthesized
/// with the same candidate while earlier audio plays, so a long message starts speaking after
/// one short request instead of after the whole text.
public struct CloudVoiceSynthesis: Sendable {
    public let providerID: UUID
    public let modelID: String
    public let label: String
    public let chunks: [String]
    public let firstSegment: Data
    /// Synthesizes and validates one chunk with this candidate.
    public let synthesize: @Sendable (String) async throws -> Data

    public var remainingChunks: ArraySlice<String> { chunks.dropFirst() }
}

/// Synthesis output prepared for playback.
public enum PreparedVoiceOutput: Sendable {
    case cloud(CloudVoiceSynthesis)
    case system(
        text: String,
        fallbackReason: String? = nil
    )
}
