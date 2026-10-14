import Foundation

/// Per-field 3-state modality customizations: `nil` = Auto, `true` = Supported, `false` = Unsupported.
public struct ModalityOverrides: Codable, Hashable, Sendable {
    public var textInput: Bool?
    public var textOutput: Bool?
    public var vision: Bool?
    public var pdfInput: Bool?
    public var audioInput: Bool?
    public var videoInput: Bool?

    public var imageOutput: Bool?
    public var audioOutput: Bool?
    public var videoOutput: Bool?

    public init(
        textInput: Bool? = nil,
        textOutput: Bool? = nil,
        vision: Bool? = nil,
        pdfInput: Bool? = nil,
        audioInput: Bool? = nil,
        videoInput: Bool? = nil,
        imageOutput: Bool? = nil,
        audioOutput: Bool? = nil,
        videoOutput: Bool? = nil
    ) {
        self.textInput = textInput
        self.textOutput = textOutput
        self.vision = vision
        self.pdfInput = pdfInput
        self.audioInput = audioInput
        self.videoInput = videoInput
        self.imageOutput = imageOutput
        self.audioOutput = audioOutput
        self.videoOutput = videoOutput
    }

    public var isEmpty: Bool {
        textInput == nil &&
        textOutput == nil &&
        vision == nil &&
        pdfInput == nil &&
        audioInput == nil &&
        videoInput == nil &&
        imageOutput == nil &&
        audioOutput == nil &&
        videoOutput == nil
    }
}

/// User-editable customizations layered on top of a model's base discovery metadata.
public struct ModelOverrides: Codable, Hashable, Sendable {
    public var displayName: String?
    public var maxOutputTokens: Int?
    public var modalityOverrides: ModalityOverrides?
    public var contextWindow: Int?
    public var supportsReasoning: Bool?
    public var maxThinkingLevel: String?

    public init(
        displayName: String? = nil,
        maxOutputTokens: Int? = nil,
        modalityOverrides: ModalityOverrides? = nil,
        contextWindow: Int? = nil,
        supportsReasoning: Bool? = nil,
        maxThinkingLevel: String? = nil
    ) {
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.modalityOverrides = modalityOverrides
        self.contextWindow = contextWindow
        self.supportsReasoning = supportsReasoning
        self.maxThinkingLevel = maxThinkingLevel
    }

    /// Legacy convenience initializer taking ModelModality OptionSet.
    public init(
        displayName: String? = nil,
        maxOutputTokens: Int? = nil,
        modalityOverride: ModelModality?,
        contextWindow: Int? = nil,
        supportsReasoning: Bool? = nil,
        maxThinkingLevel: String? = nil
    ) {
        self.displayName = displayName
        self.maxOutputTokens = maxOutputTokens
        self.contextWindow = contextWindow
        self.supportsReasoning = supportsReasoning
        self.maxThinkingLevel = maxThinkingLevel
        if let mod = modalityOverride {
            self.modalityOverrides = ModalityOverrides(
                textInput: mod.contains(.textInput),
                textOutput: mod.contains(.textOutput),
                vision: mod.contains(.imageInput),
                pdfInput: mod.contains(.pdfInput),
                audioInput: mod.contains(.audioInput),
                videoInput: mod.contains(.videoInput),
                imageOutput: mod.contains(.imageOutput),
                audioOutput: mod.contains(.audioOutput),
                videoOutput: mod.contains(.videoOutput)
            )
        } else {
            self.modalityOverrides = nil
        }
    }

    /// Legacy computed property providing transparent OptionSet bridging for older call sites.
    public var modalityOverride: ModelModality? {
        get {
            guard let overrides = modalityOverrides, !overrides.isEmpty else { return nil }
            var result: ModelModality = [.textInput, .textOutput]
            if overrides.textInput == true { result.insert(.textInput) }
            if overrides.textInput == false { result.remove(.textInput) }
            if overrides.textOutput == true { result.insert(.textOutput) }
            if overrides.textOutput == false { result.remove(.textOutput) }
            if overrides.vision == true { result.insert(.imageInput) }
            if overrides.vision == false { result.remove(.imageInput) }
            if overrides.pdfInput == true { result.insert(.pdfInput) }
            if overrides.pdfInput == false { result.remove(.pdfInput) }
            if overrides.audioInput == true { result.insert(.audioInput) }
            if overrides.audioInput == false { result.remove(.audioInput) }
            if overrides.videoInput == true { result.insert(.videoInput) }
            if overrides.videoInput == false { result.remove(.videoInput) }
            if overrides.imageOutput == true { result.insert(.imageOutput) }
            if overrides.imageOutput == false { result.remove(.imageOutput) }
            if overrides.audioOutput == true { result.insert(.audioOutput) }
            if overrides.audioOutput == false { result.remove(.audioOutput) }
            if overrides.videoOutput == true { result.insert(.videoOutput) }
            if overrides.videoOutput == false { result.remove(.videoOutput) }
            return result
        }
        set {
            if let newValue {
                self.modalityOverrides = ModalityOverrides(
                    textInput: newValue.contains(.textInput),
                    textOutput: newValue.contains(.textOutput),
                    vision: newValue.contains(.imageInput),
                    pdfInput: newValue.contains(.pdfInput),
                    audioInput: newValue.contains(.audioInput),
                    videoInput: newValue.contains(.videoInput),
                    imageOutput: newValue.contains(.imageOutput),
                    audioOutput: newValue.contains(.audioOutput),
                    videoOutput: newValue.contains(.videoOutput)
                )
            } else {
                self.modalityOverrides = nil
            }
        }
    }

    /// True when no customizations have been set by the user.
    public var isEmpty: Bool {
        displayName == nil
            && maxOutputTokens == nil
            && (modalityOverrides == nil || modalityOverrides!.isEmpty)
            && contextWindow == nil
            && supportsReasoning == nil
            && maxThinkingLevel == nil
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, maxOutputTokens, modalityOverrides, modalityOverride, contextWindow, supportsReasoning, maxThinkingLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        self.contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        self.supportsReasoning = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
        self.maxThinkingLevel = try container.decodeIfPresent(String.self, forKey: .maxThinkingLevel)

        if let newMod = try container.decodeIfPresent(ModalityOverrides.self, forKey: .modalityOverrides) {
            self.modalityOverrides = newMod.isEmpty ? nil : newMod
        } else if let legacyMod = try container.decodeIfPresent(ModelModality.self, forKey: .modalityOverride) {
            // Backward-compatible migration of legacy binary OptionSet into explicit per-field overrides
            self.modalityOverrides = ModalityOverrides(
                vision: legacyMod.contains(.imageInput),
                pdfInput: legacyMod.contains(.pdfInput),
                audioInput: legacyMod.contains(.audioInput),
                videoInput: legacyMod.contains(.videoInput),
                imageOutput: legacyMod.contains(.imageOutput),
                audioOutput: legacyMod.contains(.audioOutput),
                videoOutput: legacyMod.contains(.videoOutput)
            )
        } else {
            self.modalityOverrides = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(maxOutputTokens, forKey: .maxOutputTokens)
        if let mod = modalityOverrides, !mod.isEmpty {
            try container.encode(mod, forKey: .modalityOverrides)
        }
        try container.encodeIfPresent(contextWindow, forKey: .contextWindow)
        try container.encodeIfPresent(supportsReasoning, forKey: .supportsReasoning)
        try container.encodeIfPresent(maxThinkingLevel, forKey: .maxThinkingLevel)
    }
}

/// Parsed representation of a user input string for optional positive integer overrides.
public enum OptionalPositiveIntInput: Equatable, Sendable {
    case clear
    case value(Int)
    case invalid
}

public enum NumericOverrideParser {
    public static func parse(_ text: String) -> OptionalPositiveIntInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .clear
        }
        guard let parsed = Int(trimmed), parsed > 0 else {
            return .invalid
        }
        return .value(parsed)
    }
}
