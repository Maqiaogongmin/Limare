import Foundation

public enum ExecutableVisualRoute: String, Sendable, Equatable {
    case nativeImageInput
    case specialistVisionGroup
    case none
}

public enum AdapterCompatibilityResolver {
    /// Pure function determining whether the selected provider and adapter protocol supports native image projection.
    public static func supportsImageProjection(
        provider: ProviderConfiguration?,
        apiFormat: ProviderAPIFormat
    ) -> Bool {
        guard let provider else { return true }
        if provider.disabledNativeVision {
            return false
        }
        return true
    }
}

public struct ExecutableModalityContext: Sendable, Equatable {
    public let declaredImageInput: Bool
    public let adapterSupportsImageProjection: Bool
    public let artifactMaterializationAvailable: Bool
    public let specialistVisionExecutable: Bool

    public init(
        declaredImageInput: Bool,
        adapterSupportsImageProjection: Bool = true,
        artifactMaterializationAvailable: Bool = true,
        specialistVisionExecutable: Bool = false
    ) {
        self.declaredImageInput = declaredImageInput
        self.adapterSupportsImageProjection = adapterSupportsImageProjection
        self.artifactMaterializationAvailable = artifactMaterializationAvailable
        self.specialistVisionExecutable = specialistVisionExecutable
    }
}

public struct ExecutableModalityProjection: Sendable, Equatable {
    public let effectiveNativeVision: Bool
    public let effectiveSpecialistVision: Bool
    public let exposesReadImage: Bool
    public let effectiveVisualRoute: ExecutableVisualRoute

    public init(
        effectiveNativeVision: Bool,
        effectiveSpecialistVision: Bool,
        exposesReadImage: Bool,
        effectiveVisualRoute: ExecutableVisualRoute
    ) {
        self.effectiveNativeVision = effectiveNativeVision
        self.effectiveSpecialistVision = effectiveSpecialistVision
        self.exposesReadImage = exposesReadImage
        self.effectiveVisualRoute = effectiveVisualRoute
    }
}

enum ExecutableModalityResolver {
    /// Pure projection resolver computing effective modality executability from runtime facts (ID-I06).
    static func resolve(context: ExecutableModalityContext) -> ExecutableModalityProjection {
        let nativeVisionExecutable = context.declaredImageInput
            && context.adapterSupportsImageProjection
            && context.artifactMaterializationAvailable

        if nativeVisionExecutable {
            return ExecutableModalityProjection(
                effectiveNativeVision: true,
                effectiveSpecialistVision: false,
                exposesReadImage: false,
                effectiveVisualRoute: .nativeImageInput
            )
        } else if context.specialistVisionExecutable {
            return ExecutableModalityProjection(
                effectiveNativeVision: false,
                effectiveSpecialistVision: true,
                exposesReadImage: true,
                effectiveVisualRoute: .specialistVisionGroup
            )
        } else {
            return ExecutableModalityProjection(
                effectiveNativeVision: false,
                effectiveSpecialistVision: false,
                exposesReadImage: false,
                effectiveVisualRoute: .none
            )
        }
    }

    /// Convenience resolver mapping model and runtime capability facts into ExecutableModalityContext.
    static func resolve(
        mainModel: ProviderModel?,
        provider: ProviderConfiguration? = nil,
        apiFormat: ProviderAPIFormat = .chatCompletions,
        adapterDisabledNativeVision: Bool = false,
        artifactStoreAvailable: Bool = true,
        hasSpecialistVision: Bool = false
    ) -> ExecutableModalityProjection {
        let declaredImage = mainModel?.modality?.contains(.imageInput) == true
        let adapterSupported = !adapterDisabledNativeVision && AdapterCompatibilityResolver.supportsImageProjection(provider: provider, apiFormat: apiFormat)
        let context = ExecutableModalityContext(
            declaredImageInput: declaredImage,
            adapterSupportsImageProjection: adapterSupported,
            artifactMaterializationAvailable: artifactStoreAvailable,
            specialistVisionExecutable: hasSpecialistVision
        )
        return resolve(context: context)
    }
}
