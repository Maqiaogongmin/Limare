import SwiftUI
import Charts

private enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        case .all: String(localized: "All time")
        }
    }

    var start: Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

struct UsageSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var period: UsagePeriod = .week
    @State private var kind: UsageKind?
    @State private var report: UsageReport?
    @State private var queryError: String?
    @State private var loading = false
    @State private var refreshID = 0

    private static let inputColor = Color(red: 0.22, green: 0.47, blue: 0.94)
    private static let outputColor = Color(red: 0.16, green: 0.70, blue: 0.50)

    var body: some View {
        SettingsPage {
            headerAndToolbar

            if let failure = appState.usageRecordingStatus.failure {
                InlineStatus(kind: .error, message: "Recording unavailable: \(failure)")
            }

            if let queryError {
                InlineStatus(
                    kind: .error,
                    message: "Usage query failed: \(queryError)",
                    actionTitle: "Retry"
                ) { refreshID += 1 }
            } else if loading && report == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let report {
                if report.totals.requests == 0 {
                    ContentUnavailableView(
                        "No recorded usage",
                        systemImage: "chart.bar",
                        description: Text("No requests match these filters.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.xLarge)
                } else {
                    overview(report)
                    if period != .today {
                        trend(report)
                    }
                    groups(report)
                }
            }
        }
        .task(id: "\(period.rawValue)|\(kind?.rawValue ?? "all")|\(appState.usageProviderFilter?.uuidString ?? "all")|\(refreshID)") {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .usageRecorded)) { _ in refreshID += 1 }
    }

    // MARK: - Header & Toolbar

    private var headerAndToolbar: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                Text("Only model usage recorded on this Mac is included. This is not a provider bill.")
                    .font(AppTypography.interfaceCaption)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: AppSpacing.small)
                if let start = appState.usageRecordingStatus.startedAt {
                    Text("Recording began \(start.formatted(date: .abbreviated, time: .shortened))")
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textMuted)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.small) {
                    periodControl
                    sourcePicker
                    Spacer(minLength: AppSpacing.small)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    periodControl
                    HStack(spacing: AppSpacing.small) {
                        sourcePicker
                        Spacer(minLength: AppSpacing.small)
                        refreshButton
                    }
                }
            }

            if let providerID = appState.usageProviderFilter {
                let name = appState.providers.providers.first(where: { $0.id == providerID })?.name ?? providerID.uuidString
                HStack(spacing: AppSpacing.xSmall) {
                    SettingsBadge("Provider: \(name)")
                    Button("Show all providers") {
                        appState.usageProviderFilter = nil
                    }
                    .buttonStyle(.settingsOutline)
                }
                .font(AppTypography.interfaceCaption)
            }
        }
    }

    private var periodControl: some View {
        SettingsSegmentedPicker(
            selection: $period,
            options: UsagePeriod.allCases.map { (value: $0, title: $0.title) }
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Time")
    }

    private var sourcePicker: some View {
        Picker("Source", selection: $kind) {
            Text("All sources").tag(UsageKind?.none)
            Divider()
            Section("Primary") {
                ForEach([UsageKind.chat, .subagent, .scheduled], id: \.self) { item in
                    Text(item.displayName).tag(Optional(item))
                }
            }
            Section("System & Auxiliary") {
                ForEach([UsageKind.title, .compaction, .modelTool, .vision, .permissionReview, .quickTest, .other], id: \.self) { item in
                    Text(item.displayName).tag(Optional(item))
                }
            }
        }
        .fixedSize()
    }

    private var refreshButton: some View {
        Button { refreshID += 1 } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.settingsOutline)
        .help("Refresh usage")
    }

    // MARK: - Overview

    private func overview(_ report: UsageReport) -> some View {
        SettingsSection(
            title: "Overview",
            description: "Requests count model calls, including tool loops and retries that start a new call."
        ) {
            HStack(alignment: .top, spacing: 0) {
                kpiColumn(title: String(localized: "Input tokens"), value: format(report.totals.input)) {
                    let tags = nonZeroInputTags(report.totals)
                    if !tags.isEmpty {
                        WrappingTagFlow(spacing: 4) {
                            ForEach(tags, id: \.self) { tag in
                                subMetricTag(tag)
                            }
                        }
                    }
                }

                verticalDivider

                kpiColumn(title: String(localized: "Output tokens"), value: format(report.totals.output)) {
                    if let reasoning = report.totals.reasoning, reasoning > 0 {
                        subMetricTag(String(localized: "Reasoning: \(reasoning.formatted())"))
                    }
                }

                verticalDivider

                kpiColumn(title: String(localized: "Requests"), value: report.totals.requests.formatted()) {
                    let totalTokens = (report.totals.input ?? 0) + (report.totals.output ?? 0)
                    if totalTokens > 0 {
                        Text("Total: \(totalTokens.formatted())")
                            .font(AppTypography.interfaceCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func kpiColumn<Detail: View>(
        title: String,
        value: String,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(title)
                .font(AppTypography.interfaceCaption)
                .foregroundStyle(AppColors.textSecondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            detail()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 1)
            .padding(.vertical, 2)
            .padding(.horizontal, AppSpacing.standard)
            .accessibilityHidden(true)
    }

    private func subMetricTag(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.interfaceCaption2)
            .foregroundStyle(AppColors.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private func nonZeroInputTags(_ totals: UsageTotals) -> [String] {
        var tags: [String] = []
        if let cacheRead = totals.cacheRead, cacheRead > 0 {
            tags.append(String(localized: "Cache read: \(cacheRead.formatted())"))
        }
        if let cacheWrite = totals.cacheWrite, cacheWrite > 0 {
            tags.append(String(localized: "Cache write: \(cacheWrite.formatted())"))
        }
        if let toolPrompts = totals.toolUsePrompt, toolPrompts > 0 {
            tags.append(String(localized: "Tool prompts: \(toolPrompts.formatted())"))
        }
        return tags
    }

    // MARK: - Daily Trend

    private func trend(_ report: UsageReport) -> some View {
        let days = filledDays(for: report)
        let strideCount = max(1, days.count > 10 ? days.count / 6 : 1)
        return SettingsSection(
            title: "Daily trend",
            description: "Input and output tokens by local calendar day.",
            trailing: { chartLegend }
        ) {
            Chart(days) { day in
                BarMark(
                    x: .value("Date", day.date, unit: .day),
                    y: .value("Tokens", day.totals.input ?? 0)
                )
                .foregroundStyle(Self.inputColor)
                .cornerRadius(3)

                BarMark(
                    x: .value("Date", day.date, unit: .day),
                    y: .value("Tokens", day.totals.output ?? 0)
                )
                .foregroundStyle(Self.outputColor)
                .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: strideCount)) { _ in
                    AxisValueLabel(
                        format: .dateTime.month(.defaultDigits).day(.defaultDigits),
                        centered: true
                    )
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(count, format: .number.notation(.compactName))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .frame(height: 175)
        }
    }

    private var chartLegend: some View {
        HStack(spacing: AppSpacing.medium) {
            legendItem(color: Self.inputColor, title: "Input")
            legendItem(color: Self.outputColor, title: "Output")
        }
        .font(AppTypography.interfaceCaption)
        .foregroundStyle(AppColors.textSecondary)
    }

    private func legendItem(color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
        }
    }

    private func filledDays(for report: UsageReport) -> [UsageDay] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay: Date
        switch period {
        case .today:
            startDay = today
        case .week:
            startDay = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            startDay = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all:
            let earliest = report.days.map { calendar.startOfDay(for: $0.date) }.min() ?? today
            let minWindowStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            startDay = min(earliest, minWindowStart)
        }

        var byDay: [Date: UsageTotals] = [:]
        for day in report.days {
            byDay[calendar.startOfDay(for: day.date)] = day.totals
        }

        var result: [UsageDay] = []
        var cursor = startDay
        while cursor <= today {
            let totals = byDay[cursor] ?? UsageTotals(requests: 0, input: 0, output: 0)
            result.append(UsageDay(date: cursor, totals: totals))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    // MARK: - Providers & Models

    private func groups(_ report: UsageReport) -> some View {
        let maxGroupTokens = max(1, report.groups.map { ($0.totals.input ?? 0) + ($0.totals.output ?? 0) }.max() ?? 1)
        return SettingsSection(
            title: "Providers and models",
            description: "Names are saved at the time of each request."
        ) {
            ForEach(report.groups) { group in
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xSmall) {
                        HStack(spacing: 4) {
                            Text(group.provider)
                                .font(AppTypography.interfaceSemibold)
                            Text("/")
                                .foregroundStyle(AppColors.textMuted)
                            Text(group.model)
                                .font(AppTypography.interfaceMedium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: AppSpacing.small)
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                            Text(format(groupTotalTokens(group.totals)))
                                .font(AppTypography.interfaceSemibold)
                                .monospacedDigit()
                            Text("\(group.totals.requests) requests")
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(AppColors.textSecondary)
                                .monospacedDigit()
                        }
                    }

                    groupShareBar(totals: group.totals, maxTokens: maxGroupTokens)

                    Text(groupDetailLine(group.totals))
                        .font(AppTypography.interfaceCaption)
                        .foregroundStyle(AppColors.textSecondary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)

                if group.id != report.groups.last?.id {
                    SettingsDivider()
                }
            }
        }
    }

    private func groupShareBar(totals: UsageTotals, maxTokens: Int) -> some View {
        let input = max(0, totals.input ?? 0)
        let output = max(0, totals.output ?? 0)
        let total = input + output
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.05))
                if total > 0 && geo.size.width > 0 {
                    let filledWidth = max(4, geo.size.width * CGFloat(total) / CGFloat(maxTokens))
                    let inputRatio = CGFloat(input) / CGFloat(total)
                    let outputRatio = CGFloat(output) / CGFloat(total)
                    HStack(spacing: input > 0 && output > 0 ? 1 : 0) {
                        if input > 0 {
                            Rectangle()
                                .fill(Self.inputColor)
                                .frame(width: filledWidth * inputRatio)
                        }
                        if output > 0 {
                            Rectangle()
                                .fill(Self.outputColor)
                                .frame(width: filledWidth * outputRatio)
                        }
                    }
                    .frame(width: filledWidth, height: 4, alignment: .leading)
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func groupTotalTokens(_ totals: UsageTotals) -> Int? {
        guard totals.input != nil || totals.output != nil else { return nil }
        return (totals.input ?? 0) + (totals.output ?? 0)
    }

    private func groupDetailLine(_ totals: UsageTotals) -> String {
        var parts = [
            String(localized: "Input: \(format(totals.input))"),
            String(localized: "Output: \(format(totals.output))")
        ]
        if let cacheRead = totals.cacheRead, cacheRead > 0 {
            parts.append(String(localized: "Cache read: \(cacheRead.formatted())"))
        }
        if let cacheWrite = totals.cacheWrite, cacheWrite > 0 {
            parts.append(String(localized: "Cache write: \(cacheWrite.formatted())"))
        }
        if let reasoning = totals.reasoning, reasoning > 0 {
            parts.append(String(localized: "Reasoning: \(reasoning.formatted())"))
        }
        if let toolPrompts = totals.toolUsePrompt, toolPrompts > 0 {
            parts.append(String(localized: "Tool prompts: \(toolPrompts.formatted())"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Helpers & Loading

    private func format(_ value: Int?) -> String { value.map { $0.formatted() } ?? "—" }

    @MainActor private func load() async {
        guard let recorder = appState.usageRecorder else { report = nil; return }
        loading = true
        queryError = nil
        do {
            let value = try await recorder.report(since: period.start, kind: kind, providerID: appState.usageProviderFilter)
            guard !Task.isCancelled else { return }
            report = value
        } catch {
            guard !Task.isCancelled else { return }
            report = nil
            queryError = error.localizedDescription
        }
        loading = false
    }
}

/// Arranges compact metric tags horizontally, wrapping cleanly onto new rows within narrow KPI columns.
private struct WrappingTagFlow: Layout {
    var spacing: CGFloat = 4

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
