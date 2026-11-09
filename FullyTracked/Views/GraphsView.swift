import Charts
import SwiftData
import SwiftUI

struct GraphsView: View {
    @EnvironmentObject private var health: HealthSteps
    @Query private var entries: [JournalEntry]
    @State private var dayCount = 7
    @State private var metric: TrendMetric = .hydration

    private var series: TrendSeries {
        JournalMath.series(entries, metric: metric, dayCount: dayCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
                ChipFlow {
                    ForEach(TrendMetric.allCases) { item in
                        Chip(title: item.title, selected: metric == item) {
                            metric = item
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Metric")
                Text(metric.detail)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                if series.empty {
                    Text(series.emptyMessage)
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 8)
                } else {
                    Text(summaryText(series))
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                    chart
                }
                if metric == .steps {
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
    }

    @ViewBuilder
    private var chart: some View {
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
    var series: TrendSeries

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: series.domainStart...series.domainEnd)
            .modifier(GraphYScale(domain: series.yDomain))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: series.dayCount == 7 ? 7 : 6)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 300)
            .accessibilityLabel("\(series.metric.title) chart")
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
