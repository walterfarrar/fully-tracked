import Foundation

struct DaySummary: Sendable {
    var day: Date
    var meals: Int
    var foods: [String]
    var waterMl: Double
    var caffeineDrinks: Int
    var moodAvg: Double?
    var moodMin: Int?
    var emotions: [String]
    var sleepHours: Double?
    var steps: Int?
    var bathroom: (stool: Int, urine: Int, bristolAvg: Double?)
    var doses: [String]
    var lifeEvents: [String]
    var checkIns: Int
    var distinctPlaces: [String]
    var avgTempF: Double?
    var conditions: [String]
}

struct MoodSplit: Sendable {
    var withAverage: Double?
    var withDays: Int
    var withoutAverage: Double?
    var withoutDays: Int
}

enum MoodFactor: String, Sendable {
    case coffee
    case shortSleep
    case rain
}

enum JournalRollups {
    static func summaries(
        _ entries: [JournalEntry],
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DaySummary] {
        let bounds = span(days: days, now: now, calendar: calendar)
        return (0..<bounds.count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: bounds.start) else { return nil }
            let rows = entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
            return summarize(day: day, rows: rows)
        }
    }

    static func toCompactText(_ summaries: [DaySummary]) -> String {
        summaries.compactMap(compactLine).joined(separator: "\n")
    }

    static func entries(
        on day: Date,
        in entries: [JournalEntry],
        calendar: Calendar = .current
    ) -> [JournalEntry] {
        entries.filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
    }

    static func entries(
        _ entries: [JournalEntry],
        type: EntryType,
        in range: ClosedRange<Date>
    ) -> [JournalEntry] {
        entries.filter { entry in
            entry.entryType == type && range.contains(entry.occurredAt)
        }
    }

    static func moodVersusFactor(
        _ entries: [JournalEntry],
        factor: MoodFactor,
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MoodSplit {
        let rows = summaries(entries, days: days, now: now, calendar: calendar)
        return split(rows, factor: factor)
    }

    static func split(_ summaries: [DaySummary], factor: MoodFactor) -> MoodSplit {
        switch factor {
        case .coffee:
            return split(summaries, include: { $0.moodAvg != nil }, matches: { $0.caffeineDrinks > 0 })
        case .shortSleep:
            return split(
                summaries,
                include: { $0.moodAvg != nil && $0.sleepHours != nil },
                matches: { ($0.sleepHours ?? 0) < 6 }
            )
        case .rain:
            return split(
                summaries,
                include: { $0.moodAvg != nil && !$0.conditions.isEmpty },
                matches: { $0.conditions.contains(where: isRainy) }
            )
        }
    }

    static func split(
        _ summaries: [DaySummary],
        include: (DaySummary) -> Bool,
        matches: (DaySummary) -> Bool
    ) -> MoodSplit {
        var withValues: [Double] = []
        var withoutValues: [Double] = []
        for day in summaries where include(day) {
            guard let mood = day.moodAvg else { continue }
            if matches(day) {
                withValues.append(mood)
            } else {
                withoutValues.append(mood)
            }
        }
        return MoodSplit(
            withAverage: average(withValues),
            withDays: withValues.count,
            withoutAverage: average(withoutValues),
            withoutDays: withoutValues.count
        )
    }

    static func factorLine(_ split: MoodSplit, factor: MoodFactor) -> String {
        let withName: String
        let withoutName: String
        switch factor {
        case .coffee:
            withName = "with coffee or tea"
            withoutName = "without coffee or tea"
        case .shortSleep:
            withName = "with sleep under 6 hours"
            withoutName = "with 6 or more hours of sleep"
        case .rain:
            withName = "on rainy days"
            withoutName = "on days that were not rainy"
        }
        var parts = [
            side(split.withAverage, days: split.withDays, name: withName),
            side(split.withoutAverage, days: split.withoutDays, name: withoutName),
        ]
        if split.withDays >= 3, split.withoutDays >= 3,
           let withAverage = split.withAverage, let withoutAverage = split.withoutAverage {
            let delta = withAverage - withoutAverage
            if abs(delta) < 0.05 {
                parts.append("mood was about the same \(withName)")
            } else {
                let direction = delta > 0 ? "higher" : "lower"
                parts.append("mood was \(number(abs(delta))) \(direction) \(withName)")
            }
        } else {
            parts.append("need at least 3 days on each side to compare")
        }
        return parts.joined(separator: "; ")
    }

    static func spokenDay(_ summary: DaySummary, calendar: Calendar = .current) -> String {
        let when = calendar.isDateInToday(summary.day) ? "Today" : dayLabel(summary.day, calendar: calendar)
        var parts: [String] = []
        if summary.meals > 0 {
            parts.append(summary.meals == 1 ? "1 meal" : "\(summary.meals) meals")
        }
        if summary.waterMl > 0 {
            let ounces = summary.waterMl / JournalCatalog.ouncesToMilliliters
            parts.append("\(number(ounces)) ounces of water")
        }
        if summary.caffeineDrinks > 0 {
            parts.append(summary.caffeineDrinks == 1 ? "1 caffeinated drink" : "\(summary.caffeineDrinks) caffeinated drinks")
        }
        if let mood = summary.moodAvg {
            parts.append("mood \(number(mood))")
        }
        if let sleep = summary.sleepHours {
            parts.append("\(number(sleep)) hours of sleep")
        }
        if let steps = summary.steps {
            parts.append("\(steps) steps")
        }
        if !summary.doses.isEmpty {
            parts.append(summary.doses.count == 1 ? "1 dose" : "\(summary.doses.count) doses")
        }
        if summary.checkIns > 0 {
            parts.append(summary.checkIns == 1 ? "1 location check-in" : "\(summary.checkIns) location check-ins")
        }
        guard !parts.isEmpty else { return "\(when): nothing is logged yet." }
        return "\(when): \(parts.prefix(6).joined(separator: ", "))."
    }

    static func searchLines(
        _ entries: [JournalEntry],
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [String] {
        let bounds = span(days: days, now: now, calendar: calendar)
        let rows = entries
            .filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
            .sorted { $0.occurredAt > $1.occurredAt }
        return rows.prefix(80).map { entry in
            let body = searchBody(entry)
            let line = "\(dayLabel(entry.occurredAt, calendar: calendar)) \(entry.typeRaw) \(body)"
            return fieldText(line, limit: 180)
        }
    }

    static func clip(_ text: String, limit: Int = 1_500) -> String {
        guard text.count > limit, limit > 0 else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if abs(value) < Double(Int.max), abs(value - value.rounded()) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func isRainy(_ condition: String) -> Bool {
        let value = condition.lowercased()
        return value.contains("rain") || value.contains("drizzle") || value.contains("thunder")
    }

    private static func summarize(day: Date, rows: [JournalEntry]) -> DaySummary {
        var meals = 0
        var foods: [String] = []
        var waterMl = 0.0
        var caffeineDrinks = 0
        var moodScores: [Int] = []
        var emotions: [String] = []
        var sleepHours = 0.0
        var slept = false
        var stepRows: [JournalEntry] = []
        var stool = 0
        var urine = 0
        var bristolTotal = 0
        var bristolCount = 0
        var doses: [String] = []
        var lifeEvents: [String] = []
        var checkIns = 0
        var places: [String] = []
        var temps: [Double] = []
        var conditions: [String] = []

        for entry in rows {
            switch entry.entryType {
            case .meal:
                meals += 1
                for name in foodNames(entry) {
                    appendUnique(name, to: &foods, limit: 12)
                }
            case .hydration:
                if isWater(entry.drinkName) {
                    waterMl += milliliters(entry)
                } else if isCaffeine(entry.drinkName) {
                    caffeineDrinks += 1
                }
            case .bathroom:
                if isStool(entry) { stool += 1 }
                if isUrine(entry) { urine += 1 }
                if let scale = entry.bristolScale, (1...7).contains(scale) {
                    bristolTotal += scale
                    bristolCount += 1
                }
            case .lifeEvent:
                if let title = eventTitle(entry) {
                    appendUnique(title, to: &lifeEvents, limit: 6)
                }
            case .mood:
                if let score = entry.moodScore, (1...10).contains(score) {
                    moodScores.append(score)
                }
                for name in entry.emotions ?? [] {
                    appendUnique(name, to: &emotions, limit: 8)
                }
            case .sleep:
                if let hours = entry.sleepHours, hours.isFinite, hours > 0 {
                    sleepHours += hours
                    slept = true
                }
            case .steps:
                stepRows.append(entry)
            case .dose:
                let line = doseLine(entry)
                if !line.isEmpty {
                    appendUnique(line, to: &doses, limit: 6)
                }
            case .location:
                checkIns += 1
                if let latitude = entry.latitude, let longitude = entry.longitude,
                   latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 {
                    let label = String(
                        format: "%.3f,%.3f",
                        locale: Locale(identifier: "en_US_POSIX"),
                        latitude,
                        longitude
                    )
                    appendUnique(label, to: &places, limit: 8)
                }
                if let celsius = entry.temperatureCelsius, celsius.isFinite {
                    temps.append(celsius)
                }
                if let condition = cleaned(entry.condition) {
                    appendUnique(condition, to: &conditions, limit: 4)
                }
            default:
                break
            }
        }

        let bristolAvg = bristolCount > 0 ? Double(bristolTotal) / Double(bristolCount) : nil
        return DaySummary(
            day: day,
            meals: meals,
            foods: foods,
            waterMl: waterMl,
            caffeineDrinks: caffeineDrinks,
            moodAvg: average(moodScores.map(Double.init)),
            moodMin: moodScores.min(),
            emotions: emotions,
            sleepHours: slept ? sleepHours : nil,
            steps: stepCount(stepRows),
            bathroom: (stool: stool, urine: urine, bristolAvg: bristolAvg),
            doses: doses,
            lifeEvents: lifeEvents,
            checkIns: checkIns,
            distinctPlaces: places,
            avgTempF: temps.isEmpty ? nil : JournalMath.fahrenheit(celsius: average(temps) ?? 0),
            conditions: conditions
        )
    }

    private static func compactLine(_ summary: DaySummary) -> String? {
        var fields: [String] = []
        if summary.meals > 0 { fields.append("meals=\(summary.meals)") }
        if !summary.foods.isEmpty {
            let foods = summary.foods.prefix(8).map { fieldText($0, limit: 32) }.joined(separator: "|")
            fields.append("foods=\(foods)")
        }
        if summary.waterMl > 0 { fields.append("water=\(number(summary.waterMl))ml") }
        if summary.caffeineDrinks > 0 { fields.append("caf=\(summary.caffeineDrinks)") }
        if let mood = summary.moodAvg { fields.append("mood=\(number(mood))") }
        if let minimum = summary.moodMin { fields.append("min=\(minimum)") }
        if !summary.emotions.isEmpty {
            let names = summary.emotions.prefix(6).map { fieldText($0, limit: 24) }.joined(separator: "|")
            fields.append("emo=\(names)")
        }
        if let sleep = summary.sleepHours { fields.append("sleep=\(number(sleep))h") }
        if let steps = summary.steps { fields.append("steps=\(steps)") }
        let bath = summary.bathroom
        if bath.stool > 0 || bath.urine > 0 || bath.bristolAvg != nil {
            var text = "bath=s\(bath.stool)/u\(bath.urine)"
            if let bristol = bath.bristolAvg { text += "/b\(number(bristol))" }
            fields.append(text)
        }
        if !summary.doses.isEmpty {
            let doses = summary.doses.prefix(4).map { fieldText($0, limit: 40) }.joined(separator: "|")
            fields.append("doses=\(doses)")
        }
        if !summary.lifeEvents.isEmpty {
            let events = summary.lifeEvents.prefix(3).map { fieldText($0, limit: 40) }.joined(separator: "|")
            fields.append("events=\(events)")
        }
        if summary.checkIns > 0 { fields.append("in=\(summary.checkIns)") }
        if !summary.distinctPlaces.isEmpty {
            fields.append("places=\(summary.distinctPlaces.prefix(6).joined(separator: "|"))")
        }
        if let temp = summary.avgTempF { fields.append("temp=\(number(temp))F") }
        if !summary.conditions.isEmpty {
            let sky = summary.conditions.prefix(3).map { fieldText($0, limit: 24) }.joined(separator: "|")
            fields.append("sky=\(sky)")
        }
        guard !fields.isEmpty else { return nil }
        return dayLabel(summary.day) + " " + fields.joined(separator: " ")
    }

    private static func span(days: Int, now: Date, calendar: Calendar) -> (start: Date, end: Date, count: Int) {
        let count = min(366, max(1, days))
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return (start, end, count)
    }

    private static func searchBody(_ entry: JournalEntry) -> String {
        switch entry.entryType {
        case .location, .meal, .hydration, .bathroom, .lifeEvent, .mood, .sleep, .steps, .dose:
            return JournalMath.summary(entry)
        default:
            return [entry.title, entry.descriptionText, entry.note, entry.kind]
                .compactMap { cleaned($0) }
                .joined(separator: " ")
        }
    }

    private static func foodNames(_ entry: JournalEntry) -> [String] {
        var names: [String] = []
        if let foodsJSON = entry.foodsJSON,
           let data = foodsJSON.data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            for row in rows {
                if let name = row as? String {
                    names.append(name)
                } else if let object = row as? [String: Any], let name = object["name"] as? String {
                    names.append(name)
                }
            }
        }
        if names.isEmpty, let text = entry.descriptionText {
            for piece in text.split(separator: ",") {
                let name = piece.split(separator: "·", maxSplits: 1).first.map(String.init) ?? String(piece)
                names.append(name)
            }
        }
        return names
    }

    private static func doseLine(_ entry: JournalEntry) -> String {
        var parts: [String] = []
        if let name = cleaned(entry.substanceName) { parts.append(name) }
        if let amount = entry.doseAmount, amount.isFinite {
            var dose = number(amount)
            if let unit = cleaned(entry.doseUnit) { dose += " " + unit }
            parts.append(dose)
        }
        return parts.joined(separator: " ")
    }

    private static func eventTitle(_ entry: JournalEntry) -> String? {
        if let title = cleaned(entry.title) { return title }
        return cleaned(entry.descriptionText)
    }

    private static func stepCount(_ rows: [JournalEntry]) -> Int? {
        let health = rows.filter { $0.source == "apple-health" && $0.stepCount != nil }
        let pool = health.isEmpty ? rows : health
        return pool.max(by: { $0.savedAt < $1.savedAt })?.stepCount
    }

    private static func isWater(_ name: String?) -> Bool {
        cleaned(name)?.lowercased() == "water"
    }

    private static func isCaffeine(_ name: String?) -> Bool {
        guard let value = cleaned(name)?.lowercased() else { return false }
        let needles = [
            "coffee", "espresso", "latte", "cappuccino", "mocha", "americano",
            "tea", "matcha", "chai", "cola", "caffeine", "energy",
        ]
        return needles.contains { value.contains($0) }
    }

    private static func isStool(_ entry: JournalEntry) -> Bool {
        if entry.stool == true { return true }
        let kind = entry.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return kind == "stool" || kind == "both"
    }

    private static func isUrine(_ entry: JournalEntry) -> Bool {
        if entry.urine == true { return true }
        let kind = entry.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return kind == "urine" || kind == "both"
    }

    private static func milliliters(_ entry: JournalEntry) -> Double {
        if let amount = entry.amountMl, amount.isFinite, amount > 0 { return amount }
        if let ounces = entry.amountOz, ounces.isFinite, ounces > 0 {
            return ounces * JournalCatalog.ouncesToMilliliters
        }
        return 0
    }

    private static func appendUnique(_ raw: String, to list: inout [String], limit: Int) {
        guard list.count < limit, let name = cleaned(raw) else { return }
        guard !list.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        list.append(name)
    }

    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func side(_ average: Double?, days: Int, name: String) -> String {
        guard days > 0, let average else { return "\(name): no mood days" }
        let word = days == 1 ? "day" : "days"
        return "\(name): mood \(number(average)) over \(days) \(word)"
    }

    private static func fieldText(_ text: String, limit: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit, limit > 0 else { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: limit)
        return String(cleaned[..<end])
    }
}
