import Foundation
import SwiftData

enum EntryType: String, Codable, CaseIterable, Identifiable, Hashable {
    case location
    case meal
    case hydration
    case bathroom
    case lifeEvent = "life_event"
    case mood
    case sleep
    case steps
    case dose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .meal: "Meal"
        case .hydration: "Hydration"
        case .bathroom: "Bathroom"
        case .lifeEvent: "Life event"
        case .mood: "Mood"
        case .sleep: "Sleep"
        case .steps: "Steps"
        case .dose: "Dose"
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

    var amountLabel: String? = nil
    var amountOz: Double? = nil
    var amountHad: String? = nil
    var foodsJSON: String? = nil
    var stool: Bool? = nil
    var urine: Bool? = nil
    var stoolColor: String? = nil
    var stoolAmount: String? = nil
    var urineColor: String? = nil
    var urineClarity: String? = nil
    var urineAmount: String? = nil
    var emotions: [String]? = nil
    var substanceName: String? = nil
    var doseAmount: Double? = nil
    var doseUnit: String? = nil

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
        seedDrinks(context)
        seedStrength(context)
        seedFoods(context)
        seedHydration(context)
        seedEvents(context)
        seedEmotions(context)
        try? context.save()
    }

    private static func seedDrinks(_ context: ModelContext) {
        guard let drinks = try? context.fetch(FetchDescriptor<Drink>()) else { return }
        if drinks.isEmpty {
            for name in JournalCatalog.starterDrinks {
                context.insert(Drink(name: name))
            }
            return
        }
        let legacy = Set(["water", "coffee", "soda"])
        guard Set(drinks.map(\.name)) == legacy else { return }
        for drink in drinks {
            switch drink.name {
            case "water": drink.name = "Water"
            case "coffee": drink.name = "Coffee"
            case "soda": drink.name = "Soda"
            default: break
            }
        }
    }

    private static func seedStrength(_ context: ModelContext) {
        if let levels = try? context.fetch(FetchDescriptor<StrengthLevel>()), levels.isEmpty {
            for (index, label) in ["light", "medium", "strong"].enumerated() {
                context.insert(StrengthLevel(label: label, sortIndex: index))
            }
        }
        if let scales = try? context.fetch(FetchDescriptor<StrengthScaleSetting>()), scales.isEmpty {
            context.insert(StrengthScaleSetting(usesNumbers: false))
        }
    }

    private static func seedFoods(_ context: ModelContext) {
        seedOnce(context, key: "fully-tracked-seeded-foods", FoodItem.self) {
            for (index, name) in JournalCatalog.legacyFoods.enumerated() {
                context.insert(FoodItem(name: name, sortIndex: index))
            }
        }
    }

    private static func seedHydration(_ context: ModelContext) {
        seedOnce(context, key: "fully-tracked-seeded-hydration", HydrationAmount.self) {
            for (index, item) in JournalCatalog.starterHydration.enumerated() {
                context.insert(HydrationAmount(label: item.label, ounces: item.ounces, sortIndex: index))
            }
        }
    }

    private static func seedEvents(_ context: ModelContext) {
        guard let events = try? context.fetch(FetchDescriptor<EventType>()) else { return }
        guard events.isEmpty else { return }
        for (index, name) in JournalCatalog.starterEvents.enumerated() {
            context.insert(EventType(name: name, sortIndex: index))
        }
    }

    private static func seedEmotions(_ context: ModelContext) {
        guard let emotions = try? context.fetch(FetchDescriptor<Emotion>()) else { return }
        guard emotions.isEmpty else { return }
        for (index, name) in JournalCatalog.moodTags.enumerated() {
            context.insert(Emotion(name: name, sortIndex: index))
        }
    }

    /// Seeds a catalog once. Later deletions stay deleted.
    private static func seedOnce<Model: PersistentModel>(
        _ context: ModelContext,
        key: String,
        _: Model.Type,
        insert: () -> Void
    ) {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let rows = try? context.fetch(FetchDescriptor<Model>()) else { return }
        if rows.isEmpty {
            insert()
            do {
                try context.save()
            } catch {
                return
            }
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
