import Foundation

/// The result of a voice transcription request.
public struct VoiceTranscriptionResult: Equatable, Sendable {
    public let text: String
    public let providerID: UUID?
    public let modelID: String?
    public let source: String // "cloud" or "system_speech"
    public let durationSeconds: Double?

    public init(
        text: String,
        providerID: UUID? = nil,
        modelID: String? = nil,
        source: String,
        durationSeconds: Double? = nil
    ) {
        self.text = text
        self.providerID = providerID
        self.modelID = modelID
        self.source = source
        self.durationSeconds = durationSeconds
    }
}

/// Errors occurring during voice recording, cloud transcription, or local speech recognition.
public enum VoiceInputError: LocalizedError, Equatable, Sendable {
    case emptyAudio
    case audioTooShort(Double)
    case audioTooLong(Double)
    case audioTooLarge(Int64)
    case recordingFailed(String)
    case systemSpeechPermissionDenied
    case systemSpeechRestricted
    case systemSpeechUnavailable(String)
    case systemSpeechRecognitionFailed(String)
    case transcriptionFailed(String)
    case networkError(String)
    case emptyTranscription
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "No audio was recorded."
        case .audioTooShort(let duration):
            return String(format: "Audio recording was too short (%.2fs). Please speak longer.", duration)
        case .audioTooLong(let duration):
            return String(format: "Audio recording exceeded maximum limit of %.0fs.", duration)
        case .audioTooLarge(let bytes):
            return "Audio recording exceeded maximum size limit (\(bytes) bytes)."
        case .recordingFailed(let reason):
            return "Microphone recording failed: \(reason)"
        case .systemSpeechPermissionDenied:
            return "Speech recognition permission was denied. Please enable it in macOS System Settings."
        case .systemSpeechRestricted:
            return "Speech recognition is restricted on this device."
        case .systemSpeechUnavailable(let reason):
            return "System speech recognizer is unavailable: \(reason)"
        case .systemSpeechRecognitionFailed(let reason):
            return "System speech recognition failed: \(reason)"
        case .transcriptionFailed(let reason):
            return "Voice transcription failed: \(reason)"
        case .networkError(let reason):
            return "Network error during voice transcription: \(reason)"
        case .emptyTranscription:
            return "No speech was recognized."
        case .cancelled:
            return "Voice transcription was cancelled."
        }
    }
}

/// Current state of the voice input UI and recording pipeline.
public enum VoiceInputState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording(startedAt: Date)
    case transcribing
    case failed(String)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    public var isTranscribing: Bool {
        if case .transcribing = self { return true }
        return false
    }

    public var isActive: Bool {
        switch self {
        case .recording, .transcribing, .requestingPermission:
            return true
        case .idle, .failed:
            return false
        }
    }
}
