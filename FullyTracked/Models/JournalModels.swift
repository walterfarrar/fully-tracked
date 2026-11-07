import Foundation
import SwiftData

enum EntryType: String, Codable, CaseIterable, Identifiable {
    case location
    case meal
    case hydration
    case bathroom
    case lifeEvent = "life_event"
    case mood
    case sleep
    case steps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .meal: "Meal"
        case .hydration: "Drink"
        case .bathroom: "Bathroom"
        case .lifeEvent: "Life event"
        case .mood: "Mood"
        case .sleep: "Sleep"
        case .steps: "Steps"
        }
    }
}

@Model
final class JournalEntry {
    var id: UUID
    var typeRaw: String
    var occurredAt: Date
    var savedAt: Date

    var latitude: Double?
    var longitude: Double?
    var accuracyMeters: Double?
    var altitude: Double?
    var source: String?

    var weatherObservedAt: Date?
    var temperatureCelsius: Double?
    var condition: String?

    var descriptionText: String?
    var drinkName: String?
    var amountMl: Double?
    var strength: String?

    var kind: String?
    var bristolScale: Int?
    var note: String?
    var title: String?

    var moodScore: Int?
    var sleepHours: Double?
    var stepCount: Int?

    var servingSize: String?
    var calories: Double?
    var totalFat: Double?
    var saturatedFat: Double?
    var cholesterol: Double?
    var sodium: Double?
    var carbohydrates: Double?
    var fiber: Double?
    var sugar: Double?
    var protein: Double?

    init(type: EntryType, occurredAt: Date) {
        self.id = UUID()
        self.typeRaw = type.rawValue
        self.occurredAt = occurredAt
        self.savedAt = Date()
    }

    var entryType: EntryType {
        get { EntryType(rawValue: typeRaw) ?? .meal }
        set { typeRaw = newValue.rawValue }
    }
}

@Model
final class Drink {
    var name: String
    var createdAt: Date

    init(name: String) {
        self.name = name
        self.createdAt = Date()
    }
}

@Model
final class StrengthLevel {
    var label: String
    var sortIndex: Int

    init(label: String, sortIndex: Int) {
        self.label = label
        self.sortIndex = sortIndex
    }
}

@Model
final class StrengthScaleSetting {
    var usesNumbers: Bool

    init(usesNumbers: Bool) {
        self.usesNumbers = usesNumbers
    }
}

enum JournalSeed {
    static func seed(_ context: ModelContext) {
        let drinks = (try? context.fetch(FetchDescriptor<Drink>())) ?? []
        if drinks.isEmpty {
            for name in ["water", "coffee", "soda"] {
                context.insert(Drink(name: name))
            }
        }

        let levels = (try? context.fetch(FetchDescriptor<StrengthLevel>())) ?? []
        if levels.isEmpty {
            for (index, label) in ["light", "medium", "strong"].enumerated() {
                context.insert(StrengthLevel(label: label, sortIndex: index))
            }
        }

        let scales = (try? context.fetch(FetchDescriptor<StrengthScaleSetting>())) ?? []
        if scales.isEmpty {
            context.insert(StrengthScaleSetting(usesNumbers: false))
        }

        try? context.save()
    }
}
