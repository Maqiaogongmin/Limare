import Foundation
import AVFoundation

public protocol AudioDataPlaying: AnyObject, Sendable {
    func play(data: Data) async throws
    func stop()
}

public final class AudioDataPlayer: AudioDataPlaying, @unchecked Sendable {
    private var player: AVAudioPlayer?
    private var playerDelegate: InternalPlayerDelegate?
    private var activePlayerID: ObjectIdentifier?
    private let lock = NSLock()
    private var activeContinuation: CheckedContinuation<Void, Error>?

    public init() {}

    public func play(data: Data) async throws {
        stop()

        guard !data.isEmpty else {
            throw VoiceOutputError.playbackFailed("Cannot play empty audio data.")
        }

        let audioPlayer: AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(data: data)
        } catch {
            throw VoiceOutputError.playbackFailed("Invalid audio format: \(error.localizedDescription)")
        }

        let playerID = ObjectIdentifier(audioPlayer)
        let delegate = InternalPlayerDelegate { [weak self] success, error in
            self?.handleFinish(playerID: playerID, success: success, error: error)
        }
        audioPlayer.delegate = delegate
        audioPlayer.prepareToPlay()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.player = audioPlayer
                self.playerDelegate = delegate
                self.activePlayerID = playerID
                self.activeContinuation = continuation
                let started = audioPlayer.play()
                lock.unlock()

                if !started {
                    lock.lock()
                    let cont = self.activeContinuation
                    self.activeContinuation = nil
                    self.activePlayerID = nil
                    self.player = nil
                    self.playerDelegate = nil
                    lock.unlock()
                    cont?.resume(throwing: VoiceOutputError.playbackFailed("Failed to start audio playback."))
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    public func stop() {
        lock.lock()
        let currentPlayer = player
        let continuation = activeContinuation
        activeContinuation = nil
        activePlayerID = nil
        player = nil
        playerDelegate = nil
        lock.unlock()

        currentPlayer?.stop()
        continuation?.resume(throwing: CancellationError())
    }

    private func handleFinish(playerID: ObjectIdentifier, success: Bool, error: Error?) {
        lock.lock()
        guard activePlayerID == playerID else {
            lock.unlock()
            return
        }
        let continuation = activeContinuation
        activeContinuation = nil
        activePlayerID = nil
        player = nil
        playerDelegate = nil
        lock.unlock()

        if let error {
            continuation?.resume(throwing: VoiceOutputError.playbackFailed(error.localizedDescription))
        } else if success {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: VoiceOutputError.playbackFailed("Audio playback did not complete successfully."))
        }
    }
}

private final class InternalPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onComplete: @Sendable (Bool, Error?) -> Void

    nonisolated init(onComplete: @escaping @Sendable (Bool, Error?) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onComplete(flag, nil)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onComplete(false, error)
    }
}
