import Foundation
import Speech

public protocol SystemSpeechTranscribing: Sendable {
    func transcribe(audioFileURL: URL) async throws -> String
}

public final class SystemSpeechTranscriber: SystemSpeechTranscribing, @unchecked Sendable {
    public init() {}

    public func transcribe(audioFileURL: URL) async throws -> String {
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard authStatus == .authorized else {
            switch authStatus {
            case .authorized:
                break
            case .denied:
                throw VoiceInputError.systemSpeechPermissionDenied
            case .restricted:
                throw VoiceInputError.systemSpeechRestricted
            case .notDetermined:
                throw VoiceInputError.systemSpeechPermissionDenied
            @unknown default:
                throw VoiceInputError.systemSpeechUnavailable(String(localized: "Unknown authorization status"))
            }
            throw VoiceInputError.systemSpeechPermissionDenied
        }

        let locale = Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw VoiceInputError.systemSpeechUnavailable(String(localized: "Speech recognizer unavailable for locale \(locale.identifier)"))
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        final class RecognitionBox: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
            var hasResumed = false
            let lock = NSLock()
        }

        let box = RecognitionBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.lock.lock()
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    box.lock.lock()
                    defer { box.lock.unlock() }

                    if box.hasResumed { return }

                    if Task.isCancelled {
                        box.hasResumed = true
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if let error = error {
                        box.hasResumed = true
                        let nsErr = error as NSError
                        if (nsErr.domain == "kAFAssistantErrorDomain" && (nsErr.code == 203 || nsErr.code == 216)) ||
                           (nsErr.domain == "kLSRErrorDomain" && (nsErr.code == 203 || nsErr.code == 216 || nsErr.code == 301)) {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: VoiceInputError.systemSpeechRecognitionFailed(error.localizedDescription))
                        }
                        return
                    }

                    if let result = result, result.isFinal {
                        box.hasResumed = true
                        let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !transcription.isEmpty else {
                            continuation.resume(throwing: VoiceInputError.emptyTranscription)
                            return
                        }
                        continuation.resume(returning: transcription)
                    }
                }
                box.lock.unlock()
            }
        } onCancel: {
            box.lock.lock()
            box.task?.cancel()
            box.lock.unlock()
        }
    }
}
