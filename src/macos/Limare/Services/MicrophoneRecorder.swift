import Foundation
import AVFoundation

public protocol MicrophoneRecording: AnyObject, Sendable {
    var isRecordingActive: Bool { get }
    func startRecording() throws
    func stopRecording() throws -> (fileURL: URL, duration: Double)
    func cancelRecording()
}

public final class MicrophoneRecorder: MicrophoneRecording, @unchecked Sendable {
    private var audioEngine: AVAudioEngine?
    private var tempFileURL: URL?
    private var pcmData: Data = Data()
    private let lock = NSLock()
    private var isRecording = false
    private var recordingStartTime: Date?

    public static let minDurationSeconds: Double = 0.25
    public static let maxDurationSeconds: Double = 300.0 // 5 minutes
    public static let maxRecordedBytes: Int = 300 * 16000 * 2 // 9,600,000 bytes for 5m at 16kHz mono PCM16
    public static let maxFileSizeBytes: Int64 = 25 * 1024 * 1024 // 25 MB

    public var isRecordingActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
    }

    public init() {}

    public func startRecording() throws {
        lock.lock()
        defer { lock.unlock() }

        if isRecording {
            cleanupInternal()
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceInputError.recordingFailed(String(localized: "Invalid audio input format from microphone."))
        }

        // Target: 16000 Hz, 1 channel (mono), Int16 PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw VoiceInputError.recordingFailed(String(localized: "Failed to create target audio format."))
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceInputError.recordingFailed(String(localized: "Failed to create audio converter."))
        }

        self.pcmData = Data()
        self.recordingStartTime = Date()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard frameCount > 0,
                  let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount + 1024) else {
                return
            }

            var error: NSError?
            var allConsumed = false
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                if allConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                allConsumed = true
                return buffer
            }

            let status = converter.convert(to: targetBuffer, error: &error, withInputFrom: inputBlock)
            if status == .haveData || status == .inputRanDry {
                if let channelData = targetBuffer.int16ChannelData {
                    let bytes = Int(targetBuffer.frameLength) * 2
                    let chunk = Data(bytes: channelData[0], count: bytes)
                    self.lock.lock()
                    let currentCount = self.pcmData.count
                    if currentCount < MicrophoneRecorder.maxRecordedBytes && Int64(currentCount + chunk.count) <= MicrophoneRecorder.maxFileSizeBytes {
                        let allowedBytes = min(chunk.count, MicrophoneRecorder.maxRecordedBytes - currentCount)
                        if allowedBytes > 0 {
                            self.pcmData.append(chunk.prefix(allowedBytes))
                        }
                    }
                    self.lock.unlock()
                }
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            self.isRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
            self.isRecording = false
            self.pcmData = Data()
            self.recordingStartTime = nil
            throw VoiceInputError.recordingFailed(String(localized: "Failed to start audio engine: \(error.localizedDescription)"))
        }
    }

    public func stopRecording() throws -> (fileURL: URL, duration: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard isRecording else {
            throw VoiceInputError.recordingFailed(String(localized: "Recorder was not active."))
        }

        let recordedData = pcmData
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0.0

        cleanupInternal()

        guard duration >= MicrophoneRecorder.minDurationSeconds else {
            throw VoiceInputError.audioTooShort(duration)
        }

        guard !recordedData.isEmpty else {
            throw VoiceInputError.emptyAudio
        }

        let wavData = MicrophoneRecorder.createWAVData(fromPCM16: recordedData, sampleRate: 16000, channels: 1)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("limare-voice-\(UUID().uuidString).wav")
        try wavData.write(to: tempURL, options: .atomic)
        self.tempFileURL = tempURL

        return (tempURL, duration)
    }

    public func cancelRecording() {
        lock.lock()
        defer { lock.unlock() }
        cleanupInternal()
    }

    private func cleanupInternal() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.audioEngine = nil
        }
        self.isRecording = false
        self.pcmData = Data()
        self.recordingStartTime = nil
        if let url = tempFileURL {
            try? FileManager.default.removeItem(at: url)
            self.tempFileURL = nil
        }
    }

    public static func createWAVData(fromPCM16 pcmData: Data, sampleRate: UInt32 = 16000, channels: UInt16 = 1) -> Data {
        var header = Data()
        let totalDataLen = UInt32(pcmData.count)
        let totalChunkSize = totalDataLen + 36
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        let bitsPerSample: UInt16 = 16

        // RIFF header
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        var chunkSizeLE = totalChunkSize.littleEndian
        header.append(Data(bytes: &chunkSizeLE, count: 4))
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " subchunk
        header.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // "fmt "
        var subchunk1SizeLE = UInt32(16).littleEndian
        header.append(Data(bytes: &subchunk1SizeLE, count: 4))
        var audioFormatLE = UInt16(1).littleEndian // PCM = 1
        header.append(Data(bytes: &audioFormatLE, count: 2))
        var numChannelsLE = channels.littleEndian
        header.append(Data(bytes: &numChannelsLE, count: 2))
        var sampleRateLE = sampleRate.littleEndian
        header.append(Data(bytes: &sampleRateLE, count: 4))
        var byteRateLE = byteRate.littleEndian
        header.append(Data(bytes: &byteRateLE, count: 4))
        var blockAlignLE = blockAlign.littleEndian
        header.append(Data(bytes: &blockAlignLE, count: 2))
        var bitsPerSampleLE = bitsPerSample.littleEndian
        header.append(Data(bytes: &bitsPerSampleLE, count: 2))

        // "data" subchunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        var subchunk2SizeLE = totalDataLen.littleEndian
        header.append(Data(bytes: &subchunk2SizeLE, count: 4))

        var fullData = header
        fullData.append(pcmData)
        return fullData
    }

    public static func validateWAVHeader(data: Data) -> (isValid: Bool, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataSize: UInt32)? {
        guard data.count >= 44 else { return nil }
        guard data[0...3] == Data([0x52, 0x49, 0x46, 0x46]) else { return nil } // "RIFF"
        guard data[8...11] == Data([0x57, 0x41, 0x56, 0x45]) else { return nil } // "WAVE"
        guard data[12...15] == Data([0x66, 0x6d, 0x74, 0x20]) else { return nil } // "fmt "
        guard data[36...39] == Data([0x64, 0x61, 0x74, 0x61]) else { return nil } // "data"

        let audioFormat = data[20...21].withUnsafeBytes { $0.load(as: UInt16.self) }
        guard audioFormat == 1 else { return nil } // PCM

        let channels = data[22...23].withUnsafeBytes { $0.load(as: UInt16.self) }
        let sampleRate = data[24...27].withUnsafeBytes { $0.load(as: UInt32.self) }
        let bitsPerSample = data[34...35].withUnsafeBytes { $0.load(as: UInt16.self) }
        let dataSize = data[40...43].withUnsafeBytes { $0.load(as: UInt32.self) }

        return (isValid: true, sampleRate: sampleRate, channels: channels, bitsPerSample: bitsPerSample, dataSize: dataSize)
    }
}
