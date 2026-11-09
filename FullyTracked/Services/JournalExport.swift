import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum JournalExporter {
    static func data(entries: [JournalEntry]) throws -> Data {
        let payload: [String: Any] = [
            "format": "fully-tracked-journal",
            "version": 1,
            "exportedAt": iso(Date()),
            "entries": entries.map(dictionary(for:)),
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    static func filename(on date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "fully-tracked-journal-\(formatter.string(from: date))"
    }

    private static func dictionary(for entry: JournalEntry) -> [String: Any] {
        var object: [String: Any] = [
            "id": entry.id.uuidString,
            "type": typeName(entry),
            "occurredAt": iso(entry.occurredAt),
            "savedAt": iso(entry.savedAt),
        ]
        switch entry.entryType {
        case .location:
            put(&object, "latitude", entry.latitude)
            put(&object, "longitude", entry.longitude)
            put(&object, "accuracyMeters", entry.accuracyMeters)
            put(&object, "altitude", entry.altitude)
            put(&object, "source", entry.source)
            put(&object, "temperatureCelsius", entry.temperatureCelsius)
            put(&object, "condition", entry.condition)
            if let observed = entry.weatherObservedAt {
                object["weatherObservedAt"] = iso(observed)
            }
        case .meal:
            put(&object, "description", entry.descriptionText)
            put(&object, "amountHad", entry.amountHad)
            put(&object, "servingSize", entry.servingSize)
            put(&object, "calories", entry.calories)
            put(&object, "totalFat", entry.totalFat)
            put(&object, "saturatedFat", entry.saturatedFat)
            put(&object, "cholesterol", entry.cholesterol)
            put(&object, "sodium", entry.sodium)
            put(&object, "carbohydrates", entry.carbohydrates)
            put(&object, "fiber", entry.fiber)
            put(&object, "sugar", entry.sugar)
            put(&object, "protein", entry.protein)
            if let foods = foodsValue(entry.foodsJSON) {
                object["foods"] = foods
            }
        case .hydration:
            put(&object, "drinkName", entry.drinkName)
            put(&object, "amountLabel", entry.amountLabel)
            put(&object, "amountOz", entry.amountOz)
            put(&object, "amountMl", entry.amountMl)
            put(&object, "strength", entry.strength)
        case .bathroom:
            put(&object, "kind", entry.kind)
            put(&object, "bristolScale", entry.bristolScale)
            put(&object, "note", entry.note)
            put(&object, "stool", entry.stool)
            put(&object, "urine", entry.urine)
            put(&object, "stoolColor", entry.stoolColor)
            put(&object, "stoolAmount", entry.stoolAmount)
            put(&object, "urineColor", entry.urineColor)
            put(&object, "urineClarity", entry.urineClarity)
            put(&object, "urineAmount", entry.urineAmount)
        case .lifeEvent:
            put(&object, "title", entry.title)
            put(&object, "description", entry.descriptionText)
        case .mood:
            put(&object, "moodScore", entry.moodScore)
            put(&object, "note", entry.note)
            if let emotions = entry.emotions?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }),
               !emotions.isEmpty {
                object["emotions"] = emotions
            }
        case .sleep:
            put(&object, "sleepHours", entry.sleepHours)
            put(&object, "note", entry.note)
        case .steps:
            put(&object, "stepCount", entry.stepCount)
            put(&object, "source", entry.source)
        case .dose:
            put(&object, "substanceName", entry.substanceName)
            put(&object, "amount", entry.doseAmount)
            put(&object, "unit", entry.doseUnit)
        }
        return object
    }

    private static func typeName(_ entry: JournalEntry) -> String {
        switch entry.entryType {
        case .hydration: "water"
        default: entry.typeRaw
        }
    }

    private static func foodsValue(_ text: String?) -> [Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        guard let foods = try? JSONSerialization.jsonObject(with: data) as? [Any], !foods.isEmpty else { return nil }
        return foods
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func put(_ object: inout [String: Any], _ key: String, _ value: String?) {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        object[key] = trimmed
    }

    private static func put(_ object: inout [String: Any], _ key: String, _ value: Double?) {
        guard let value, value.isFinite else { return }
        object[key] = value
    }

    private static func put(_ object: inout [String: Any], _ key: String, _ value: Int?) {
        guard let value else { return }
        object[key] = value
    }

    private static func put(_ object: inout [String: Any], _ key: String, _ value: Bool?) {
        guard let value else { return }
        object[key] = value
    }
}

struct JournalDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
enum JournalSave {
    static func commit(_ entry: JournalEntry, in context: ModelContext) throws {
        context.insert(entry)
        do {
            try context.save()
        } catch {
            context.delete(entry)
            throw error
        }
    }
}
