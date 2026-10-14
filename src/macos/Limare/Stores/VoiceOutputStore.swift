import Foundation
import Observation

@MainActor
@Observable
final class VoiceOutputStore {
    var state: VoiceOutputState = .idle
    var errorMessage: String?
    var lastFallbackReason: String?

    private let resolver: VoiceOutputResolver
    private let audioPlayer: any AudioDataPlaying
    private let systemSpeaker: any SystemSpeechSpeaking
    private let logs: DebugLogStore

    private var playbackTask: Task<Void, Never>?
    private var activeSessionID: UUID?

    init(
        resolver: VoiceOutputResolver,
        audioPlayer: any AudioDataPlaying = AudioDataPlayer(),
        systemSpeaker: any SystemSpeechSpeaking = SystemSpeechSpeaker(),
        logs: DebugLogStore
    ) {
        self.resolver = resolver
        self.audioPlayer = audioPlayer
        self.systemSpeaker = systemSpeaker
        self.logs = logs
    }

    func toggle(messageID: UUID, text: String) {
        if state.activeMessageID == messageID {
            stop()
        } else {
            play(messageID: messageID, text: text)
        }
    }

    func play(messageID: UUID, text: String) {
        stop()

        let sessionID = UUID()
        activeSessionID = sessionID

        state = .preparing(messageID: messageID)
        errorMessage = nil
        lastFallbackReason = nil

        playbackTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            do {
                let seed = Int.random(in: 0...100_000)
                let prepared = try await self.resolver.prepare(text: text, sessionSeed: seed)
                guard !Task.isCancelled, self.activeSessionID == sessionID else {
                    if self.activeSessionID == sessionID {
                        self.state = .idle
                    }
                    return
                }

                switch prepared {
                case .cloud(let segments, _, _, let label):
                    guard self.activeSessionID == sessionID else { return }
                    self.state = .playing(messageID: messageID, engineLabel: label)
                    for segment in segments {
                        guard !Task.isCancelled, self.activeSessionID == sessionID else { break }
                        try await self.audioPlayer.play(data: segment)
                    }

                case .system(let sanitizedText, let fallbackReason):
                    guard self.activeSessionID == sessionID else { return }
                    self.lastFallbackReason = fallbackReason
                    let engineLabel: String = {
                        if let fallbackReason, !fallbackReason.isEmpty {
                            return "System Voice (Fallback: \(fallbackReason))"
                        } else {
                            return "System Voice"
                        }
                    }()
                    self.state = .playing(messageID: messageID, engineLabel: engineLabel)
                    try await self.systemSpeaker.speak(text: sanitizedText)
                }

                if !Task.isCancelled && self.activeSessionID == sessionID {
                    self.state = .idle
                }
            } catch is CancellationError {
                if self.activeSessionID == sessionID {
                    self.state = .idle
                    self.logs.info("VoiceOutput", "Voice output playback was cancelled.")
                }
            } catch {
                guard !Task.isCancelled, self.activeSessionID == sessionID else {
                    return
                }
                self.state = .failed(messageID: messageID, message: error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.logs.error("VoiceOutput", "Voice output failed for message \(messageID): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        activeSessionID = nil
        playbackTask?.cancel()
        playbackTask = nil

        audioPlayer.stop()
        systemSpeaker.stop()

        state = .idle
        lastFallbackReason = nil
    }
}
