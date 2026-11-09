import Foundation
import NaturalLanguage

enum InsightEngine {
    static func insight(
        entries: [JournalEntry],
        days: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let lines = insightLines(entries: entries, days: days, now: now, calendar: calendar)
        return lines.prefix(6).joined(separator: " ")
    }

    static func answer(
        question: String,
        entries: [JournalEntry],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let routed = route(asked, entries: entries, now: now, calendar: calendar)
        var lines = routed.sentences
        let spoken = lines.joined(separator: " ")
        if spoken.filter({ $0 == "." }).count < 6, let tone = sentimentSentence(in: routed.pool) {
            lines.append(tone)
        }
        if lines.isEmpty {
            return "Nothing in the journal matches that yet."
        }
        return lines.joined(separator: " ")
    }

    private static func insightLines(
        entries: [JournalEntry],
        days: Int,
        now: Date,
        calendar: Calendar
    ) -> [String] {
        let window = min(366, max(1, days))
        let rows = JournalRollups.summaries(entries, days: window, now: now, calendar: calendar)
        let span = bounds(days: window, now: now, calendar: calendar)
        let loggedCount = entries.filter { $0.occurredAt >= span.start && $0.occurredAt < span.end }.count
        let word = window == 1 ? "day" : "days"
        guard loggedCount > 0 else {
            return ["Nothing is logged in the last \(window) \(word)."]
        }

        var lines: [String] = []
        var compared = false
        let moodDays = rows.compactMap(\.moodAvg)
        if !moodDays.isEmpty {
            let average = moodDays.reduce(0, +) / Double(moodDays.count)
            lines.append("Mood averaged \(JournalRollups.number(average)) on \(moodDays.count) of the last \(window) \(word).")
        }

        let longSleep = JournalRollups.split(
            rows,
            include: { $0.moodAvg != nil && $0.sleepHours != nil },
            matches: { ($0.sleepHours ?? 0) >= 7 }
        )
        if let sentence = comparison(longSleep, phrase: "on days with 7 or more hours of sleep") {
            lines.append(sentence)
            compared = true
        }

        let coffee = JournalRollups.split(rows, factor: .coffee)
        if let sentence = comparison(coffee, phrase: "on days with coffee or tea") {
            lines.append(sentence)
            compared = true
        }

        let rain = JournalRollups.split(rows, factor: .rain)
        if let sentence = comparison(rain, phrase: "on rainy days") {
            lines.append(sentence)
            compared = true
        }

        let sleepDays = rows.compactMap(\.sleepHours)
        if !sleepDays.isEmpty, lines.count < 6 {
            let average = sleepDays.reduce(0, +) / Double(sleepDays.count)
            lines.append("Sleep averaged \(JournalRollups.number(average)) hours on \(sleepDays.count) \(sleepDays.count == 1 ? "day" : "days").")
        }

        let waterDays = rows.filter { $0.waterMl > 0 }
        if !waterDays.isEmpty, lines.count < 6 {
            let total = waterDays.reduce(0) { $0 + $1.waterMl }
            let average = total / Double(waterDays.count)
            lines.append("Water averaged \(JournalRollups.number(average)) ml on \(waterDays.count) \(waterDays.count == 1 ? "day" : "days").")
        }

        let mealCount = rows.reduce(0) { $0 + $1.meals }
        if mealCount > 0, lines.count < 6 {
            lines.append(mealCount == 1 ? "You logged 1 meal in this stretch." : "You logged \(mealCount) meals in this stretch.")
        }

        let stepDays = rows.compactMap(\.steps)
        if !stepDays.isEmpty, lines.count < 6 {
            let total = stepDays.reduce(0, +)
            let average = Double(total) / Double(stepDays.count)
            lines.append("Steps averaged \(JournalRollups.number(average)) on \(stepDays.count) \(stepDays.count == 1 ? "day" : "days").")
        }

        if lines.count < 3 {
            let checkIns = rows.reduce(0) { $0 + $1.checkIns }
            if checkIns > 0 {
                lines.append(checkIns == 1 ? "There is 1 location check-in in this stretch." : "There are \(checkIns) location check-ins in this stretch.")
            }
        }
        if lines.count < 3 {
            let doses = rows.reduce(0) { $0 + $1.doses.count }
            if doses > 0 {
                lines.append(doses == 1 ? "You logged 1 dose in this stretch." : "You logged \(doses) doses in this stretch.")
            }
        }
        if lines.count < 3 {
            let stool = rows.reduce(0) { $0 + $1.bathroom.stool }
            let urine = rows.reduce(0) { $0 + $1.bathroom.urine }
            if stool > 0 || urine > 0 {
                lines.append("Bathroom logs: \(stool) with stool and \(urine) with urine.")
            }
        }
        if compared, lines.count < 6 {
            lines.append(JournalMath.comparisonNote)
        }
        if lines.isEmpty {
            let noun = loggedCount == 1 ? "entry" : "entries"
            return ["The journal has \(loggedCount) \(noun) in the last \(window) \(word), without mood, sleep, or meal totals to compare yet."]
        }
        return lines
    }

    private static func route(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        if asksWhere(asked) {
            return places(asked, entries: entries, now: now, calendar: calendar)
        }
        if asksFood(asked) {
            return foods(asked, entries: entries, now: now, calendar: calendar)
        }
        if asked.contains("coffee") || asked.contains("caffeine") || asked.contains("tea") {
            return factorAnswer(.coffee, asked: asked, entries: entries, now: now, calendar: calendar)
        }
        if asked.contains("sleep") {
            return sleepAnswer(asked, entries: entries, now: now, calendar: calendar)
        }
        if asked.contains("mood") || asked.contains("feel") {
            return moodAnswer(asked, entries: entries, now: now, calendar: calendar)
        }
        if asked.contains("water") || asked.contains("hydrat") {
            return waterAnswer(asked, entries: entries, now: now, calendar: calendar)
        }
        if asked.contains("dose") || asked.contains("medicat") || asked.contains("medicine") {
            return doseAnswer(asked, entries: entries, now: now, calendar: calendar)
        }
        let window = spanLength(asked)
        let text = insight(entries: entries, days: window, now: now, calendar: calendar)
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        return (text.split(separator: " ").isEmpty ? [] : [text], pool)
    }

    private static func places(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let yesterday = asked.contains("yesterday")
        let day = yesterday
            ? (calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now)
            : calendar.startOfDay(for: now)
        let rows = JournalRollups.entries(on: day, in: entries, calendar: calendar)
        let label = yesterday ? "Yesterday" : "Today"
        let places = placeLabels(rows)
        if places.isEmpty {
            if !yesterday {
                let recent = JournalRollups.summaries(entries, days: 7, now: now, calendar: calendar)
                    .filter { !$0.distinctPlaces.isEmpty }
                if let latest = recent.last {
                    let names = latest.distinctPlaces.joined(separator: "; ")
                    return ([
                        "Today has no location check-in. The latest in the last 7 days is \(JournalRollups.dayLabel(latest.day, calendar: calendar)): \(names).",
                    ], rows)
                }
            }
            return (["\(label) has no location check-in saved on this phone."], rows)
        }
        var sentences = ["\(label), the journal has \(places.count) \(places.count == 1 ? "place" : "places"): \(places.joined(separator: "; "))."]
        let conditions = unique(rows.compactMap { cleaned($0.condition) })
        let temps = rows.compactMap(\.temperatureCelsius).filter(\.isFinite)
        if !temps.isEmpty {
            let average = temps.reduce(0, +) / Double(temps.count)
            var weather = "The saved weather averaged \(JournalMath.formatFahrenheit(average))"
            if !conditions.isEmpty {
                weather += ", \(conditions.joined(separator: ", "))"
            }
            weather += "."
            sentences.append(weather)
        }
        return (sentences, rows)
    }

    private static func foods(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = asked.contains("week") ? 7 : 30
        let rows = JournalRollups.summaries(entries, days: window, now: now, calendar: calendar)
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        let bad = asked.contains("bad") || asked.contains("low") || asked.contains("worse") || asked.contains("awful")
        if bad {
            let days = rows.filter { ($0.moodMin ?? 11) <= 4 }
            if days.isEmpty {
                return (["No day in the last \(window) days has a mood of 4 or below."], pool)
            }
            let names = unique(days.flatMap(\.foods))
            if names.isEmpty {
                let sentence = days.count == 1
                    ? "1 day has a mood of 4 or below, and that day has no meal logged."
                    : "\(days.count) days have a mood of 4 or below, and none of them has a meal logged."
                return ([sentence], pool)
            }
            let shown = Array(names.prefix(8))
            return ([
                "On \(days.count) \(days.count == 1 ? "day" : "days") with mood at 4 or below, meals included \(list(shown)).",
            ], pool)
        }
        let names = unique(rows.flatMap(\.foods))
        if names.isEmpty {
            return (["No meals are logged in the last \(window) days."], pool)
        }
        let mealCount = rows.reduce(0) { $0 + $1.meals }
        return ([
            "You logged \(mealCount) \(mealCount == 1 ? "meal" : "meals") in the last \(window) days, including \(list(Array(names.prefix(8)))).",
        ], pool)
    }

    private static func factorAnswer(
        _ factor: MoodFactor,
        asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = asked.contains("week") ? 7 : 30
        let split = JournalRollups.moodVersusFactor(entries, factor: factor, days: window, now: now, calendar: calendar)
        let phrase: String
        switch factor {
        case .coffee: phrase = "on days with coffee or tea"
        case .shortSleep: phrase = "on days with under 6 hours of sleep"
        case .rain: phrase = "on rainy days"
        }
        var lines: [String] = []
        if let sentence = comparison(split, phrase: phrase) {
            lines.append(sentence)
            lines.append(JournalMath.comparisonNote)
        } else {
            lines.append(proseSplit(split, phrase: phrase, window: window))
        }
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        return (lines, pool)
    }

    private static func sleepAnswer(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = spanLength(asked)
        let rows = JournalRollups.summaries(entries, days: window, now: now, calendar: calendar)
        let hours = rows.compactMap(\.sleepHours)
        var lines: [String] = []
        if hours.isEmpty {
            lines.append("No sleep is logged in the last \(window) days.")
        } else {
            let average = hours.reduce(0, +) / Double(hours.count)
            lines.append("Sleep averaged \(JournalRollups.number(average)) hours on \(hours.count) of the last \(window) days.")
        }
        if asked.contains("under") || asked.contains("less") || asked.contains("<") || asked.contains("short") {
            let split = JournalRollups.split(rows, factor: .shortSleep)
            if let sentence = comparison(split, phrase: "on days with under 6 hours of sleep") {
                lines.append(sentence)
            } else {
                lines.append(proseSplit(split, phrase: "with under 6 hours of sleep", window: window))
            }
        } else if let sentence = comparison(
            JournalRollups.split(
                rows,
                include: { $0.moodAvg != nil && $0.sleepHours != nil },
                matches: { ($0.sleepHours ?? 0) >= 7 }
            ),
            phrase: "on days with 7 or more hours of sleep"
        ) {
            lines.append(sentence)
        }
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        return (lines, pool)
    }

    private static func moodAnswer(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = spanLength(asked)
        let text = insight(entries: entries, days: window, now: now, calendar: calendar)
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end && $0.entryType == .mood }
        return ([text], pool)
    }

    private static func waterAnswer(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = spanLength(asked)
        let rows = JournalRollups.summaries(entries, days: window, now: now, calendar: calendar)
        let waterDays = rows.filter { $0.waterMl > 0 }
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        guard !waterDays.isEmpty else {
            return (["No water is logged in the last \(window) days."], pool)
        }
        let total = waterDays.reduce(0) { $0 + $1.waterMl }
        let average = total / Double(waterDays.count)
        let ounces = total / JournalCatalog.ouncesToMilliliters
        return ([
            "Water totaled \(JournalRollups.number(ounces)) ounces (\(JournalRollups.number(total)) ml) over \(waterDays.count) of the last \(window) days, about \(JournalRollups.number(average)) ml a day.",
        ], pool)
    }

    private static func doseAnswer(
        _ asked: String,
        entries: [JournalEntry],
        now: Date,
        calendar: Calendar
    ) -> (sentences: [String], pool: [JournalEntry]) {
        let window = spanLength(asked)
        let rows = JournalRollups.summaries(entries, days: window, now: now, calendar: calendar)
        let names = unique(rows.flatMap(\.doses))
        let bounds = bounds(days: window, now: now, calendar: calendar)
        let pool = entries.filter { $0.occurredAt >= bounds.start && $0.occurredAt < bounds.end }
        guard !names.isEmpty else {
            return (["No doses are logged in the last \(window) days."], pool)
        }
        return (["Doses in the last \(window) days: \(list(Array(names.prefix(6))))."], pool)
    }

    private static func comparison(_ split: MoodSplit, phrase: String) -> String? {
        guard split.withDays >= 3, split.withoutDays >= 3,
              let withAverage = split.withAverage, let withoutAverage = split.withoutAverage else { return nil }
        let delta = withAverage - withoutAverage
        if abs(delta) < 0.05 {
            return "Mood was about the same \(phrase) (\(split.withDays) days vs \(split.withoutDays))."
        }
        let direction = delta > 0 ? "higher" : "lower"
        return "Mood was \(JournalRollups.number(abs(delta))) \(direction) \(phrase) (\(split.withDays) days vs \(split.withoutDays))."
    }

    private static func proseSplit(_ split: MoodSplit, phrase: String, window: Int) -> String {
        let withText = groupText(split.withAverage, days: split.withDays)
        let withoutText = groupText(split.withoutAverage, days: split.withoutDays)
        return "Over the last \(window) days, mood \(phrase) was \(withText), and the other side was \(withoutText). A comparison needs at least 3 days on each side."
    }

    private static func groupText(_ average: Double?, days: Int) -> String {
        guard days > 0, let average else { return "missing" }
        let word = days == 1 ? "day" : "days"
        return "\(JournalRollups.number(average)) across \(days) \(word)"
    }

    private static func sentimentSentence(in entries: [JournalEntry]) -> String? {
        let notes = entries.compactMap { cleaned($0.note) }
        let scores = notes.compactMap(sentimentScore)
        guard scores.count >= 2 else { return nil }
        let average = scores.reduce(0, +) / Double(scores.count)
        let tone: String
        if average >= 0.2 {
            tone = "positive"
        } else if average <= -0.2 {
            tone = "negative"
        } else {
            tone = "neutral"
        }
        return "Notes leaned \(tone) across \(scores.count) notes."
    }

    private static func sentimentScore(_ text: String) -> Double? {
        guard text.count >= 3 else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let raw = tag?.rawValue else { return nil }
        return Double(raw)
    }

    private static func asksWhere(_ asked: String) -> Bool {
        asked.contains("where") || asked.contains("place") || asked.contains("location") || asked.contains("check-in") || asked.contains("check in")
    }

    private static func asksFood(_ asked: String) -> Bool {
        asked.contains("eat") || asked.contains("ate") || asked.contains("food") || asked.contains("meal")
    }

    private static func spanLength(_ asked: String) -> Int {
        if asked.contains("month") || asked.contains("30") { return 30 }
        if asked.contains("yesterday") { return 2 }
        return 7
    }

    private static func bounds(days: Int, now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let count = min(366, max(1, days))
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return (start, end)
    }

    private static func placeLabels(_ entries: [JournalEntry]) -> [String] {
        var labels: [String] = []
        for entry in entries where entry.entryType == .location {
            guard let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            let label = String(
                format: "%.3f, %.3f",
                locale: Locale(identifier: "en_US_POSIX"),
                latitude,
                longitude
            )
            if !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    private static func unique(_ names: [String]) -> [String] {
        var list: [String] = []
        for name in names {
            guard let trimmed = cleaned(name) else { continue }
            guard !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            list.append(trimmed)
        }
        return list
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), and \(items[items.count - 1])"
        }
    }

    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
