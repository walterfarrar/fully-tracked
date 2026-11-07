import Foundation

enum TrendMetric: String, CaseIterable, Identifiable {
    case hydration
    case coffee
    case meals
    case mood
    case sleep
    case steps
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hydration: "Hydration"
        case .coffee: "Coffee"
        case .meals: "Meals"
        case .mood: "Mood"
        case .sleep: "Sleep"
        case .steps: "Steps"
        case .temperature: "Temperature"
        }
    }

    var unit: String {
        switch self {
        case .hydration, .coffee: "ml"
        case .meals: "Meals"
        case .mood: "Mood"
        case .sleep: "Hours"
        case .steps: "Steps"
        case .temperature: "°F"
        }
    }
}

enum TrendKind {
    case bars
    case stacked
}

struct TrendPoint: Identifiable {
    let day: Date
    let value: Double
    let strength: String

    var id: String {
        "\(day.timeIntervalSinceReferenceDate)-\(strength)-\(value)"
    }
}

struct TrendSeries {
    let metric: TrendMetric
    let dayCount: Int
    let empty: Bool
    let emptyMessage: String
    let domainStart: Date
    let domainEnd: Date
    let points: [TrendPoint]
    let kind: TrendKind
    let yDomain: ClosedRange<Double>?
}

enum ComparisonKind: String, CaseIterable, Identifiable {
    case meals
    case rain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meals: "Meals and mood"
        case .rain: "Rain and mood"
        }
    }
}

enum JournalMath {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "for", "to", "in", "on", "at",
        "with", "from", "by", "my", "your", "our", "i", "me", "it", "is", "was",
        "were", "be", "been", "this", "that", "these", "those", "some", "any",
        "had", "have", "just", "very", "really", "after", "before", "into", "over",
        "under", "about", "as", "so", "if", "than", "then", "too", "not", "no", "yes",
    ]

    static func fahrenheit(celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    static func formatFahrenheit(_ celsius: Double) -> String {
        let value = fahrenheit(celsius: celsius)
        let text = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        return "\(text)°F"
    }

    static func sortedNewest(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries.sorted { left, right in
            if left.occurredAt != right.occurredAt {
                return left.occurredAt > right.occurredAt
            }
            if left.savedAt != right.savedAt {
                return left.savedAt > right.savedAt
            }
            return left.id.uuidString > right.id.uuidString
        }
    }

    static func search(_ entries: [JournalEntry], query: String) -> [JournalEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = sortedNewest(entries)
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { blob($0).contains(needle) }
    }

    static func summary(_ entry: JournalEntry) -> String {
        switch entry.entryType {
        case .location:
            let lat = entry.latitude.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
            let lon = entry.longitude.map { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
            var line = "\(lat), \(lon)"
            if let altitude = entry.altitude {
                line += " · \(formatNumber(altitude)) m elevation"
            }
            if let celsius = entry.temperatureCelsius {
                line += " · \(formatFahrenheit(celsius))"
                if let condition = entry.condition, !condition.isEmpty {
                    line += " \(condition)"
                }
            }
            return line
        case .meal:
            return entry.descriptionText ?? ""
        case .hydration:
            var parts = [entry.drinkName ?? "Drink"]
            if let amount = entry.amountMl {
                parts.append("\(formatNumber(amount)) ml")
            }
            if let strength = entry.strength, !strength.isEmpty {
                parts.append(strength)
            }
            return parts.joined(separator: " · ")
        case .bathroom:
            var line = entry.kind ?? ""
            if let scale = entry.bristolScale {
                line += " · Bristol \(scale)"
            }
            if let note = entry.note, !note.isEmpty {
                line += line.isEmpty ? note : " · \(note)"
            }
            return line
        case .lifeEvent:
            return entry.title ?? ""
        case .mood:
            var line = entry.moodScore.map(String.init) ?? ""
            if let note = entry.note, !note.isEmpty {
                line += line.isEmpty ? note : " · \(note)"
            }
            return line
        case .sleep:
            if let hours = entry.sleepHours {
                return "\(formatNumber(hours)) hours"
            }
            return ""
        case .steps:
            if let count = entry.stepCount {
                return "\(count) steps"
            }
            return ""
        }
    }

    static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func series(
        _ entries: [JournalEntry],
        metric: TrendMetric,
        dayCount: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TrendSeries {
        let count = dayCount == 30 ? 30 : 7
        let days = dayStarts(count: count, now: now, calendar: calendar)
        let start = days.first ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: days.last ?? start) ?? start
        let emptyMessage = "No \(emptyNoun(metric)) in the last \(count) days."

        switch metric {
        case .hydration:
            let rows = entries.filter { $0.entryType == .hydration }
            return counted(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                hasAny: rows.contains { daySet(days, calendar: calendar).contains(calendar.startOfDay(for: $0.occurredAt)) },
                value: { day in
                    rows.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
                        .compactMap(\.amountMl)
                        .reduce(0, +)
                },
                includeEmptyDays: true
            )
        case .meals:
            let rows = entries.filter { $0.entryType == .meal }
            return counted(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                hasAny: rows.contains { daySet(days, calendar: calendar).contains(calendar.startOfDay(for: $0.occurredAt)) },
                value: { day in
                    Double(rows.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }.count)
                },
                includeEmptyDays: true
            )
        case .coffee:
            let rows = entries.filter { isCoffee($0) && daySet(days, calendar: calendar).contains(calendar.startOfDay(for: $0.occurredAt)) }
            var points: [TrendPoint] = []
            for day in days {
                let todays = rows.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
                var totals: [String: Double] = [:]
                for row in todays {
                    let label = strengthLabel(row.strength)
                    totals[label, default: 0] += row.amountMl ?? 0
                }
                for (label, ml) in totals where ml > 0 {
                    points.append(TrendPoint(day: day, value: ml, strength: label))
                }
            }
            return TrendSeries(
                metric: metric,
                dayCount: count,
                empty: points.isEmpty,
                emptyMessage: emptyMessage,
                domainStart: start,
                domainEnd: end,
                points: points.sorted { $0.strength < $1.strength },
                kind: .stacked,
                yDomain: nil
            )
        case .mood:
            return sparse(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                yDomain: 1...5
            ) { day in
                let scores = entries.filter {
                    $0.entryType == .mood && calendar.isDate($0.occurredAt, inSameDayAs: day)
                }.compactMap(\.moodScore)
                guard !scores.isEmpty else { return nil }
                let total = scores.reduce(0, +)
                return Double(total) / Double(scores.count)
            }
        case .sleep:
            return sparse(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                yDomain: nil
            ) { day in
                let hours = entries.filter {
                    $0.entryType == .sleep && calendar.isDate($0.occurredAt, inSameDayAs: day)
                }.compactMap(\.sleepHours)
                guard !hours.isEmpty else { return nil }
                return hours.reduce(0, +)
            }
        case .steps:
            return sparse(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                yDomain: nil
            ) { day in
                let rows = entries.filter {
                    $0.entryType == .steps
                        && $0.source == "apple-health"
                        && calendar.isDate($0.occurredAt, inSameDayAs: day)
                }
                guard let latest = rows.max(by: { $0.savedAt < $1.savedAt }),
                      let count = latest.stepCount else { return nil }
                return Double(count)
            }
        case .temperature:
            return sparse(
                metric: metric,
                dayCount: count,
                days: days,
                domainStart: start,
                domainEnd: end,
                emptyMessage: emptyMessage,
                yDomain: nil
            ) { day in
                let readings = entries.filter {
                    $0.entryType == .location
                        && calendar.isDate($0.occurredAt, inSameDayAs: day)
                        && $0.temperatureCelsius != nil
                }.compactMap(\.temperatureCelsius)
                guard !readings.isEmpty else { return nil }
                let average = readings.reduce(0, +) / Double(readings.count)
                return fahrenheit(celsius: average)
            }
        }
    }

    static func sentence(_ entries: [JournalEntry], comparison: ComparisonKind) -> String {
        switch comparison {
        case .meals: mealMoodSentence(entries)
        case .rain: rainyMoodSentence(entries)
        }
    }

    static let comparisonNote = "Counted from the journal. This is not a cause, and it is not medical advice."

    private static func mealMoodSentence(_ entries: [JournalEntry]) -> String {
        let meals = entries.filter { $0.entryType == .meal }
        let moods = entries.filter {
            $0.entryType == .mood && (1...2).contains($0.moodScore ?? 0)
        }
        var counts: [String: Int] = [:]
        for mood in moods {
            let feeling = feelingLabel(mood.note)
            let windowStart = mood.occurredAt.addingTimeInterval(-4 * 60 * 60)
            var words = Set<String>()
            for meal in meals where meal.occurredAt >= windowStart && meal.occurredAt <= mood.occurredAt {
                words.formUnion(significantWords(in: meal.descriptionText ?? ""))
            }
            for word in words {
                counts["\(feeling)\t\(word)", default: 0] += 1
            }
        }
        guard let best = counts.max(by: { left, right in
            if left.value != right.value { return left.value < right.value }
            return left.key > right.key
        }) else {
            return "No low mood within 4 hours of a meal is in the journal yet."
        }
        let parts = best.key.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "No low mood within 4 hours of a meal is in the journal yet."
        }
        let times = best.value == 1 ? "1 time" : "\(best.value) times"
        return "You logged \(parts[0]) within 4 hours of meals that mentioned \(parts[1]), \(times)."
    }

    private static func rainyMoodSentence(_ entries: [JournalEntry]) -> String {
        let calendar = Calendar.current
        let rainyDays = Set(entries.compactMap { entry -> Date? in
            guard entry.entryType == .location, isRainy(entry.condition) else { return nil }
            return calendar.startOfDay(for: entry.occurredAt)
        })
        let moods = entries.filter { entry in
            guard entry.entryType == .mood, let score = entry.moodScore, (1...5).contains(score) else {
                return false
            }
            return rainyDays.contains(calendar.startOfDay(for: entry.occurredAt))
        }
        guard !moods.isEmpty else {
            return "No rainy day in this journal has a mood entry yet."
        }
        let total = moods.compactMap(\.moodScore).reduce(0, +)
        let average = Double(total) / Double(moods.count)
        let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), average)
        return "On rainy days your logged mood averaged \(text)."
    }

    private static func isRainy(_ condition: String?) -> Bool {
        guard let condition else { return false }
        let value = condition.lowercased()
        return value.contains("rain") || value.contains("drizzle") || value.contains("thunder")
    }

    private static func feelingLabel(_ note: String?) -> String {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.count > 80 { return "a low mood" }
        return trimmed
    }

    private static func significantWords(in text: String) -> Set<String> {
        let pieces = text.lowercased().split { !$0.isLetter }.map(String.init)
        return Set(pieces.filter { $0.count > 2 && !stopwords.contains($0) })
    }

    private static func isCoffee(_ entry: JournalEntry) -> Bool {
        entry.entryType == .hydration && entry.drinkName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "coffee"
    }

    private static func strengthLabel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "unspecified" : trimmed
    }

    private static func dayStarts(count: Int, now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: -(count - 1 - offset), to: today)
        }
    }

    private static func daySet(_ days: [Date], calendar: Calendar) -> Set<Date> {
        Set(days.map { calendar.startOfDay(for: $0) })
    }

    private static func emptyNoun(_ metric: TrendMetric) -> String {
        switch metric {
        case .hydration: "drinks"
        case .coffee: "coffee"
        case .meals: "meals"
        case .mood: "mood scores"
        case .sleep: "sleep"
        case .steps: "step totals"
        case .temperature: "temperatures"
        }
    }

    private static func counted(
        metric: TrendMetric,
        dayCount: Int,
        days: [Date],
        domainStart: Date,
        domainEnd: Date,
        emptyMessage: String,
        hasAny: Bool,
        value: (Date) -> Double,
        includeEmptyDays: Bool
    ) -> TrendSeries {
        guard hasAny else {
            return TrendSeries(
                metric: metric,
                dayCount: dayCount,
                empty: true,
                emptyMessage: emptyMessage,
                domainStart: domainStart,
                domainEnd: domainEnd,
                points: [],
                kind: .bars,
                yDomain: nil
            )
        }
        let points = days.compactMap { day -> TrendPoint? in
            let amount = value(day)
            if !includeEmptyDays && amount == 0 { return nil }
            return TrendPoint(day: day, value: amount, strength: "")
        }
        return TrendSeries(
            metric: metric,
            dayCount: dayCount,
            empty: false,
            emptyMessage: emptyMessage,
            domainStart: domainStart,
            domainEnd: domainEnd,
            points: points,
            kind: .bars,
            yDomain: nil
        )
    }

    private static func sparse(
        metric: TrendMetric,
        dayCount: Int,
        days: [Date],
        domainStart: Date,
        domainEnd: Date,
        emptyMessage: String,
        yDomain: ClosedRange<Double>?,
        value: (Date) -> Double?
    ) -> TrendSeries {
        let points = days.compactMap { day -> TrendPoint? in
            guard let amount = value(day) else { return nil }
            return TrendPoint(day: day, value: amount, strength: "")
        }
        return TrendSeries(
            metric: metric,
            dayCount: dayCount,
            empty: points.isEmpty,
            emptyMessage: emptyMessage,
            domainStart: domainStart,
            domainEnd: domainEnd,
            points: points,
            kind: .bars,
            yDomain: yDomain
        )
    }

    private static func blob(_ entry: JournalEntry) -> String {
        var parts: [String] = [
            entry.entryType.rawValue,
            entry.entryType.title,
            entry.entryType == .lifeEvent ? "life event" : "",
            entry.entryType == .hydration ? "hydration" : "",
            entry.descriptionText ?? "",
            entry.note ?? "",
            entry.title ?? "",
            entry.kind ?? "",
            entry.source ?? "",
            entry.drinkName ?? "",
            entry.strength ?? "",
            entry.condition ?? "",
            entry.servingSize ?? "",
        ]
        if let amount = entry.amountMl {
            parts.append("\(formatNumber(amount))")
            parts.append("\(formatNumber(amount)) ml")
        }
        if let score = entry.moodScore {
            parts.append("\(score)")
            parts.append("mood \(score)")
        }
        if let hours = entry.sleepHours {
            parts.append("\(formatNumber(hours))")
            parts.append("\(formatNumber(hours)) hours")
        }
        if let scale = entry.bristolScale {
            parts.append("\(scale)")
            parts.append("bristol \(scale)")
        }
        if let latitude = entry.latitude, let longitude = entry.longitude {
            parts.append(String(latitude))
            parts.append(String(longitude))
        }
        if let altitude = entry.altitude {
            parts.append(String(altitude))
        }
        if let accuracy = entry.accuracyMeters {
            parts.append(String(accuracy))
        }
        if let steps = entry.stepCount {
            parts.append("\(steps)")
            parts.append("\(steps) steps")
        }
        if let celsius = entry.temperatureCelsius {
            parts.append(String(celsius))
            parts.append(formatFahrenheit(celsius))
        }
        for value in [entry.calories, entry.totalFat, entry.saturatedFat, entry.cholesterol, entry.sodium, entry.carbohydrates, entry.fiber, entry.sugar, entry.protein] {
            if let value {
                parts.append(formatNumber(value))
            }
        }
        return parts
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
