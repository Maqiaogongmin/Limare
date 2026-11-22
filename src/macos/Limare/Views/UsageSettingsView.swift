import SwiftUI

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

private enum UsageGroupSort: String, CaseIterable, Identifiable {
    case tokens, requests, name
    var id: Self { self }
    var title: String {
        switch self {
        case .tokens: String(localized: "Total tokens")
        case .requests: String(localized: "Requests")
        case .name: String(localized: "Name")
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
    @State private var expandedGroups: Set<String> = []
    @State private var groupSort: UsageGroupSort = .tokens

    @State private var highlightedSeries: UsageTokenSeries?
    @State private var overviewComposition = UsageTokenComposition(totals: UsageTotals())
    @State private var trendBuckets: [UsageTrendBucket] = []
    @State private var trendIsWeekly = false
    @State private var activeTrendSeries: [UsageTokenSeries] = []
    @State private var sortedGroups: [UsageGroup] = []
    @State private var maxGroupTokens = 1

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
                        trend()
                    }
                    groups()
                }
            }
        }
        .task(id: "\(period.rawValue)|\(kind?.rawValue ?? "all")|\(appState.usageProviderFilter?.uuidString ?? "all")|\(refreshID)") {
            await load()
        }
        .onChange(of: groupSort) { _, _ in
            if let report {
                recomputeGroups(for: report)
            }
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
            description: "Requests count model calls, including tool loops and retries that start a new call. Cache figures use requests with complete cache data."
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                HStack(alignment: .top, spacing: 0) {
                    kpiColumn(
                        title: String(localized: "Input tokens"),
                        value: format(report.totals.input),
                        numericValue: report.totals.input
                    ) {
                        if report.totals.cacheMeasuredInput > 0 {
                            let rate = Double(report.totals.cacheMeasuredRead) / Double(report.totals.cacheMeasuredInput)
                            Text("Cache hit: \(rate.formatted(.percent.precision(.fractionLength(1))))")
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(AppColors.textSecondary)
                                .monospacedDigit()
                        }
                        let auxTags = nonZeroAuxiliaryInputTags(report.totals)
                        if !auxTags.isEmpty {
                            UsageWrappingFlow(spacing: AppSpacing.xxSmall) {
                                ForEach(auxTags, id: \.self) { tag in
                                    subMetricTag(tag)
                                }
                            }
                        }
                    }

                    verticalDivider

                    kpiColumn(
                        title: String(localized: "Output tokens"),
                        value: format(report.totals.output),
                        numericValue: report.totals.output
                    ) {
                        if let reasoning = report.totals.reasoning, reasoning > 0 {
                            Text("Reasoning: \(reasoning.formatted())")
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(AppColors.textSecondary)
                                .monospacedDigit()
                        }
                    }

                    verticalDivider

                    kpiColumn(
                        title: String(localized: "Requests"),
                        value: report.totals.requests.formatted(),
                        numericValue: report.totals.requests
                    ) {
                        let totalTokens = overviewComposition.total
                        if totalTokens > 0 {
                            Text("Total: \(totalTokens.formatted())")
                                .font(AppTypography.interfaceCaption)
                                .foregroundStyle(AppColors.textSecondary)
                                .monospacedDigit()
                        }
                    }
                }

                SettingsDivider()

                UsageCompositionBar(
                    composition: overviewComposition,
                    totals: report.totals,
                    activeSeries: $highlightedSeries
                )
            }
        }
    }

    private func kpiColumn<Detail: View>(
        title: String,
        value: String,
        numericValue: Int?,
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
                .contentTransition(.numericText(value: Double(numericValue ?? 0)))
                .animation(AppMotion.resolved(AppMotion.layout), value: numericValue)
            detail()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(width: 1)
            .padding(.vertical, AppSpacing.xxxSmall)
            .padding(.horizontal, AppSpacing.standard)
            .accessibilityHidden(true)
    }

    private func subMetricTag(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.interfaceCaption2)
            .foregroundStyle(AppColors.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, AppSpacing.xSmall)
            .padding(.vertical, AppSpacing.xxxSmall)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    private func nonZeroAuxiliaryInputTags(_ totals: UsageTotals) -> [String] {
        var tags: [String] = []
        if let cacheWrite = totals.cacheWrite, cacheWrite > 0 {
            tags.append(String(localized: "Cache write: \(cacheWrite.formatted())"))
        }
        if let toolPrompts = totals.toolUsePrompt, toolPrompts > 0 {
            tags.append(String(localized: "Tool prompts: \(toolPrompts.formatted())"))
        }
        return tags
    }

    // MARK: - Daily Trend

    private func trend() -> some View {
        SettingsSection(
            title: "Daily trend",
            description: trendIsWeekly
                ? LocalizedStringKey("Token breakdown grouped by week.")
                : LocalizedStringKey("Token breakdown by local calendar day."),
            trailing: {
                HStack(spacing: AppSpacing.small) {
                    if trendIsWeekly {
                        SettingsBadge("By week")
                    }
                    if !activeTrendSeries.isEmpty {
                        UsageSeriesLegend(series: activeTrendSeries, activeSeries: $highlightedSeries)
                    }
                }
            }
        ) {
            UsageDailyTrendChart(buckets: trendBuckets, highlightedSeries: $highlightedSeries)
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

    private func groups() -> some View {
        SettingsSection(
            title: "Providers and models",
            description: "Names are saved at the time of each request.",
            trailing: {
                Picker("Sort by", selection: $groupSort) {
                    ForEach(UsageGroupSort.allCases) { sort in Text(sort.title).tag(sort) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        ) {
            HStack {
                Text("Provider / Model").frame(maxWidth: .infinity, alignment: .leading)
                Text("Total tokens").frame(width: 125, alignment: .trailing)
                Text("Requests").frame(width: 75, alignment: .trailing)
                Text("Cache hit rate").frame(width: 100, alignment: .trailing)
            }
            .font(AppTypography.interfaceCaption)
            .foregroundStyle(AppColors.textSecondary)
            .padding(.leading, AppSpacing.large)

            ForEach(sortedGroups) { group in
                let isExpanded = expandedGroups.contains(group.id)
                let tokens = groupTotalTokens(group.totals)
                let ratio = tokens.map { CGFloat($0) / CGFloat(max(1, maxGroupTokens)) } ?? 0

                SettingsDivider()
                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                    Button {
                        withAnimation(AppMotion.resolved(AppMotion.standard)) {
                            if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
                        }
                    } label: {
                        HStack(spacing: AppSpacing.xSmall) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .frame(width: 14)

                            VStack(alignment: .leading, spacing: AppSpacing.xxxSmall) {
                                Text(group.model).font(AppTypography.interfaceMedium).lineLimit(1)
                                Text(group.provider).font(AppTypography.interfaceCaption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(format(tokens))
                                .padding(.horizontal, AppSpacing.xSmall)
                                .padding(.vertical, AppSpacing.xxxSmall)
                                .frame(width: 125, alignment: .trailing)
                                .background(alignment: .trailing) {
                                    if ratio > 0 {
                                        GeometryReader { geo in
                                            RoundedRectangle(cornerRadius: AppRadius.small, style: .continuous)
                                                .fill(UsageTokenSeries.rowBarTint)
                                                .frame(width: max(4, geo.size.width * ratio))
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                        }
                                    }
                                }

                            Text(group.totals.requests.formatted()).frame(width: 75, alignment: .trailing)
                            Text(cacheRate(group.totals)).frame(width: 100, alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .monospacedDigit()

                    if isExpanded {
                        Text(groupDetailLine(group.totals))
                            .font(AppTypography.interfaceCaption)
                            .foregroundStyle(AppColors.textSecondary)
                            .monospacedDigit()
                            .padding(.leading, AppSpacing.large)
                            .textSelection(.enabled)
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, AppSpacing.xxSmall)
            }
        }
    }

    private func cacheRate(_ totals: UsageTotals) -> String {
        guard totals.cacheMeasuredInput > 0 else { return "—" }
        return (Double(totals.cacheMeasuredRead) / Double(totals.cacheMeasuredInput)).formatted(.percent.precision(.fractionLength(1)))
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
        if totals.cacheMeasuredInput > 0 {
            let rate = Double(totals.cacheMeasuredRead) / Double(totals.cacheMeasuredInput)
            parts.append(String(localized: "Cache hit: \(totals.cacheMeasuredRead.formatted()) (\(rate.formatted(.percent.precision(.fractionLength(1)))))"))
            parts.append(String(localized: "Cache miss: \((totals.cacheMeasuredInput - totals.cacheMeasuredRead).formatted())"))
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

    private func recomputeDerivedState(for report: UsageReport) {
        overviewComposition = UsageTokenComposition(totals: report.totals)
        let days = filledDays(for: report)
        let (buckets, isWeekly) = UsageTrendBucket.buckets(from: days)
        trendBuckets = buckets
        trendIsWeekly = isWeekly
        activeTrendSeries = UsageTokenSeries.allCases.filter { series in
            buckets.contains { $0.composition.value(for: series) > 0 }
        }
        if let active = highlightedSeries, overviewComposition.value(for: active) == 0 {
            highlightedSeries = nil
        }
        recomputeGroups(for: report)
    }

    private func recomputeGroups(for report: UsageReport) {
        let sorted = report.groups.sorted { lhs, rhs in
            switch groupSort {
            case .tokens: return (groupTotalTokens(lhs.totals) ?? -1) > (groupTotalTokens(rhs.totals) ?? -1)
            case .requests: return lhs.totals.requests > rhs.totals.requests
            case .name: return (lhs.provider + lhs.model).localizedStandardCompare(rhs.provider + rhs.model) == .orderedAscending
            }
        }
        sortedGroups = sorted
        maxGroupTokens = max(1, sorted.compactMap { groupTotalTokens($0.totals) }.max() ?? 1)
    }

    @MainActor private func load() async {
        guard let recorder = appState.usageRecorder else {
            report = nil
            overviewComposition = UsageTokenComposition(totals: UsageTotals())
            trendBuckets = []
            trendIsWeekly = false
            activeTrendSeries = []
            sortedGroups = []
            maxGroupTokens = 1
            return
        }
        loading = true
        queryError = nil
        do {
            let value = try await recorder.report(since: period.start, kind: kind, providerID: appState.usageProviderFilter)
            guard !Task.isCancelled else { return }
            report = value
            recomputeDerivedState(for: value)
        } catch {
            guard !Task.isCancelled else { return }
            report = nil
            queryError = error.localizedDescription
        }
        loading = false
    }
}
