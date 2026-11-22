import SwiftUI
import AppKit

/// Canonical token composition series displayed across Overview and Daily Trend.
enum UsageTokenSeries: String, CaseIterable, Identifiable, Sendable {
    case freshInput
    case cacheHit
    case output
    case reasoning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freshInput: String(localized: "Fresh input")
        case .cacheHit: String(localized: "Cache hit")
        case .output: String(localized: "Output")
        case .reasoning: String(localized: "Reasoning")
        }
    }

    // Appearance-adaptive colours created once so SwiftUI identity comparisons remain stable.
    private static let freshInputColor = Color(nsColor: AppColors.dynamicNSColor(light: 0x3878F0, dark: 0x60A5FA))
    private static let cacheHitColor = Color(nsColor: AppColors.dynamicNSColor(light: 0x0EA5A4, dark: 0x2DD4BF))
    private static let outputColor = Color(nsColor: AppColors.dynamicNSColor(light: 0x29B380, dark: 0x34D399))
    private static let reasoningColor = Color(nsColor: AppColors.dynamicNSColor(light: 0x8B5CF6, dark: 0xA78BFA))

    static let rowBarTint = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 96.0 / 255.0, green: 165.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.15)
            : NSColor(srgbRed: 56.0 / 255.0, green: 120.0 / 255.0, blue: 240.0 / 255.0, alpha: 0.11)
    })

    var color: Color {
        switch self {
        case .freshInput: Self.freshInputColor
        case .cacheHit: Self.cacheHitColor
        case .output: Self.outputColor
        case .reasoning: Self.reasoningColor
        }
    }
}

/// Truthful decomposition of normalized totals into non-overlapping composition segments.
struct UsageTokenComposition: Equatable, Sendable {
    let freshInput: Int
    let cacheHit: Int
    let output: Int
    let reasoning: Int
    let totalInput: Int
    let totalOutput: Int
    let cacheHitRate: Double?

    init(totals: UsageTotals) {
        let totalIn = max(0, totals.input ?? 0)
        let cached = min(totalIn, max(0, totals.cacheRead ?? 0))
        let fresh = max(0, totalIn - cached)

        let totalOut = max(0, totals.output ?? 0)
        let reason = min(totalOut, max(0, totals.reasoning ?? 0))
        let regularOut = max(0, totalOut - reason)

        self.freshInput = fresh
        self.cacheHit = cached
        self.output = regularOut
        self.reasoning = reason
        self.totalInput = totalIn
        self.totalOutput = totalOut
        if totals.cacheMeasuredInput > 0 {
            self.cacheHitRate = Double(totals.cacheMeasuredRead) / Double(totals.cacheMeasuredInput)
        } else {
            self.cacheHitRate = nil
        }
    }

    var total: Int { freshInput + cacheHit + output + reasoning }

    func value(for series: UsageTokenSeries) -> Int {
        switch series {
        case .freshInput: freshInput
        case .cacheHit: cacheHit
        case .output: output
        case .reasoning: reasoning
        }
    }

    func share(for series: UsageTokenSeries) -> Double {
        guard total > 0 else { return 0 }
        return Double(value(for: series)) / Double(total)
    }

    var nonZeroSeries: [UsageTokenSeries] {
        UsageTokenSeries.allCases.filter { value(for: $0) > 0 }
    }
}

/// Single day or aggregated week column rendered in `UsageDailyTrendChart`.
struct UsageTrendBucket: Identifiable, Equatable, Sendable {
    let id: Date
    let startDate: Date
    let endDate: Date?
    let axisLabel: String
    let tooltipTitle: String
    let composition: UsageTokenComposition
    let requests: Int

    static func buckets(from days: [UsageDay], calendar: Calendar = .current) -> (buckets: [UsageTrendBucket], isWeekly: Bool) {
        if days.count <= 35 {
            let daily = days.map { day in
                UsageTrendBucket(
                    id: day.date,
                    startDate: day.date,
                    endDate: nil,
                    axisLabel: day.date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)),
                    tooltipTitle: day.date.formatted(.dateTime.month().day()),
                    composition: UsageTokenComposition(totals: day.totals),
                    requests: day.totals.requests
                )
            }
            return (daily, false)
        }

        // Group chronologically by local calendar week when history spans more than 35 days.
        var grouped: [(key: DateComponents, days: [UsageDay])] = []
        var indexByKey: [DateComponents: Int] = [:]

        for day in days {
            let key = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day.date)
            if let existingIndex = indexByKey[key] {
                grouped[existingIndex].days.append(day)
            } else {
                indexByKey[key] = grouped.count
                grouped.append((key: key, days: [day]))
            }
        }

        let weekly = grouped.compactMap { entry -> UsageTrendBucket? in
            guard let firstDay = entry.days.first?.date, let lastDay = entry.days.last?.date else {
                return nil
            }
            let summed = mergeTotals(entry.days.map(\.totals))
            let title: String
            if calendar.isDate(firstDay, inSameDayAs: lastDay) {
                title = firstDay.formatted(.dateTime.month().day())
            } else {
                title = "\(firstDay.formatted(.dateTime.month().day())) – \(lastDay.formatted(.dateTime.month().day()))"
            }
            return UsageTrendBucket(
                id: firstDay,
                startDate: firstDay,
                endDate: lastDay,
                axisLabel: firstDay.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)),
                tooltipTitle: title,
                composition: UsageTokenComposition(totals: summed),
                requests: summed.requests
            )
        }
        return (weekly, true)
    }

    private static func mergeTotals(_ items: [UsageTotals]) -> UsageTotals {
        func addOpt(_ a: Int?, _ b: Int?) -> Int? {
            guard let b else { return a }
            return (a ?? 0) + b
        }

        var result = UsageTotals()
        for item in items {
            result.requests += item.requests
            result.input = addOpt(result.input, item.input)
            result.output = addOpt(result.output, item.output)
            result.cacheRead = addOpt(result.cacheRead, item.cacheRead)
            result.cacheMeasuredInput += item.cacheMeasuredInput
            result.cacheMeasuredRead += item.cacheMeasuredRead
            result.cacheWrite = addOpt(result.cacheWrite, item.cacheWrite)
            result.reasoning = addOpt(result.reasoning, item.reasoning)
            result.toolUsePrompt = addOpt(result.toolUsePrompt, item.toolUsePrompt)
            result.incomplete = result.incomplete || item.incomplete
        }
        return result
    }
}

/// Overview 10pt segmented composition bar paired with interactive breakdown pills.
struct UsageCompositionBar: View {
    let composition: UsageTokenComposition
    let totals: UsageTotals
    @Binding var activeSeries: UsageTokenSeries?

    private let barHeight: CGFloat = 10
    private let segmentGap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Text("Token breakdown")
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)

                Spacer(minLength: AppSpacing.small)

                readoutView
                    .font(AppTypography.interfaceCaption)
                    .monospacedDigit()
            }

            if composition.total > 0 {
                let nonZero = composition.nonZeroSeries
                GeometryReader { geo in
                    let widths = segmentWidths(for: nonZero, totalWidth: geo.size.width)
                    HStack(spacing: segmentGap) {
                        ForEach(Array(nonZero.enumerated()), id: \.element.id) { idx, series in
                            let isActive = activeSeries == nil || activeSeries == series
                            Capsule(style: .continuous)
                                .fill(series.color)
                                .frame(width: widths[idx], height: barHeight)
                                .opacity(isActive ? 1 : 0.22)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    withAnimation(AppMotion.resolved(AppMotion.quick)) {
                                        if hovering {
                                            activeSeries = series
                                        } else if activeSeries == series {
                                            activeSeries = nil
                                        }
                                    }
                                }
                                .accessibilityElement()
                                .accessibilityLabel(series.title)
                                .accessibilityValue(
                                    "\(composition.value(for: series).formatted()) (\(composition.share(for: series).formatted(.percent.precision(.fractionLength(1)))))"
                                )
                        }
                    }
                    .animation(AppMotion.resolved(AppMotion.layout), value: composition)
                }
                .frame(height: barHeight)

                UsageWrappingFlow(spacing: AppSpacing.xSmall) {
                    ForEach(nonZero) { series in
                        legendPill(for: series)
                    }
                }
            } else {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: barHeight)
            }
        }
    }

    @ViewBuilder
    private var readoutView: some View {
        if let series = activeSeries, composition.value(for: series) > 0 {
            let value = composition.value(for: series).formatted()
            let share = composition.share(for: series).formatted(.percent.precision(.fractionLength(1)))
            Text("\(series.title): \(value) (\(share))")
                .foregroundStyle(AppColors.textPrimary)
        } else {
            Text("Total: \(composition.total.formatted())")
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func legendPill(for series: UsageTokenSeries) -> some View {
        let value = composition.value(for: series)
        let share = composition.share(for: series)
        let isFocused = activeSeries == series
        let isDimmed = activeSeries != nil && !isFocused

        return Button {
            withAnimation(AppMotion.resolved(AppMotion.quick)) {
                activeSeries = (activeSeries == series) ? nil : series
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(series.color)
                    .frame(width: 7, height: 7)
                Text(series.title)
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textPrimary)
                Text(value, format: .number.notation(.compactName))
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)
                    .monospacedDigit()
                Text(share, format: .percent.precision(.fractionLength(1)))
                    .font(AppTypography.interfaceCaption2)
                    .foregroundStyle(AppColors.textMuted)
                    .monospacedDigit()
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.xxSmall)
            .background(
                Capsule(style: .continuous)
                    .fill(isFocused ? Color.primary.opacity(0.085) : Color.primary.opacity(0.045))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isFocused ? AppColors.hairline : .clear, lineWidth: 1)
            )
            .scaleEffect(isFocused ? 0.98 : 1.0)
            .opacity(isDimmed ? 0.38 : 1.0)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AppMotion.resolved(AppMotion.quick)) {
                if hovering {
                    activeSeries = series
                } else if activeSeries == series {
                    activeSeries = nil
                }
            }
        }
    }

    private func segmentWidths(for series: [UsageTokenSeries], totalWidth: CGFloat) -> [CGFloat] {
        guard !series.isEmpty else { return [] }
        let usable = max(0, totalWidth - CGFloat(series.count - 1) * segmentGap)
        guard usable > 0 else { return Array(repeating: 0, count: series.count) }
        if series.count == 1 { return [usable] }

        let total = max(1, composition.total)
        let minWidth = min(4, usable / CGFloat(series.count))
        var widths = series.map { usable * CGFloat(composition.value(for: $0)) / CGFloat(total) }

        var lockedIndices = Set<Int>()
        var lockedTotal: CGFloat = 0
        for (idx, w) in widths.enumerated() where w < minWidth {
            lockedIndices.insert(idx)
            widths[idx] = minWidth
            lockedTotal += minWidth
        }

        if !lockedIndices.isEmpty && lockedIndices.count < series.count {
            let remaining = max(0, usable - lockedTotal)
            let unlockedSum = widths.enumerated()
                .filter { !lockedIndices.contains($0.offset) }
                .reduce(CGFloat(0)) { $0 + $1.element }
            if unlockedSum > 0 {
                for idx in widths.indices where !lockedIndices.contains(idx) {
                    widths[idx] = (widths[idx] / unlockedSum) * remaining
                }
            }
        }
        return widths
    }
}

/// Interactive trailing legend for the Daily Trend section header.
struct UsageSeriesLegend: View {
    let series: [UsageTokenSeries]
    @Binding var activeSeries: UsageTokenSeries?

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            ForEach(series) { item in
                let isFocused = activeSeries == item
                let isDimmed = activeSeries != nil && !isFocused
                Button {
                    withAnimation(AppMotion.resolved(AppMotion.quick)) {
                        activeSeries = (activeSeries == item) ? nil : item
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.title)
                            .font(AppTypography.interfaceCaption)
                            .foregroundStyle(isFocused ? AppColors.textPrimary : AppColors.textSecondary)
                    }
                    .padding(.horizontal, AppSpacing.small)
                    .padding(.vertical, AppSpacing.xxxSmall + 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isFocused ? Color.primary.opacity(0.085) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(isFocused ? AppColors.hairline : .clear, lineWidth: 1)
                    )
                    .scaleEffect(isFocused ? 0.98 : 1.0)
                    .opacity(isDimmed ? 0.38 : 1.0)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(AppMotion.resolved(AppMotion.quick)) {
                        if hovering {
                            activeSeries = item
                        } else if activeSeries == item {
                            activeSeries = nil
                        }
                    }
                }
            }
        }
    }
}

/// Native SwiftUI stacked bar chart with 2pt segment gaps and bidirectional hover:
/// continuous column scrubbing + floating tooltip, and cross-day series highlighting.
struct UsageDailyTrendChart: View {
    let buckets: [UsageTrendBucket]
    @Binding var highlightedSeries: UsageTokenSeries?

    @State private var hoveredIndex: Int?
    @State private var hoveredSegment: UsageTokenSeries?

    private let plotHeight: CGFloat = 176
    private let yAxisWidth: CGFloat = 42
    private let segmentGap: CGFloat = 2
    private let tooltipWidth: CGFloat = 204

    private var columnSpacing: CGFloat {
        buckets.count > 20 ? 2 : (buckets.count > 10 ? 4 : 8)
    }

    private var maxBarWidth: CGFloat {
        buckets.count > 20 ? 16 : (buckets.count > 10 ? 22 : 30)
    }

    var body: some View {
        let maxTotal = buckets.map(\.composition.total).max() ?? 0
        let ceiling = Self.niceCeiling(for: maxTotal)

        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack(alignment: .bottom, spacing: AppSpacing.small) {
                GeometryReader { geo in
                    let plotWidth = geo.size.width

                    ZStack(alignment: .topLeading) {
                        gridLines(width: plotWidth)

                        columnsRow(ceiling: ceiling)

                        if let idx = hoveredIndex, buckets.indices.contains(idx) {
                            tooltipOverlay(for: buckets[idx], index: idx, plotWidth: plotWidth)
                        }
                    }
                    .frame(width: plotWidth, height: plotHeight)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard !buckets.isEmpty, plotWidth > 0 else { return }
                            let idx = max(0, min(buckets.count - 1, Int((point.x / plotWidth) * CGFloat(buckets.count))))
                            let seg = hitTestSegment(atY: point.y, bucket: buckets[idx], ceiling: ceiling)
                            if hoveredIndex != idx || hoveredSegment != seg {
                                hoveredIndex = idx
                                hoveredSegment = seg
                            }
                        case .ended:
                            if hoveredIndex != nil || hoveredSegment != nil {
                                hoveredIndex = nil
                                hoveredSegment = nil
                            }
                        }
                    }
                }
                .frame(height: plotHeight)

                yAxisLabels(ceiling: ceiling)
                    .frame(width: yAxisWidth, height: plotHeight)
            }

            xAxisLabels
                .padding(.trailing, yAxisWidth + AppSpacing.small)
        }
    }

    private func gridLines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5, id: \.self) { step in
                let y = plotHeight * (1 - CGFloat(step) / 4.0)
                if step == 0 {
                    Rectangle()
                        .fill(AppColors.hairline)
                        .frame(width: width, height: 1)
                        .offset(y: plotHeight - 1)
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: width, y: 0))
                    }
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .frame(width: width, height: 1)
                    .offset(y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func yAxisLabels(ceiling: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach((0..<5).reversed(), id: \.self) { step in
                let value = (ceiling * step) / 4
                Text(value == 0 ? "0" : value.formatted(.number.notation(.compactName)))
                    .font(AppTypography.interfaceCaption2)
                    .foregroundStyle(AppColors.textMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                if step > 0 {
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func columnsRow(ceiling: Int) -> some View {
        HStack(alignment: .bottom, spacing: columnSpacing) {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                let segments = segmentHeights(for: bucket.composition, ceiling: ceiling)
                let isColHovered = hoveredIndex == idx
                let colOpacity: Double = {
                    guard highlightedSeries == nil, let hoveredIndex else { return 1 }
                    return hoveredIndex == idx ? 1 : 0.45
                }()

                ZStack(alignment: .bottom) {
                    if isColHovered && highlightedSeries == nil {
                        RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    VStack(spacing: segmentGap) {
                        ForEach(segments, id: \.series.id) { item in
                            let segOpacity: Double = {
                                if let highlightedSeries {
                                    return highlightedSeries == item.series ? 1 : 0.20
                                }
                                return 1
                            }()
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(item.series.color)
                                .frame(height: item.height)
                                .opacity(segOpacity)
                        }
                    }
                    .frame(maxWidth: maxBarWidth)
                    .opacity(colOpacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(height: plotHeight, alignment: .bottom)
        .animation(AppMotion.resolved(.easeOut(duration: 0.28)), value: buckets)
        .animation(AppMotion.resolved(AppMotion.quick), value: highlightedSeries)
        .animation(AppMotion.resolved(AppMotion.quick), value: hoveredIndex)
    }

    private var xAxisLabels: some View {
        let count = buckets.count
        let strideCount = max(1, count > 10 ? count / 6 : 1)

        return HStack(spacing: columnSpacing) {
            ForEach(Array(buckets.enumerated()), id: \.element.id) { idx, bucket in
                let showLabel = idx == 0
                    || idx == count - 1
                    || (idx % strideCount == 0 && (count - 1 - idx) >= max(1, strideCount / 2))
                let alignment: Alignment = idx == 0 ? .leading : (idx == count - 1 ? .trailing : .center)

                Group {
                    if showLabel {
                        Text(bucket.axisLabel)
                            .font(AppTypography.interfaceCaption2)
                            .foregroundStyle(AppColors.textMuted)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
    }

    private func tooltipOverlay(for bucket: UsageTrendBucket, index: Int, plotWidth: CGFloat) -> some View {
        let count = max(1, buckets.count)
        let colWidth = (plotWidth - CGFloat(count - 1) * columnSpacing) / CGFloat(count)
        let centerX = CGFloat(index) * (colWidth + columnSpacing) + colWidth / 2
        let clampedX = max(4, min(max(4, plotWidth - tooltipWidth - 4), centerX - tooltipWidth / 2))
        let nonZero = bucket.composition.nonZeroSeries

        return VStack(alignment: .leading, spacing: AppSpacing.xxSmall) {
            HStack(spacing: AppSpacing.small) {
                Text(bucket.tooltipTitle)
                    .font(AppTypography.interfaceCaption.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: AppSpacing.xSmall)
                Text(bucket.composition.total, format: .number.notation(.compactName))
                    .font(AppTypography.interfaceCaption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .monospacedDigit()
            }

            if !nonZero.isEmpty {
                SettingsDivider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(nonZero) { series in
                        let value = bucket.composition.value(for: series)
                        let share = bucket.composition.share(for: series)
                        let isSegFocused = hoveredSegment == series
                        HStack(spacing: 5) {
                            Circle()
                                .fill(series.color)
                                .frame(width: 6, height: 6)
                            Text(series.title)
                                .foregroundStyle(isSegFocused ? AppColors.textPrimary : AppColors.textSecondary)
                            Spacer(minLength: AppSpacing.xSmall)
                            Text(value, format: .number.notation(.compactName))
                                .foregroundStyle(isSegFocused ? AppColors.textPrimary : AppColors.textSecondary)
                                .monospacedDigit()
                            Text(verbatim: "(\(share.formatted(.percent.precision(.fractionLength(0)))))")
                                .foregroundStyle(AppColors.textMuted)
                                .monospacedDigit()
                        }
                        .font(AppTypography.interfaceCaption2.weight(isSegFocused ? .semibold : .regular))
                    }
                }
            }

            SettingsDivider()
            HStack(spacing: AppSpacing.xSmall) {
                if let rate = bucket.composition.cacheHitRate {
                    Text("Cache hit: \(rate.formatted(.percent.precision(.fractionLength(1))))")
                }
                Spacer(minLength: AppSpacing.xSmall)
                Text("\(bucket.requests) requests")
            }
            .font(AppTypography.interfaceCaption2)
            .foregroundStyle(AppColors.textMuted)
            .monospacedDigit()
        }
        .padding(AppSpacing.small)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                .strokeBorder(AppColors.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
        .offset(x: clampedX, y: 4)
        .allowsHitTesting(false)
        .animation(AppMotion.resolved(AppMotion.quickOut), value: hoveredIndex)
    }

    /// Returns segments ordered top-to-bottom for `VStack` rendering (reverse canonical order so `freshInput` is at the bottom).
    private func segmentHeights(for composition: UsageTokenComposition, ceiling: Int) -> [(series: UsageTokenSeries, height: CGFloat)] {
        let nonZero = composition.nonZeroSeries
        guard !nonZero.isEmpty, ceiling > 0, composition.total > 0 else { return [] }

        let gapTotal = CGFloat(nonZero.count - 1) * segmentGap
        let rawTotalHeight = min(plotHeight, (CGFloat(composition.total) / CGFloat(ceiling)) * plotHeight)
        let usableInk = max(CGFloat(nonZero.count) * 2, rawTotalHeight - gapTotal)
        let cappedInk = min(usableInk, max(0, plotHeight - gapTotal))

        var heights = nonZero.map {
            max(CGFloat(2), cappedInk * CGFloat(composition.value(for: $0)) / CGFloat(composition.total))
        }

        // Keep total stack height within `plotHeight` even when tiny segments hit the 2pt floor.
        let sumHeights = heights.reduce(0, +)
        if sumHeights > cappedInk, let maxIdx = heights.indices.max(by: { heights[$0] < heights[$1] }) {
            let excess = sumHeights - cappedInk
            heights[maxIdx] = max(2, heights[maxIdx] - excess)
        }

        return zip(nonZero, heights).reversed().map { (series: $0.0, height: $0.1) }
    }

    private func hitTestSegment(atY pointY: CGFloat, bucket: UsageTrendBucket, ceiling: Int) -> UsageTokenSeries? {
        let segmentsBottomUp = segmentHeights(for: bucket.composition, ceiling: ceiling).reversed()
        var cursorY = plotHeight
        for item in segmentsBottomUp {
            let topY = cursorY - item.height
            if pointY >= topY - 1 && pointY <= cursorY + 1 {
                return item.series
            }
            cursorY = topY - segmentGap
        }
        return nil
    }

    private static func niceCeiling(for maxValue: Int) -> Int {
        guard maxValue > 0 else { return 100 }
        let value = Double(maxValue)
        let mag = pow(10.0, floor(log10(value)))
        let norm = value / mag
        let niceFactors: [Double] = [1.0, 1.2, 1.6, 2.0, 2.4, 3.2, 4.0, 5.0, 6.0, 8.0, 10.0]
        let chosen = niceFactors.first { $0 >= norm } ?? 10.0
        return max(4, Int((chosen * mag).rounded()))
    }
}

/// Arranges compact metric pills horizontally, wrapping cleanly onto new rows.
struct UsageWrappingFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposal.width ?? maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
