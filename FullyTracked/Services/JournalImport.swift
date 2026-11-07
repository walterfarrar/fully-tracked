import Foundation
import SwiftData

struct JournalImportOutcome {
    var inserted: Int
    var skipped: Int
    var rejected: Int
}

enum JournalImportError: LocalizedError {
    case unreadable
    case unexpectedFormat

    var errorDescription: String? {
        switch self {
        case .unreadable: "The journal file could not be read."
        case .unexpectedFormat: "This file is not a version 1 Fully Tracked journal."
        }
    }
}

enum JournalImporter {
    private static let ouncesToMilliliters = 29.5735295625

    static func importJournal(_ data: Data, context: ModelContext) throws -> JournalImportOutcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JournalImportError.unexpectedFormat
        }
        guard root["format"] as? String == "fully-tracked-journal",
              intValue(root["version"]) == 1,
              let entries = root["entries"] as? [Any] else {
            throw JournalImportError.unexpectedFormat
        }
        let existing = (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []
        var ids = Set(existing.map(\.id))
        var signatures = Set(existing.map(signature))
        var outcome = JournalImportOutcome(inserted: 0, skipped: 0, rejected: 0)
        for item in entries {
            guard let fields = item as? [String: Any],
                  let typeName = fields["type"] as? String,
                  let kind = entryType(typeName),
                  let occurredAt = dateValue(fields["occurredAt"]) else {
                outcome.rejected += 1
                continue
            }
            let entry = JournalEntry(type: kind, occurredAt: occurredAt)
            let rawID = fields["id"] as? String
            let parsedID = rawID.flatMap(UUID.init(uuidString:))
            if let parsedID {
                entry.id = parsedID
                if ids.contains(parsedID) {
                    outcome.skipped += 1
                    continue
                }
            }
            entry.savedAt = dateValue(fields["savedAt"]) ?? occurredAt
            apply(fields, to: entry, typeName: typeName)
            if parsedID == nil {
                let mark = signature(entry)
                if signatures.contains(mark) {
                    outcome.skipped += 1
                    continue
                }
                signatures.insert(mark)
            }
            context.insert(entry)
            ids.insert(entry.id)
            outcome.inserted += 1
        }
        if outcome.inserted > 0 {
            try context.save()
        }
        return outcome
    }

    private static func entryType(_ name: String) -> EntryType? {
        switch name {
        case "location": .location
        case "meal": .meal
        case "water", "hydration": .hydration
        case "bathroom": .bathroom
        case "life_event": .lifeEvent
        case "mood": .mood
        case "sleep": .sleep
        case "steps": .steps
        case "dose": .dose
        default: nil
        }
    }

    private static func apply(_ fields: [String: Any], to entry: JournalEntry, typeName: String) {
        entry.latitude = doubleValue(fields["latitude"])
        entry.longitude = doubleValue(fields["longitude"])
        entry.accuracyMeters = doubleValue(fields["accuracyMeters"])
        entry.altitude = doubleValue(fields["altitude"])
        entry.source = stringValue(fields["source"])
        entry.descriptionText = stringValue(fields["description"])
        entry.drinkName = stringValue(fields["drinkName"])
        entry.amountLabel = stringValue(fields["amountLabel"])
        entry.amountOz = doubleValue(fields["amountOz"])
        entry.amountMl = doubleValue(fields["amountMl"])
        if entry.amountMl == nil, let ounces = entry.amountOz {
            entry.amountMl = ounces * ouncesToMilliliters
        }
        entry.strength = stringValue(fields["strength"])
        entry.kind = stringValue(fields["kind"])
        if let scale = intValue(fields["bristolScale"]) {
            entry.bristolScale = scale
        }
        entry.note = stringValue(fields["note"])
        entry.title = stringValue(fields["title"])
        if let score = intValue(fields["moodScore"]) {
            entry.moodScore = score
        }
        entry.sleepHours = doubleValue(fields["sleepHours"])
        if let steps = intValue(fields["stepCount"]) {
            entry.stepCount = steps
        }
        entry.amountHad = stringValue(fields["amountHad"])
        entry.stoolColor = stringValue(fields["stoolColor"])
        entry.stoolAmount = stringValue(fields["stoolAmount"])
        entry.urineColor = stringValue(fields["urineColor"])
        entry.urineClarity = stringValue(fields["urineClarity"])
        entry.urineAmount = stringValue(fields["urineAmount"])
        if fields["stool"] != nil {
            entry.stool = boolValue(fields["stool"])
        }
        if fields["urine"] != nil {
            entry.urine = boolValue(fields["urine"])
        }
        if let emotions = fields["emotions"] as? [Any] {
            entry.emotions = emotions.compactMap { stringValue($0) }
        }
        entry.substanceName = stringValue(fields["substanceName"])
        entry.doseAmount = doubleValue(fields["amount"])
        if typeName != "dose" {
            entry.doseAmount = nil
        }
        entry.doseUnit = stringValue(fields["unit"])
        if typeName != "dose" {
            entry.doseUnit = nil
        }
        entry.servingSize = stringValue(fields["servingSize"])
        entry.calories = doubleValue(fields["calories"])
        entry.totalFat = doubleValue(fields["totalFat"])
        entry.saturatedFat = doubleValue(fields["saturatedFat"])
        entry.cholesterol = doubleValue(fields["cholesterol"])
        entry.sodium = doubleValue(fields["sodium"])
        entry.carbohydrates = doubleValue(fields["carbohydrates"])
        entry.fiber = doubleValue(fields["fiber"])
        entry.sugar = doubleValue(fields["sugar"])
        entry.protein = doubleValue(fields["protein"])
        if let foods = fields["foods"] as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: foods, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            entry.foodsJSON = text
        }
        if typeName != "location" {
            entry.latitude = nil
            entry.longitude = nil
            entry.accuracyMeters = nil
            entry.altitude = nil
        }
    }

    private static func signature(_ entry: JournalEntry) -> String {
        var fields: [String: String] = [
            "type": entry.typeRaw,
            "occurredAt": String(Int((entry.occurredAt.timeIntervalSince1970 * 1000).rounded())),
        ]
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields[key] = value
        }
        func putNumber(_ key: String, _ value: Double?) {
            guard let value else { return }
            put(key, String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value))
        }
        putNumber("latitude", entry.latitude)
        putNumber("longitude", entry.longitude)
        putNumber("accuracyMeters", entry.accuracyMeters)
        putNumber("altitude", entry.altitude)
        put("source", entry.source)
        put("description", entry.descriptionText)
        put("drinkName", entry.drinkName)
        put("amountLabel", entry.amountLabel)
        putNumber("amountOz", entry.amountOz)
        putNumber("amountMl", entry.amountMl)
        put("strength", entry.strength)
        put("kind", entry.kind)
        if let scale = entry.bristolScale {
            put("bristolScale", String(scale))
        }
        put("note", entry.note)
        put("title", entry.title)
        if let score = entry.moodScore {
            put("moodScore", String(score))
        }
        putNumber("sleepHours", entry.sleepHours)
        if let steps = entry.stepCount {
            put("stepCount", String(steps))
        }
        put("amountHad", entry.amountHad)
        if let stool = entry.stool {
            put("stool", stool ? "true" : "false")
        }
        if let urine = entry.urine {
            put("urine", urine ? "true" : "false")
        }
        put("stoolColor", entry.stoolColor)
        put("stoolAmount", entry.stoolAmount)
        put("urineColor", entry.urineColor)
        put("urineClarity", entry.urineClarity)
        put("urineAmount", entry.urineAmount)
        if let emotions = entry.emotions, !emotions.isEmpty {
            put("emotions", emotions.joined(separator: "\u{1f}"))
        }
        put("substanceName", entry.substanceName)
        putNumber("doseAmount", entry.doseAmount)
        put("doseUnit", entry.doseUnit)
        put("servingSize", entry.servingSize)
        putNumber("calories", entry.calories)
        putNumber("totalFat", entry.totalFat)
        putNumber("saturatedFat", entry.saturatedFat)
        putNumber("cholesterol", entry.cholesterol)
        putNumber("sodium", entry.sodium)
        putNumber("carbohydrates", entry.carbohydrates)
        putNumber("fiber", entry.fiber)
        putNumber("sugar", entry.sugar)
        putNumber("protein", entry.protein)
        put("foods", entry.foodsJSON)
        return fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: "\n")
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let amount = number.doubleValue
            return amount.isFinite ? amount : nil
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
