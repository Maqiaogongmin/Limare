import Foundation
import AVFoundation

public protocol AudioDataValidating: Sendable {
    func validate(_ data: Data) throws
}

public struct AVAudioDataValidator: AudioDataValidating {
    public init() {}

    public func validate(_ data: Data) throws {
        guard !data.isEmpty else {
            throw VoiceOutputError.invalidAudioResponse("Audio data is empty.")
        }
        do {
            let player = try AVAudioPlayer(data: data)
            guard player.duration >= 0 else {
                throw VoiceOutputError.invalidAudioResponse("Audio decoder reported invalid negative duration.")
            }
        } catch let err as VoiceOutputError {
            throw err
        } catch {
            throw VoiceOutputError.invalidAudioResponse("Corrupted or unsupported audio data: \(error.localizedDescription)")
        }
    }
}
