import Foundation
import Observation

@MainActor
@Observable
final class VoiceInputStore {
    var state: VoiceInputState = .idle
    var elapsedSeconds: Int = 0
    var errorMessage: String?

    private let recorder: any MicrophoneRecording
    private let permissionAuthorizer: any MicrophonePermissionAuthorizing
    private let resolver: VoiceInputResolver
    private let logs: DebugLogStore
    private weak var chatStore: ChatStore?

    private var timerTask: Task<Void, Never>?
    private var transcribingTask: Task<Void, Never>?
    private var currentAudioFileURL: URL?

    init(
        recorder: any MicrophoneRecording = MicrophoneRecorder(),
        permissionAuthorizer: any MicrophonePermissionAuthorizing = MacMicrophonePermissionAuthorizer(),
        resolver: VoiceInputResolver,
        chatStore: ChatStore? = nil,
        logs: DebugLogStore
    ) {
        self.recorder = recorder
        self.permissionAuthorizer = permissionAuthorizer
        self.resolver = resolver
        self.chatStore = chatStore
        self.logs = logs
    }

    /// Whether dictation goes into `store`'s composer.
    func isTarget(_ store: ChatStore) -> Bool {
        chatStore === store
    }

    func setChatStore(_ store: ChatStore) {
        self.chatStore = store
    }

    var isPermissionDenied: Bool {
        guard case .failed = state else { return false }
        let status = permissionAuthorizer.authorizationStatus()
        return status == .denied || status == .restricted
    }

    func clearError() {
        errorMessage = nil
        if case .failed = state {
            state = .idle
        }
    }

    /// Dictation only appends to the draft, so it stays available while a run is streaming,
    /// just like typing does.
    func start() {
        cancel()
        errorMessage = nil
        elapsedSeconds = 0

        let status = permissionAuthorizer.authorizationStatus()
        logs.info("VoiceInput", "Mic permission status before request: \(status.rawValue)")
        switch status {
        case .authorized:
            beginRecording()
        case .notDetermined:
            state = .requestingPermission
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let granted = await self.permissionAuthorizer.requestAccess()
                self.logs.info("VoiceInput", "Permission request completed: granted=\(granted)")
                guard !Task.isCancelled else { return }
                guard case .requestingPermission = self.state else { return }
                if granted {
                    self.beginRecording()
                } else {
                    let msg = String(localized: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
                    self.state = .failed(msg)
                    self.errorMessage = msg
                    self.logs.error("VoiceInput", msg)
                }
            }
        case .denied:
            let msg = String(localized: "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone.")
            state = .failed(msg)
            errorMessage = msg
            logs.error("VoiceInput", msg)
        case .restricted:
            let msg = String(localized: "Microphone access is restricted by system policy. Enable it in System Settings → Privacy & Security → Microphone.")
            state = .failed(msg)
            errorMessage = msg
            logs.error("VoiceInput", msg)
        }
    }

    private func beginRecording() {
        do {
            try recorder.startRecording()
            state = .recording(startedAt: Date())
            logs.info("VoiceInput", "Started voice recording.")
            startTimer()
        } catch {
            let msg = error.localizedDescription
            state = .failed(msg)
            errorMessage = msg
            logs.error("VoiceInput", "Failed to start microphone recording: \(error.localizedDescription)")
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard let self = self else { break }

                if case .recording = self.state {
                    self.elapsedSeconds += 1
                    if self.elapsedSeconds >= Int(MicrophoneRecorder.maxDurationSeconds) {
                        self.logs.info("VoiceInput", "Reached maximum recording duration (5m), auto-finishing...")
                        self.finish()
                        break
                    }
                } else {
                    break
                }
            }
        }
    }

    func finish() {
        timerTask?.cancel()
        timerTask = nil

        guard case .recording = state else { return }

        state = .transcribing
        logs.info("VoiceInput", "Finishing recording and beginning transcription...")

        let stopped: (fileURL: URL, duration: Double)
        do {
            stopped = try recorder.stopRecording()
        } catch {
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            logs.error("VoiceInput", "Failed to stop recording: \(error.localizedDescription)")
            return
        }

        let audioURL = stopped.fileURL
        let duration = stopped.duration
        self.currentAudioFileURL = audioURL

        transcribingTask = Task { [weak self, audioURL, duration] in
            guard let self = self else {
                try? FileManager.default.removeItem(at: audioURL)
                return
            }

            defer {
                try? FileManager.default.removeItem(at: audioURL)
                if self.currentAudioFileURL == audioURL {
                    self.currentAudioFileURL = nil
                }
            }

            do {
                let seed = Int.random(in: 0...100_000)
                let result = try await self.resolver.transcribe(audioFileURL: audioURL, duration: duration, sessionSeed: seed)
                guard !Task.isCancelled else { return }

                if let currentDraft = self.chatStore?.draft {
                    let updated = Self.smartAppend(draft: currentDraft, transcription: result.text)
                    self.chatStore?.draft = updated
                }

                self.state = .idle
                self.errorMessage = nil
                self.logs.info("VoiceInput", "Transcription complete. Inserted text into draft (\(result.source)).")
            } catch is CancellationError {
                self.state = .idle
                self.logs.info("VoiceInput", "Voice transcription was cancelled.")
            } catch {
                guard !Task.isCancelled else {
                    self.state = .idle
                    return
                }
                self.state = .failed(error.localizedDescription)
                self.errorMessage = error.localizedDescription
                self.logs.error("VoiceInput", "Voice transcription failed: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        timerTask?.cancel()
        timerTask = nil

        transcribingTask?.cancel()
        transcribingTask = nil

        recorder.cancelRecording()

        if let url = currentAudioFileURL {
            try? FileManager.default.removeItem(at: url)
            self.currentAudioFileURL = nil
        }

        state = .idle
        elapsedSeconds = 0
    }

    // MARK: - Smart Draft Appending

    nonisolated static func smartAppend(draft: String, transcription: String) -> String {
        let trimmedTranscription = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscription.isEmpty else { return draft }
        guard !draft.isEmpty else { return trimmedTranscription }

        guard let lastChar = draft.last, let firstChar = trimmedTranscription.first else {
            return draft + trimmedTranscription
        }

        if lastChar.isWhitespace || lastChar.isNewline {
            return draft + trimmedTranscription
        }

        if isCJK(lastChar) || isCJK(firstChar) {
            return draft + trimmedTranscription
        }

        return draft + " " + trimmedTranscription
    }

    nonisolated static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)       // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(value)       // CJK Extension A
            || (0x20000...0x2A6DF).contains(value)     // CJK Extension B
            || (0x3000...0x303F).contains(value)       // CJK Symbols and Punctuation
            || (0xFF00...0xFFEF).contains(value)       // Halfwidth and Fullwidth Forms
            || (0x3040...0x309F).contains(value)       // Hiragana
            || (0x30A0...0x30FF).contains(value)       // Katakana
            || (0xAC00...0xD7AF).contains(value)       // Hangul Syllables
    }
}
