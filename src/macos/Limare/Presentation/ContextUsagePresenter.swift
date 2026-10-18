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
            detail = "≈ \(estimate) / \(grouped(budget)) tokens"
            if snapshot.estimatedInputTokens > budget {
                notice = "超出可用预算：下一次请求会先压缩上下文"
            }
        } else {
            percent = nil
            headline = "窗口未知"
            detail = "≈ \(estimate) tokens"
        }
        let provenance: String
        switch snapshot.provenance {
        case .heuristic:
            provenance = "估算"
        case .calibrated(let factor):
            provenance = "校准 ×" + factor.formatted(.number.precision(.fractionLength(2)))
        }
        let source: String
        switch snapshot.origin {
        case .request:
            source = "来自最近一次请求 · 模型 \(snapshot.modelID)"
        case .preview:
            source = "下一次请求的预估（尚未发送）· 模型 \(snapshot.modelID)"
        }
        let footnote = snapshot.lastActualInputTokens.map { "上次请求实测 \(grouped($0)) tokens" }
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
