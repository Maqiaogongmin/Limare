import Foundation

public enum CapabilityTruth: String, Sendable, Codable, CaseIterable, Equatable {
    case supported
    case unsupported
    case unknown
}

public typealias ModalityTruth = CapabilityTruth

public struct ModelModalitiesTruth: Sendable, Equatable {
    public var textInput: CapabilityTruth
    public var imageInput: CapabilityTruth
    public var pdfInput: CapabilityTruth
    public var audioInput: CapabilityTruth
    public var videoInput: CapabilityTruth
    public var textOutput: CapabilityTruth
    public var imageOutput: CapabilityTruth
    public var audioOutput: CapabilityTruth
    public var videoOutput: CapabilityTruth

    public var textInputProvenance: ModelMetadataSource
    public var imageInputProvenance: ModelMetadataSource
    public var pdfInputProvenance: ModelMetadataSource
    public var audioInputProvenance: ModelMetadataSource
    public var videoInputProvenance: ModelMetadataSource
    public var textOutputProvenance: ModelMetadataSource
    public var imageOutputProvenance: ModelMetadataSource
    public var audioOutputProvenance: ModelMetadataSource
    public var videoOutputProvenance: ModelMetadataSource

    public var provenance: ModelMetadataSource

    public init(
        textInput: CapabilityTruth = .unknown,
        imageInput: CapabilityTruth = .unknown,
        pdfInput: CapabilityTruth = .unknown,
        audioInput: CapabilityTruth = .unknown,
        videoInput: CapabilityTruth = .unknown,
        textOutput: CapabilityTruth = .unknown,
        imageOutput: CapabilityTruth = .unknown,
        audioOutput: CapabilityTruth = .unknown,
        videoOutput: CapabilityTruth = .unknown,
        textInputProvenance: ModelMetadataSource = .unknown,
        imageInputProvenance: ModelMetadataSource = .unknown,
        pdfInputProvenance: ModelMetadataSource = .unknown,
        audioInputProvenance: ModelMetadataSource = .unknown,
        videoInputProvenance: ModelMetadataSource = .unknown,
        textOutputProvenance: ModelMetadataSource = .unknown,
        imageOutputProvenance: ModelMetadataSource = .unknown,
        audioOutputProvenance: ModelMetadataSource = .unknown,
        videoOutputProvenance: ModelMetadataSource = .unknown,
        provenance: ModelMetadataSource = .unknown
    ) {
        self.textInput = textInput
        self.imageInput = imageInput
        self.pdfInput = pdfInput
        self.audioInput = audioInput
        self.videoInput = videoInput
        self.textOutput = textOutput
        self.imageOutput = imageOutput
        self.audioOutput = audioOutput
        self.videoOutput = videoOutput
        self.textInputProvenance = textInputProvenance
        self.imageInputProvenance = imageInputProvenance
        self.pdfInputProvenance = pdfInputProvenance
        self.audioInputProvenance = audioInputProvenance
        self.videoInputProvenance = videoInputProvenance
        self.textOutputProvenance = textOutputProvenance
        self.imageOutputProvenance = imageOutputProvenance
        self.audioOutputProvenance = audioOutputProvenance
        self.videoOutputProvenance = videoOutputProvenance
        self.provenance = provenance
    }
}

public enum ModalityOverrideChoice: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "auto"
    case supported = "supported"
    case unsupported = "unsupported"

    public var id: String { rawValue }
}

public enum ModelCapabilityTruthResolver {

    /// Calculates effective runtime ModelModality by applying per-field overrides over baseModality.
    public static func effectiveModality(
        baseModality: ModelModality?,
        overrides: ModalityOverrides?
    ) -> ModelModality? {
        guard let overrides = overrides, !overrides.isEmpty else {
            return baseModality
        }

        var result: ModelModality = baseModality ?? []

        if let textIn = overrides.textInput {
            if textIn { result.insert(.textInput) } else { result.remove(.textInput) }
        }
        if let textOut = overrides.textOutput {
            if textOut { result.insert(.textOutput) } else { result.remove(.textOutput) }
        }
        if let vision = overrides.vision {
            if vision { result.insert(.imageInput) } else { result.remove(.imageInput) }
        }
        if let pdf = overrides.pdfInput {
            if pdf { result.insert(.pdfInput) } else { result.remove(.pdfInput) }
        }
        if let audioIn = overrides.audioInput {
            if audioIn { result.insert(.audioInput) } else { result.remove(.audioInput) }
        }
        if let videoIn = overrides.videoInput {
            if videoIn { result.insert(.videoInput) } else { result.remove(.videoInput) }
        }
        if let imgOut = overrides.imageOutput {
            if imgOut { result.insert(.imageOutput) } else { result.remove(.imageOutput) }
        }
        if let audioOut = overrides.audioOutput {
            if audioOut { result.insert(.audioOutput) } else { result.remove(.audioOutput) }
        }
        if let videoOut = overrides.videoOutput {
            if videoOut { result.insert(.videoOutput) } else { result.remove(.videoOutput) }
        }

        return result
    }

    /// Resolves the 3-state modality truth and per-field capability provenance for a model.
    public static func resolveModalities(
        for model: ProviderModel
    ) -> ModelModalitiesTruth {
        let baseProv = model.baseCapabilityProvenance?.modality ?? model.baseMetadataSource ?? (model.isCustom ? .custom : .unknown)
        let baseMod = model.baseModality
        let overrides = model.overrides.modalityOverrides

        func resolveField(
            modality: ModelModality,
            overrideVal: Bool?
        ) -> (truth: CapabilityTruth, prov: ModelMetadataSource) {
            if let overrideVal = overrideVal {
                return (overrideVal ? .supported : .unsupported, .userOverride)
            }

            // Auto: resolve from base
            guard let baseMod = baseMod else {
                return (.unknown, baseProv)
            }

            switch baseProv {
            case .modelsDevAuthoritative, .builtIn, .providerDeclaration:
                return (baseMod.contains(modality) ? .supported : .unsupported, baseProv)
            case .inferred, .modelsDevFallback, .custom, .userOverride, .unknown:
                return (baseMod.contains(modality) ? .supported : .unknown, baseProv)
            }
        }

        let textIn = resolveField(modality: .textInput, overrideVal: overrides?.textInput)
        let textOut = resolveField(modality: .textOutput, overrideVal: overrides?.textOutput)

        let visionField = resolveField(modality: .imageInput, overrideVal: overrides?.vision)
        let pdfField = resolveField(modality: .pdfInput, overrideVal: overrides?.pdfInput)
        let audioInField = resolveField(modality: .audioInput, overrideVal: overrides?.audioInput)
        let videoInField = resolveField(modality: .videoInput, overrideVal: overrides?.videoInput)

        let imgOutField = resolveField(modality: .imageOutput, overrideVal: overrides?.imageOutput)
        let audioOutField = resolveField(modality: .audioOutput, overrideVal: overrides?.audioOutput)
        let videoOutField = resolveField(modality: .videoOutput, overrideVal: overrides?.videoOutput)

        let overallProv: ModelMetadataSource
        if let overrides = overrides, !overrides.isEmpty {
            overallProv = .userOverride
        } else {
            overallProv = baseProv
        }

        return ModelModalitiesTruth(
            textInput: textIn.truth,
            imageInput: visionField.truth,
            pdfInput: pdfField.truth,
            audioInput: audioInField.truth,
            videoInput: videoInField.truth,
            textOutput: textOut.truth,
            imageOutput: imgOutField.truth,
            audioOutput: audioOutField.truth,
            videoOutput: videoOutField.truth,
            textInputProvenance: textIn.prov,
            imageInputProvenance: visionField.prov,
            pdfInputProvenance: pdfField.prov,
            audioInputProvenance: audioInField.prov,
            videoInputProvenance: videoInField.prov,
            textOutputProvenance: textOut.prov,
            imageOutputProvenance: imgOutField.prov,
            audioOutputProvenance: audioOutField.prov,
            videoOutputProvenance: videoOutField.prov,
            provenance: overallProv
        )
    }

    /// Builds a sanitized ModalityOverrides struct from 3-state UI choices, returning `nil` when all choices are `.auto`.
    public static func buildModalityOverrides(
        textInput: ModalityOverrideChoice = .auto,
        textOutput: ModalityOverrideChoice = .auto,
        vision: ModalityOverrideChoice = .auto,
        pdf: ModalityOverrideChoice = .auto,
        audioInput: ModalityOverrideChoice = .auto,
        videoInput: ModalityOverrideChoice = .auto,
        imageOutput: ModalityOverrideChoice = .auto,
        audioOutput: ModalityOverrideChoice = .auto,
        videoOutput: ModalityOverrideChoice = .auto
    ) -> ModalityOverrides? {
        func toBool(_ choice: ModalityOverrideChoice) -> Bool? {
            switch choice {
            case .supported: return true
            case .unsupported: return false
            case .auto: return nil
            }
        }

        let overrides = ModalityOverrides(
            textInput: toBool(textInput),
            textOutput: toBool(textOutput),
            vision: toBool(vision),
            pdfInput: toBool(pdf),
            audioInput: toBool(audioInput),
            videoInput: toBool(videoInput),
            imageOutput: toBool(imageOutput),
            audioOutput: toBool(audioOutput),
            videoOutput: toBool(videoOutput)
        )

        return overrides.isEmpty ? nil : overrides
    }

    /// Legacy helper for building ModelModality OptionSet.
    public static func buildSanitizedModalityOverride(
        baseModel: ProviderModel? = nil,
        baseModality: ModelModality? = nil,
        textInput: ModalityOverrideChoice = .auto,
        textOutput: ModalityOverrideChoice = .auto,
        vision: ModalityOverrideChoice = .auto,
        pdf: ModalityOverrideChoice = .auto,
        audioInput: ModalityOverrideChoice = .auto,
        videoInput: ModalityOverrideChoice = .auto,
        imageOutput: ModalityOverrideChoice = .auto,
        audioOutput: ModalityOverrideChoice = .auto,
        videoOutput: ModalityOverrideChoice = .auto
    ) -> ModelModality? {
        guard let overrides = buildModalityOverrides(
            textInput: textInput,
            textOutput: textOutput,
            vision: vision,
            pdf: pdf,
            audioInput: audioInput,
            videoInput: videoInput,
            imageOutput: imageOutput,
            audioOutput: audioOutput,
            videoOutput: videoOutput
        ) else {
            return nil
        }
        return effectiveModality(
            baseModality: baseModality ?? baseModel?.baseModality,
            overrides: overrides
        )
    }
}
