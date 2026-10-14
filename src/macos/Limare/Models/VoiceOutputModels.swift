import Foundation

public enum VoiceOutputDefaults {
    public static let cloudVoice = "alloy"
    public static let responseFormat = "mp3"
    public static let maxChunkCharacters = 3500
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
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noSpeakableText:
            return "No speakable text found in message."
        case .invalidAudioResponse(let reason):
            return "Invalid audio response from TTS provider: \(reason)"
        case .audioTooLarge(let bytes):
            return "Synthesized audio exceeded maximum size limit (\(bytes) bytes)."
        case .synthesisFailed(let reason):
            return "Voice synthesis failed: \(reason)"
        case .networkError(let reason):
            return "Network error during voice synthesis: \(reason)"
        case .playbackFailed(let reason):
            return "Audio playback failed: \(reason)"
        case .cancelled:
            return "Voice output was cancelled."
        }
    }
}

/// Current state of the voice output playback.
public enum VoiceOutputState: Equatable, Sendable {
    case idle
    case preparing(messageID: UUID)
    case playing(messageID: UUID, engineLabel: String)
    case failed(messageID: UUID, message: String)

    public var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    public var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    public var activeMessageID: UUID? {
        switch self {
        case .preparing(let id), .playing(let id, _):
            return id
        case .idle, .failed:
            return nil
        }
    }
}

/// Synthesis output prepared for playback.
public enum PreparedVoiceOutput: Sendable {
    case cloud(
        segments: [Data],
        providerID: UUID,
        modelID: String,
        label: String
    )
    case system(
        text: String,
        fallbackReason: String? = nil
    )
}
