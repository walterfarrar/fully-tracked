import Charts
import SwiftData
import SwiftUI

struct HealthView: View {
    @EnvironmentObject private var health: HealthSteps
    @Query private var rollups: [HealthDailyRollup]

    private var sections: [HealthBoardSection] {
        HealthBoard.sections(from: rollups)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Health")
                    .font(Theme.font(28, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if sections.isEmpty {
                    Text("Nothing from Apple Health is on this device yet.")
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, 8)
                    Text("Allow access when iOS asks. To change it later, open the Health app, then Sharing, then Apps, then Fully Tracked.")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(Theme.font(20, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .padding(.top, 6)
                            ForEach(section.rows) { row in
                                HealthMetricRowView(row: row)
                            }
                        }
                    }
                }
                Text(health.status)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

private struct HealthMetricRowView: View {
    var row: HealthBoardRow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(Theme.font(16))
                    .foregroundStyle(Theme.ink)
                Text(row.today)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
                Text(row.week)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HealthSparkline(points: row.points)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HealthSparkline: View {
    var points: [HealthDayValue]

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(Theme.accent)
            .interpolationMethod(.linear)
            PointMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Value", point.value)
            )
            .foregroundStyle(Theme.accent)
            .symbolSize(points.count == 1 ? 28 : 12)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(width: 84, height: 36)
        .accessibilityHidden(true)
    }
}

struct HealthBoardSection: Identifiable {
    var title: String
    var rows: [HealthBoardRow]

    var id: String { title }
}

struct HealthBoardRow: Identifiable {
    var id: String
    var title: String
    var today: String
    var week: String
    var points: [HealthDayValue]
}

enum HealthBoard {
    static func sections(from rollups: [HealthDailyRollup], now: Date = Date()) -> [HealthBoardSection] {
        let today = HealthDay.start(of: now)
        let start = Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
        let window = rollups.filter { rollup in
            let day = HealthDay.start(of: rollup.day)
            return day >= start && day <= today
        }
        return HealthGroup.allCases.compactMap { group in
            let rows = rows(for: group, window: window, today: today)
            guard !rows.isEmpty else { return nil }
            return HealthBoardSection(title: group.title, rows: rows)
        }
    }

    private static func rows(for group: HealthGroup, window: [HealthDailyRollup], today: Date) -> [HealthBoardRow] {
        if group == .sleep {
            return sleepRows(window: window, today: today)
        }
        return HealthCatalog.types.compactMap { type in
            guard type.group == group, type.kind != .sleep else { return nil }
            let matches = window.filter { $0.typeRaw == type.typeRaw }
            let points = metricPoints(matches, aggregate: type.aggregate, series: type.typeRaw)
            guard !points.isEmpty else { return nil }
            return HealthBoardRow(
                id: type.typeRaw,
                title: type.title,
                today: headline(points, today: today, type: type),
                week: weekline(points, aggregate: type.aggregate, type: type),
                points: points
            )
        }
    }

    private static func sleepRows(window: [HealthDailyRollup], today: Date) -> [HealthBoardRow] {
        let rows = window.filter { $0.typeRaw.hasPrefix("sleepAnalysis") }
        let present = Set(rows.map(\.typeRaw))
        let stages = HealthSleep.chartKeys(present: present)
        guard !stages.isEmpty else { return [] }
        var result: [HealthBoardRow] = []
        if stages.count > 1 {
            let keys = HealthSleep.summaryKeys(present: present)
            let points = summed(rows: rows, keys: keys, series: "asleep-total")
            if !points.isEmpty {
                result.append(sleepRow(id: "sleep-total", title: "Asleep", points: points, today: today))
            }
        }
        for key in stages {
            let points = summed(rows: rows, keys: [key], series: key)
            guard !points.isEmpty else { continue }
            result.append(sleepRow(id: key, title: HealthSleep.title(for: key), points: points, today: today))
        }
        return result
    }

    private static func sleepRow(id: String, title: String, points: [HealthDayValue], today: Date) -> HealthBoardRow {
        let todayText: String
        if let point = points.first(where: { HealthDay.start(of: $0.day) == today }) {
            todayText = "Today \(hours(point.value))"
        } else if let latest = points.max(by: { $0.day < $1.day }) {
            todayText = "Latest \(hours(latest.value))"
        } else {
            todayText = ""
        }
        let total = points.reduce(0) { $0 + $1.value }
        return HealthBoardRow(
            id: id,
            title: title,
            today: todayText,
            week: "7-day total \(hours(total))",
            points: points
        )
    }

    private static func summed(rows: [HealthDailyRollup], keys: [String], series: String) -> [HealthDayValue] {
        let allowed = Set(keys)
        var totals: [Date: Double] = [:]
        for row in rows where allowed.contains(row.typeRaw) {
            let day = HealthDay.start(of: row.day)
            totals[day, default: 0] += row.sum ?? 0
        }
        return totals
            .filter { $0.value.isFinite && $0.value > 0 }
            .map { HealthDayValue(day: $0.key, value: $0.value, series: series) }
            .sorted { $0.day < $1.day }
    }

    private static func metricPoints(
        _ rows: [HealthDailyRollup],
        aggregate: HealthAggregate,
        series: String
    ) -> [HealthDayValue] {
        rows.compactMap { rollup in
            guard let value = HealthCatalog.value(rollup, aggregate: aggregate), value.isFinite else { return nil }
            return HealthDayValue(day: HealthDay.start(of: rollup.day), value: value, series: series)
        }
        .sorted { $0.day < $1.day }
    }

    private static func headline(_ points: [HealthDayValue], today: Date, type: HealthReadType) -> String {
        if let point = points.first(where: { HealthDay.start(of: $0.day) == today }) {
            return "Today \(HealthCatalog.format(point.value, type: type))"
        }
        if let latest = points.max(by: { $0.day < $1.day }) {
            return "Latest \(HealthCatalog.format(latest.value, type: type))"
        }
        return ""
    }

    private static func weekline(_ points: [HealthDayValue], aggregate: HealthAggregate, type: HealthReadType) -> String {
        let values = points.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else { return "" }
        switch aggregate {
        case .sum:
            let total = values.reduce(0, +)
            return "7-day total \(HealthCatalog.format(total, type: type))"
        case .average:
            let average = values.reduce(0, +) / Double(values.count)
            return "7-day average \(HealthCatalog.format(average, type: type))"
        case .latest:
            guard let latest = points.max(by: { $0.day < $1.day }) else { return "" }
            return "7-day latest \(HealthCatalog.format(latest.value, type: type))"
        }
    }

    private static func hours(_ value: Double) -> String {
        String(format: "%.1f h", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
