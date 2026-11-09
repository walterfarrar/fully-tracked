import Charts
import SwiftData
import SwiftUI

struct GraphsView: View {
    @EnvironmentObject private var health: HealthSteps
    @Query private var entries: [JournalEntry]
    @Query private var rollups: [HealthDailyRollup]
    @State private var dayCount = 7
    @State private var metric: TrendMetric = .hydration
    @State private var healthMetric: HealthChartMetric = .steps
    @State private var showingHealth = false

    private var series: TrendSeries {
        JournalMath.series(entries, metric: metric, dayCount: dayCount)
    }

    private var healthDays: [Date] {
        HealthDay.starts(count: dayCount)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    NavigationLink {
                        HealthView()
                    } label: {
                        HStack(spacing: 12) {
                            Text("Health")
                                .font(Theme.font(18))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .light))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    HStack(alignment: .lastTextBaseline) {
                        Text("Graphs")
                            .font(Theme.font(28, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 12)
                        Picker("Range", selection: $dayCount) {
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 190)
                        .tint(Theme.accent)
                    }
                    Text("Journal")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                    ChipFlow {
                        ForEach(TrendMetric.allCases) { item in
                            Chip(title: item.title, selected: !showingHealth && metric == item) {
                                showingHealth = false
                                metric = item
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Metric")
                    Text("Health")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                    ChipFlow {
                        ForEach(HealthChartMetric.allCases) { item in
                            Chip(title: item.title, selected: showingHealth && healthMetric == item) {
                                showingHealth = true
                                healthMetric = item
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Health metric")
                    Text(showingHealth ? healthMetric.detail : metric.detail)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                    if showingHealth {
                        healthBody
                    } else {
                        journalBody
                    }
                    if showingHealth || metric == .steps {
                        Text(health.status)
                            .font(Theme.font(14))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var journalBody: some View {
        if series.empty {
            Text(series.emptyMessage)
                .font(Theme.font(17))
                .foregroundStyle(Theme.muted)
                .padding(.top, 8)
        } else {
            Text(summaryText(series))
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
            journalChart
        }
    }

    @ViewBuilder
    private var healthBody: some View {
        if healthMetric == .sleep {
            if sleepPoints.isEmpty {
                Text("No sleep from Apple Health in the last \(healthDays.count) days.")
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 8)
            } else {
                Text(sleepSummary)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                sleepChart
            }
        } else if healthPoints.isEmpty {
            Text("No \(healthMetric.title.lowercased()) from Apple Health in the last \(healthDays.count) days.")
                .font(Theme.font(17))
                .foregroundStyle(Theme.muted)
                .padding(.top, 8)
        } else {
            Text(healthSummary)
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
            quantityChart
        }
    }

    @ViewBuilder
    private var journalChart: some View {
        if series.kind == .stacked {
            Chart(series.points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value(series.metric.unit, point.value)
                )
                .foregroundStyle(by: .value("Strength", point.strength))
            }
            .chartForegroundStyleScale(range: GraphPalette.colors)
            .chartLegend(.visible)
            .modifier(GraphFrame(series: series))
        } else {
            Chart(series.points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value(series.metric.unit, point.value)
                )
                .foregroundStyle(Theme.accent)
            }
            .chartLegend(.hidden)
            .modifier(GraphFrame(series: series))
        }
    }

    private var quantityChart: some View {
        Chart(healthPoints) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value(healthMetric.unit, point.value)
            )
            .foregroundStyle(Theme.accent)
        }
        .chartLegend(.hidden)
        .modifier(GraphFrame(
            domainStart: healthDomainStart,
            domainEnd: healthDomainEnd,
            dayCount: healthDays.count,
            yDomain: barDomain(healthPoints.map(\.value)),
            accessibilityLabel: "\(healthMetric.title) chart"
        ))
    }

    private var sleepChart: some View {
        Chart(sleepPoints) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Hours", point.value)
            )
            .foregroundStyle(by: .value("Stage", point.series))
        }
        .chartForegroundStyleScale(domain: sleepLegend, range: sleepColors)
        .chartLegend(.visible)
        .modifier(GraphFrame(
            domainStart: healthDomainStart,
            domainEnd: healthDomainEnd,
            dayCount: healthDays.count,
            yDomain: barDomain(sleepDayTotals),
            accessibilityLabel: "Sleep chart"
        ))
    }

    private var healthPoints: [HealthDayValue] {
        guard let raw = healthMetric.typeRaw, let type = HealthCatalog.byRaw[raw] else { return [] }
        let allowed = Set(healthDays)
        return rollups.compactMap { rollup in
            let day = HealthDay.start(of: rollup.day)
            guard rollup.typeRaw == raw, allowed.contains(day) else { return nil }
            guard let value = HealthCatalog.value(rollup, aggregate: type.aggregate), value.isFinite else { return nil }
            return HealthDayValue(day: day, value: value, series: healthMetric.title)
        }
        .sorted { $0.day < $1.day }
    }

    private var sleepRows: [HealthDailyRollup] {
        let allowed = Set(healthDays)
        return rollups.filter { rollup in
            allowed.contains(HealthDay.start(of: rollup.day)) && rollup.typeRaw.hasPrefix("sleepAnalysis")
        }
    }

    private var sleepPoints: [HealthDayValue] {
        let present = Set(sleepRows.map(\.typeRaw))
        let keys = HealthSleep.chartKeys(present: present)
        return sleepRows.compactMap { rollup in
            guard keys.contains(rollup.typeRaw), let value = rollup.sum, value.isFinite, value > 0 else { return nil }
            return HealthDayValue(
                day: HealthDay.start(of: rollup.day),
                value: value,
                series: HealthSleep.title(for: rollup.typeRaw)
            )
        }
        .sorted { $0.series < $1.series }
    }

    private var sleepLegend: [String] {
        let order = ["Awake", "Asleep", "Core", "Deep", "REM", "In bed"]
        let present = Set(sleepPoints.map(\.series))
        return order.filter { present.contains($0) }
    }

    private var sleepColors: [Color] {
        let palette = GraphPalette.colors
        return sleepLegend.enumerated().map { index, _ in
            palette[index % palette.count]
        }
    }

    private var sleepDayTotals: [Double] {
        let grouped = Dictionary(grouping: sleepPoints, by: \.day)
        return grouped.values.map { points in
            points.reduce(0) { $0 + $1.value }
        }
    }

    private var sleepSummary: String {
        let keys = Set(HealthSleep.summaryKeys(present: Set(sleepRows.map(\.typeRaw))))
        let total = sleepRows.reduce(0.0) { partial, rollup in
            guard keys.contains(rollup.typeRaw) else { return partial }
            return partial + (rollup.sum ?? 0)
        }
        return String(format: "%.1f hours", locale: Locale(identifier: "en_US_POSIX"), total)
    }

    private var healthSummary: String {
        let values = healthPoints.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else { return "" }
        let total = values.reduce(0, +)
        switch healthMetric {
        case .steps:
            return "\(Int(total.rounded()).formatted(.number.grouping(.automatic))) steps"
        case .distance:
            return String(format: "%.2f km", locale: Locale(identifier: "en_US_POSIX"), total)
        case .activeEnergy:
            return "\(Int(total.rounded()).formatted(.number.grouping(.automatic))) kcal"
        case .exercise, .daylight:
            return "\(Int(total.rounded()).formatted(.number.grouping(.automatic))) min"
        case .restingHeartRate, .hrv, .oxygen:
            let average = total / Double(values.count)
            return "Average \(HealthCatalog.format(average, typeRaw: healthMetric.typeRaw ?? "", unit: healthMetric.unit == "bpm" ? "bpm" : healthMetric.unit))"
        case .weight:
            let latest = healthPoints.max { $0.day < $1.day }?.value ?? values[values.count - 1]
            return String(format: "Latest %.1f kg", locale: Locale(identifier: "en_US_POSIX"), latest)
        case .sleep:
            return sleepSummary
        }
    }

    private var healthDomainStart: Date {
        healthDays.first ?? HealthDay.start(of: Date())
    }

    private var healthDomainEnd: Date {
        HealthDay.next(healthDays.last ?? healthDomainStart)
    }

    private func barDomain(_ values: [Double]) -> ClosedRange<Double> {
        let peak = values.filter(\.isFinite).max() ?? 0
        return 0...(max(peak, 1) * 1.1)
    }

    private func summaryText(_ series: TrendSeries) -> String {
        let values = series.points.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else { return "" }
        let total = values.reduce(0, +)
        switch series.metric {
        case .hydration, .coffee:
            return "\(FormValues.display(total)) ml total"
        case .meals:
            guard let count = whole(total) else { return "" }
            return count == 1 ? "1 meal" : "\(count) meals"
        case .mood:
            return "Average \(FormValues.display(total / Double(values.count)))"
        case .sleep:
            return "\(FormValues.display(total)) hours total"
        case .steps:
            guard let count = whole(total) else { return "" }
            return "\(count.formatted(.number.grouping(.automatic))) steps across logged days"
        case .temperature:
            return "Average \(FormValues.display(total / Double(values.count)))°F"
        case .activeMinutes:
            guard let count = whole(total) else { return "" }
            return count == 1 ? "1 active minute" : "\(count) active minutes"
        case .placesVisited:
            guard let count = whole(total) else { return "" }
            return count == 1 ? "1 place" : "\(count) places"
        }
    }

    private func whole(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < Double(Int.max) else { return nil }
        return Int(value.rounded())
    }
}

private enum GraphPalette {
    static let colors = [
        Color(red: 212 / 255, green: 184 / 255, blue: 150 / 255),
        Color(red: 196 / 255, green: 137 / 255, blue: 106 / 255),
        Color(red: 156 / 255, green: 175 / 255, blue: 150 / 255),
        Color(red: 138 / 255, green: 164 / 255, blue: 181 / 255),
        Color(red: 224 / 255, green: 160 / 255, blue: 151 / 255),
        Color(red: 168 / 255, green: 159 / 255, blue: 148 / 255),
    ]
}

private struct GraphFrame: ViewModifier {
    var domainStart: Date
    var domainEnd: Date
    var dayCount: Int
    var yDomain: ClosedRange<Double>?
    var chartLabel: String

    init(series: TrendSeries) {
        domainStart = series.domainStart
        domainEnd = series.domainEnd
        dayCount = series.dayCount
        yDomain = series.yDomain
        chartLabel = "\(series.metric.title) chart"
    }

    init(
        domainStart: Date,
        domainEnd: Date,
        dayCount: Int,
        yDomain: ClosedRange<Double>?,
        accessibilityLabel: String
    ) {
        self.domainStart = domainStart
        self.domainEnd = domainEnd
        self.dayCount = dayCount
        self.yDomain = yDomain
        self.chartLabel = accessibilityLabel
    }

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: domainStart...domainEnd)
            .modifier(GraphYScale(domain: yDomain))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: dayCount == 7 ? 7 : 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 300)
            .accessibilityLabel(chartLabel)
    }
}

private struct GraphYScale: ViewModifier {
    var domain: ClosedRange<Double>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else {
            content
        }
    }
}
