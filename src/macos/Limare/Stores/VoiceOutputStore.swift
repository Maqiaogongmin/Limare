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

    /// Speaker button: starts reading, then pauses and resumes the active message. A tap while
    /// the first chunk is still being synthesized cancels it.
    func toggle(messageID: UUID, text: String) {
        guard state.activeMessageID == messageID else {
            play(messageID: messageID, text: text)
            return
        }
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .preparing, .idle, .failed:
            stop()
        }
    }

    func play(messageID: UUID, text: String) {
        stop()

        let sessionID = UUID()
        activeSessionID = sessionID
        errorMessage = nil
        lastFallbackReason = nil

        if let cached = cachedAudio,
           cached.messageID == messageID,
           cached.text == text,
           cached.configurationKey == resolver.configurationKey {
            state = .playing(messageID: messageID, engineLabel: cached.label)
            logs.info("VoiceOutput", "Replaying \(cached.segments.count) cached segments for message \(messageID).")
            runSession(sessionID, messageID: messageID) { store in
                for segment in cached.segments {
                    guard store.isActive(sessionID) else { return }
                    try await store.audioPlayer.play(data: segment)
                }
            }
            return
        }

        state = .preparing(messageID: messageID)
        runSession(sessionID, messageID: messageID) { store in
            let seed = Int.random(in: 0...100_000)
            let prepared = try await store.resolver.prepare(text: text, sessionSeed: seed)
            guard store.isActive(sessionID) else { return }

            switch prepared {
            case .cloud(let synthesis):
                store.state = .playing(messageID: messageID, engineLabel: synthesis.label)
                try await store.playCloud(synthesis, sessionID: sessionID, messageID: messageID, text: text)

            case .system(let sanitizedText, let fallbackReason):
                store.lastFallbackReason = fallbackReason
                let engineLabel: String = {
                    if let fallbackReason, !fallbackReason.isEmpty {
                        return String(localized: "System Voice (Fallback: \(fallbackReason))")
                    } else {
                        return String(localized: "System Voice")
                    }
                }()
                store.state = .playing(messageID: messageID, engineLabel: engineLabel)
                try await store.systemSpeaker.speak(text: sanitizedText)
            }
        }
    }

    func pause() {
        guard case .playing(let messageID, let engineLabel) = state else { return }
        audioPlayer.pause()
        systemSpeaker.pause()
        state = .paused(messageID: messageID, engineLabel: engineLabel)
    }

    func resume() {
        guard case .paused(let messageID, let engineLabel) = state else { return }
        state = .playing(messageID: messageID, engineLabel: engineLabel)
        audioPlayer.resume()
        systemSpeaker.resume()
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

    func clearError() {
        errorMessage = nil
        if case .failed = state {
            state = .idle
        }
    }

    // MARK: - Session

    private struct CachedAudio {
        let messageID: UUID
        let text: String
        let configurationKey: String?
        let label: String
        let segments: [Data]
    }

    /// The last message whose every chunk was synthesized, so stopping and replaying it does
    /// not synthesize it again.
    private var cachedAudio: CachedAudio?

    private func isActive(_ sessionID: UUID) -> Bool {
        !Task.isCancelled && activeSessionID == sessionID
    }

    private func runSession(
        _ sessionID: UUID,
        messageID: UUID,
        body: @escaping @MainActor (VoiceOutputStore) async throws -> Void
    ) {
        playbackTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await body(self)
                if self.isActive(sessionID) {
                    self.state = .idle
                }
            } catch is CancellationError {
                if self.activeSessionID == sessionID {
                    self.state = .idle
                    self.logs.info("VoiceOutput", "Voice output playback was cancelled.")
                }
            } catch {
                guard self.isActive(sessionID) else { return }
                self.audioPlayer.stop()
                self.systemSpeaker.stop()
                self.state = .failed(messageID: messageID, message: error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.logs.error("VoiceOutput", "Voice output failed for message \(messageID): \(error.localizedDescription)")
            }
        }
    }

    /// Plays the first segment at once while the remaining chunks are synthesized in order in
    /// the background; each segment plays as soon as it and everything before it is ready.
    private func playCloud(
        _ synthesis: CloudVoiceSynthesis,
        sessionID: UUID,
        messageID: UUID,
        text: String
    ) async throws {
        let total = synthesis.chunks.count
        let configurationKey = resolver.configurationKey
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task { @MainActor [weak self] in
            var segments = [synthesis.firstSegment]
            do {
                for (offset, chunk) in synthesis.remainingChunks.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let segment = try await synthesis.synthesize(chunk)
                        segments.append(segment)
                        continuation.yield(segment)
                    } catch {
                        if VoiceOutputResolver.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                        throw VoiceOutputError.partFailed(part: offset + 2, total: total, reason: error.localizedDescription)
                    }
                }
                continuation.finish()
                self?.cachedAudio = CachedAudio(
                    messageID: messageID,
                    text: text,
                    configurationKey: configurationKey,
                    label: synthesis.label,
                    segments: segments
                )
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { producer.cancel() }

        try await audioPlayer.play(data: synthesis.firstSegment)
        for try await segment in stream {
            guard isActive(sessionID) else { return }
            try await audioPlayer.play(data: segment)
        }
    }
}
