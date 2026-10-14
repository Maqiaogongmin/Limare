import Foundation

/// Identity key for isolated in-memory calibration tracking.
public struct ContextCalibrationKey: Hashable, Sendable, CustomStringConvertible {
    public let conversationID: UUID
    public let providerID: UUID
    public let modelID: String

    public init(conversationID: UUID, providerID: UUID, modelID: String) {
        self.conversationID = conversationID
        self.providerID = providerID
        self.modelID = modelID
    }

    public var description: String {
        "conv=\(conversationID.uuidString.prefix(8))|prov=\(providerID.uuidString.prefix(8))|model=\(modelID)"
    }
}

/// In-memory ephemeral calibration record for empirical token estimation feedback.
@MainActor
public final class ContextCalibrationStore {
    public struct CalibrationEntry: Sendable, Equatable {
        public let key: ContextCalibrationKey
        public let lastEstimatedInputTokens: Int
        public let lastActualInputTokens: Int
        public let observedRatio: Double
        public let underestimateFactor: Double
        public let updatedAt: Date

        public init(
            key: ContextCalibrationKey,
            lastEstimatedInputTokens: Int,
            lastActualInputTokens: Int,
            observedRatio: Double,
            underestimateFactor: Double,
            updatedAt: Date = Date()
        ) {
            self.key = key
            self.lastEstimatedInputTokens = lastEstimatedInputTokens
            self.lastActualInputTokens = lastActualInputTokens
            self.observedRatio = observedRatio
            self.underestimateFactor = underestimateFactor
            self.updatedAt = updatedAt
        }
    }

    private var entries: [ContextCalibrationKey: CalibrationEntry] = [:]

    public init() {}

    /// Retrieves the current bounded calibration factor for a given conversation + provider + model key.
    public func factor(for key: ContextCalibrationKey) -> Double {
        entries[key]?.underestimateFactor ?? 1.0
    }

    public func factor(conversationID: UUID, providerID: UUID, modelID: String) -> Double {
        factor(for: ContextCalibrationKey(conversationID: conversationID, providerID: providerID, modelID: modelID))
    }

    /// Retrieves the full calibration entry if present.
    public func entry(for key: ContextCalibrationKey) -> CalibrationEntry? {
        entries[key]
    }

    /// Records authoritative provider usage feedback and calibrates the underestimateFactor.
    ///
    /// Formula:
    /// - observedRatio = actualInputTokens / rawTotalInputTokens
    /// - underestimateFactor = min(4.0, max(1.0, observedRatio))
    @discardableResult
    public func recordUsage(
        key: ContextCalibrationKey,
        rawTotalInputTokens: Int,
        actualInputTokens: Int
    ) -> Double {
        guard rawTotalInputTokens > 0, actualInputTokens > 0 else {
            return factor(for: key)
        }
        let observedRatio = Double(actualInputTokens) / Double(rawTotalInputTokens)
        let factor = min(4.0, max(1.0, observedRatio))
        let entry = CalibrationEntry(
            key: key,
            lastEstimatedInputTokens: rawTotalInputTokens,
            lastActualInputTokens: actualInputTokens,
            observedRatio: observedRatio,
            underestimateFactor: factor,
            updatedAt: Date()
        )
        entries[key] = entry
        return factor
    }

    @discardableResult
    public func recordUsage(
        conversationID: UUID,
        providerID: UUID,
        modelID: String,
        rawTotalInputTokens: Int,
        actualInputTokens: Int
    ) -> Double {
        recordUsage(
            key: ContextCalibrationKey(conversationID: conversationID, providerID: providerID, modelID: modelID),
            rawTotalInputTokens: rawTotalInputTokens,
            actualInputTokens: actualInputTokens
        )
    }

    @discardableResult
    public func recordUsage(
        key: ContextCalibrationKey,
        estimatedPreviousInputTokens: Int,
        actualInputTokens: Int
    ) -> Double {
        recordUsage(key: key, rawTotalInputTokens: estimatedPreviousInputTokens, actualInputTokens: actualInputTokens)
    }

    @discardableResult
    public func recordUsage(
        conversationID: UUID,
        providerID: UUID,
        modelID: String,
        estimatedPreviousInputTokens: Int,
        actualInputTokens: Int
    ) -> Double {
        recordUsage(
            conversationID: conversationID,
            providerID: providerID,
            modelID: modelID,
            rawTotalInputTokens: estimatedPreviousInputTokens,
            actualInputTokens: actualInputTokens
        )
    }

    /// Resets calibration state (optionally scoped to a specific conversation).
    public func reset(conversationID: UUID? = nil) {
        if let conversationID {
            entries = entries.filter { $0.key.conversationID != conversationID }
        } else {
            entries.removeAll()
        }
    }
}
