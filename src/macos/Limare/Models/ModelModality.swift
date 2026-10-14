import Foundation

/// 9-bit modality flags representing input and output capabilities of an LLM model.
public struct ModelModality: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    // Input Modalities
    public static let textInput      = ModelModality(rawValue: 1 << 0)
    public static let textOutput     = ModelModality(rawValue: 1 << 1)
    public static let imageInput     = ModelModality(rawValue: 1 << 2)
    public static let pdfInput       = ModelModality(rawValue: 1 << 3)
    public static let audioInput     = ModelModality(rawValue: 1 << 4)
    public static let videoInput     = ModelModality(rawValue: 1 << 5)

    // Output Modalities
    public static let imageOutput    = ModelModality(rawValue: 1 << 6)
    public static let audioOutput    = ModelModality(rawValue: 1 << 7)
    public static let videoOutput    = ModelModality(rawValue: 1 << 8)

    // Direction-scoped aggregations
    public static let allInputs: ModelModality = [.textInput, .imageInput, .pdfInput, .audioInput, .videoInput]
    public static let allOutputs: ModelModality = [.textOutput, .imageOutput, .audioOutput, .videoOutput]

    /// Just the input-side modalities of this set.
    public var inputs: ModelModality { intersection(.allInputs) }
    /// Just the output-side modalities of this set.
    public var outputs: ModelModality { intersection(.allOutputs) }

    // Common capability presets
    public static let textOnly: ModelModality = [.textInput, .textOutput]
    public static let vision: ModelModality = [.textInput, .textOutput, .imageInput, .pdfInput]
    public static let fullMultimodalInput: ModelModality = [.textInput, .textOutput, .imageInput, .pdfInput, .audioInput, .videoInput]
    public static let fullMultimodal: ModelModality = .fullMultimodalInput
}

/// Modality check for dedicated Audio-to-Text / Speech-to-Text models.
/// Requires audio input ONLY (no text/image/video input) and text output.
public func isDedicatedASR(_ model: ProviderModel) -> Bool {
    guard let modality = model.modality else { return false }
    return modality.inputs == .audioInput && modality.contains(.textOutput)
}

/// Modality check for dedicated Text-to-Speech models.
/// Requires text input ONLY and audio output ONLY (e.g. [.textInput, .audioOutput]).
public func isDedicatedTTS(_ model: ProviderModel) -> Bool {
    guard let modality = model.modality else { return false }
    return modality.inputs == .textInput && modality.outputs == .audioOutput
}
