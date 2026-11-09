import Foundation
import SwiftData

enum JournalCatalog {
    static let starterDrinks = ["Water", "Coffee", "Soda"]
    static let starterEvents = ["Family trip", "Birthday"]
    static let starterHydration: [(label: String, ounces: Double)] = [
        ("water", 8),
        ("coffee", 8),
        ("tea", 8),
        ("1 cup", 8),
        ("can", 12),
    ]
    static let legacyFoods = ["Eggs", "Oatmeal", "Rice", "Chicken", "Salad", "Fruit", "Yogurt", "Sandwich", "Pasta", "Soup"]
    static let moodTags = [
        "happy", "sad", "anxious", "excited",
        "calm", "angry", "tired", "stressed",
        "content", "bored", "hopeful", "overwhelmed",
        "grateful", "lonely", "frustrated", "peaceful",
    ]
    static let doseUnits = ["mg", "mcg", "IU", "tablet", "capsule", "ml"]
    static let urineColors = ["Clear", "Pale", "Yellow", "Dark", "Amber"]
    static let urineClarity = ["Clear", "Cloudy"]
    static let urineAmounts = ["A little", "Usual", "A lot"]
    static let stoolColors = ["Brown", "Tan", "Yellow", "Green", "Black", "Red"]
    static let stoolAmounts = ["A little", "Usual", "A lot"]
    static let bristolTypes = [1, 2, 3, 4, 5, 6, 7]
    static let portionUnits = ["g", "oz"]
    static let ouncesToMilliliters = 29.5735295625
}

enum FormValues {
    enum NumberRead {
        case empty
        case value(Double)
        case invalid
    }

    static func clean(_ text: String, limit: Int = 4_000) -> String {
        let joined = text.split(whereSeparator: \.isWhitespace).map(String.init).joined(separator: " ")
        if joined.count <= limit { return joined }
        return String(joined.prefix(limit))
    }

    static func readDecimal(_ text: String) -> NumberRead {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return .invalid }
        return .value(value)
    }

    static func decimal(_ text: String) -> Double? {
        if case .value(let value) = readDecimal(text) { return value }
        return nil
    }

    static func display(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if abs(value) < Double(Int.max), value.rounded() == value {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

@Model
final class FoodItem {
    var name: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, sortIndex: Int) {
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

@Model
final class HydrationAmount {
    var label: String = ""
    var ounces: Double = 0
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(label: String, ounces: Double, sortIndex: Int) {
        self.label = label
        self.ounces = ounces
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

@Model
final class EventType {
    var name: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, sortIndex: Int) {
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

@Model
final class Emotion {
    var name: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, sortIndex: Int) {
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

@Model
final class Substance {
    var uuid: UUID = UUID()
    var name: String = ""
    var dose: Double = 0
    var unit: String = ""
    var sortIndex: Int = 0
    var createdAt: Date = Date()

    init(name: String, dose: Double, unit: String, sortIndex: Int) {
        self.uuid = UUID()
        self.name = name
        self.dose = dose
        self.unit = unit
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}

@MainActor
enum CatalogStore {
    static func addDrink(named raw: String, existing: [Drink], context: ModelContext) -> Drink? {
        let name = FormValues.clean(raw, limit: 80)
        guard !name.isEmpty else { return nil }
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        let drink = Drink(name: name)
        return insert(drink, context: context)
    }

    static func addFood(named raw: String, existing: [FoodItem], context: ModelContext) -> FoodItem? {
        let name = FormValues.clean(raw, limit: 80)
        guard !name.isEmpty else { return nil }
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        let food = FoodItem(name: name, sortIndex: nextIndex(existing.map(\.sortIndex)))
        return insert(food, context: context)
    }

    static func addHydration(label raw: String, ounces: Double, existing: [HydrationAmount], context: ModelContext) -> HydrationAmount? {
        let label = FormValues.clean(raw, limit: 40)
        guard !label.isEmpty, ounces > 0, ounces.isFinite else { return nil }
        if let match = existing.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) {
            match.ounces = ounces
            try? context.save()
            return match
        }
        let amount = HydrationAmount(label: label, ounces: ounces, sortIndex: nextIndex(existing.map(\.sortIndex)))
        return insert(amount, context: context)
    }

    static func addEvent(named raw: String, existing: [EventType], context: ModelContext) -> EventType? {
        let name = FormValues.clean(raw, limit: 80)
        guard !name.isEmpty else { return nil }
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        let event = EventType(name: name, sortIndex: nextIndex(existing.map(\.sortIndex)))
        return insert(event, context: context)
    }

    static func addEmotion(named raw: String, existing: [Emotion], context: ModelContext) -> Emotion? {
        let name = FormValues.clean(raw, limit: 40)
        guard !name.isEmpty else { return nil }
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match
        }
        let emotion = Emotion(name: name, sortIndex: nextIndex(existing.map(\.sortIndex)))
        return insert(emotion, context: context)
    }

    static func addSubstance(name raw: String, dose: Double, unit: String, existing: [Substance], context: ModelContext) -> Substance? {
        let name = FormValues.clean(raw, limit: 80)
        guard !name.isEmpty, dose > 0, dose.isFinite, JournalCatalog.doseUnits.contains(unit) else { return nil }
        let substance = Substance(name: name, dose: dose, unit: unit, sortIndex: nextIndex(existing.map(\.sortIndex)))
        return insert(substance, context: context)
    }

    static func delete(_ model: some PersistentModel, context: ModelContext) {
        context.delete(model)
        try? context.save()
    }

    private static func nextIndex(_ values: [Int]) -> Int {
        (values.max() ?? -1) + 1
    }

    private static func insert<Model: PersistentModel>(_ model: Model, context: ModelContext) -> Model? {
        context.insert(model)
        do {
            try context.save()
            return model
        } catch {
            context.delete(model)
            return nil
        }
    }
}
