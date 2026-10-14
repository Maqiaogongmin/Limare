import Foundation
import AVFoundation

public protocol SystemSpeechSpeaking: AnyObject, Sendable {
    func speak(text: String) async throws
    func stop()
}

public final class SystemSpeechSpeaker: NSObject, SystemSpeechSpeaking, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var activeContinuation: CheckedContinuation<Void, Error>?
    private var activeUtteranceID: ObjectIdentifier?
    private var isCurrentlySpeaking = false

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(text: String) async throws {
        stop()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        let utteranceID = ObjectIdentifier(utterance)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.activeContinuation = continuation
                self.activeUtteranceID = utteranceID
                self.isCurrentlySpeaking = true
                lock.unlock()

                synthesizer.speak(utterance)
            }
        } onCancel: {
            self.stop()
        }
    }

    public func stop() {
        lock.lock()
        let continuation = activeContinuation
        activeContinuation = nil
        activeUtteranceID = nil
        isCurrentlySpeaking = false
        lock.unlock()

        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume(throwing: CancellationError())
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lock.lock()
        guard activeUtteranceID == ObjectIdentifier(utterance) else {
            lock.unlock()
            return
        }
        let continuation = activeContinuation
        activeContinuation = nil
        activeUtteranceID = nil
        isCurrentlySpeaking = false
        lock.unlock()

        continuation?.resume()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        lock.lock()
        guard activeUtteranceID == ObjectIdentifier(utterance) else {
            lock.unlock()
            return
        }
        let continuation = activeContinuation
        activeContinuation = nil
        activeUtteranceID = nil
        isCurrentlySpeaking = false
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}
