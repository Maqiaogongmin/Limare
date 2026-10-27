import Foundation

/// Display strings for a context usage snapshot. The ratio is the calibrated estimate of the
/// request over its effective input budget, the same terms `ContextBudget.needsCompaction`
/// uses; the provider's reported input of an earlier request is shown as reference only.
enum ContextUsagePresenter {
    struct Presentation: Equatable {
        /// nil when the model declares no context window.
        let percent: Int?
        let headline: String
        let detail: String
        let provenance: String
        let source: String
        let footnote: String?
        /// Set when even the reduced request is over the budget: sending compacts first.
        let notice: String?
    }

    static func presentation(for snapshot: ContextUsageSnapshot?) -> Presentation? {
        guard let snapshot else { return nil }
        let estimate = grouped(snapshot.estimatedInputTokens)
        let percent: Int?
        let headline: String
        let detail: String
        var notice: String?
        if let budget = snapshot.effectiveInputBudget, budget > 0 {
            let ratio = Double(snapshot.estimatedInputTokens) / Double(budget) * 100
            let value = min(100, max(0, Int(ratio.rounded())))
            percent = value
            headline = "\(value)%"
            detail = String(localized: "≈ \(estimate) / \(grouped(budget)) tokens")
            if snapshot.estimatedInputTokens > budget {
                notice = String(localized: "Over the available budget: the next request compacts the context first")
            }
        } else {
            percent = nil
            headline = String(localized: "Window unknown")
            detail = String(localized: "≈ \(estimate) tokens")
        }
        let provenance: String
        switch snapshot.provenance {
        case .heuristic:
            provenance = String(localized: "Estimated")
        case .calibrated(let factor):
            provenance = String(localized: "Calibrated ×\(factor.formatted(.number.precision(.fractionLength(2))))")
        }
        let source: String
        switch snapshot.origin {
        case .request:
            source = String(localized: "From the latest request · model \(snapshot.modelID)")
        case .preview:
            source = String(localized: "Estimate for the next request (not sent yet) · model \(snapshot.modelID)")
        }
        let footnote = snapshot.lastActualInputTokens.map { String(localized: "Last request measured \(grouped($0)) tokens") }
        return Presentation(
            percent: percent,
            headline: headline,
            detail: detail,
            provenance: provenance,
            source: source,
            footnote: footnote,
            notice: notice
        )
    }

    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}
