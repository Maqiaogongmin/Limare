import SwiftUI
import AppKit

/// Context usage of the conversation's next or latest request, beside the model selector: a
/// ring that fills and turns from green to yellow as the request nears its budget. Hovering
/// it shows the figures.
struct ContextUsageIndicator: View {
    @Environment(AppState.self) private var appState
    let conversationID: UUID?
    @State private var isHovering = false

    private var presentation: ContextUsagePresenter.Presentation? {
        guard let conversationID else { return nil }
        return ContextUsagePresenter.presentation(for: appState.conversationRuns.contextUsage[conversationID])
    }

    var body: some View {
        if let presentation {
            // Narrower than a button: the ring is small, and the composer row is short of room.
            ContextUsageRing(fraction: presentation.percent.map { Double($0) / 100 })
                .frame(width: AppControlHeight.composerButton - 8, height: AppControlHeight.composerButton)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .popover(isPresented: $isHovering, arrowEdge: .top) {
                    ContextUsageDetail(presentation: presentation)
                }
                .accessibilityElement()
                .accessibilityLabel("上下文用量 \(presentation.headline)")
                .accessibilityValue(presentation.detail)
                .accessibilityIdentifier("composer.contextUsage")
        }
    }
}

/// A progress ring; an unknown fraction (no context window) shows the track alone.
struct ContextUsageRing: View {
    let fraction: Double?

    static let diameter: CGFloat = 14
    static let lineWidth: CGFloat = 2.5

    /// Green when empty, yellow when full, blended between.
    static func nsColor(for fraction: Double) -> NSColor {
        NSColor.systemGreen.blended(withFraction: min(1, max(0, fraction)), of: .systemYellow) ?? .systemGreen
    }

    // Flat ends: a small share reads as a short filled arc on the full track, not as the
    // rounded tail of a spinner.
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.22), lineWidth: Self.lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(Color(nsColor: Self.nsColor(for: fraction)), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }
}

private struct ContextUsageDetail: View {
    let presentation: ContextUsagePresenter.Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(presentation.headline)
                .font(.headline.monospacedDigit())
            Text(presentation.detail)
                .font(.callout.monospacedDigit())
            if let notice = presentation.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(AppColors.statusWarning)
            }
            Text(presentation.provenance)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(presentation.source)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let footnote = presentation.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("按校准估算；实测值仅供参考")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(AppSpacing.medium)
        .frame(minWidth: 240, alignment: .leading)
    }
}
