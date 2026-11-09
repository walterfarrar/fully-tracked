import AppIntents
import Foundation
import SwiftData

struct JournalIntentFailure: Error, CustomLocalizedStringResourceConvertible, Sendable {
    var localizedStringResource: LocalizedStringResource

    init(_ message: LocalizedStringResource) {
        localizedStringResource = message
    }
}

@MainActor
enum JournalIntentStore {
    static func commit(_ entry: JournalEntry) throws {
        do {
            try JournalSave.commit(entry, in: SharedContainer.context)
        } catch {
            throw JournalIntentFailure("The entry could not be saved.")
        }
    }

    static func entries() throws -> [JournalEntry] {
        do {
            return try SharedContainer.context.fetch(FetchDescriptor<JournalEntry>())
        } catch {
            throw JournalIntentFailure("The journal could not be read.")
        }
    }

    static func applyOunces(_ ounces: Double, to entry: JournalEntry) throws {
        guard ounces.isFinite, ounces > 0 else {
            throw JournalIntentFailure("Enter an amount in ounces.")
        }
        entry.amountOz = ounces
        entry.amountMl = ounces * JournalCatalog.ouncesToMilliliters
        let amounts = (try? SharedContainer.context.fetch(FetchDescriptor<HydrationAmount>())) ?? []
        if let match = amounts.first(where: { abs($0.ounces - ounces) < 0.001 }) {
            entry.amountLabel = match.label
        }
    }

    static func catalogDrinkName(_ preferred: String) -> String {
        let drinks = (try? SharedContainer.context.fetch(FetchDescriptor<Drink>())) ?? []
        if let match = drinks.first(where: { $0.name.caseInsensitiveCompare(preferred) == .orderedSame }) {
            let name = match.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return preferred
    }
}

struct LogDrinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a Drink"
    static var description = IntentDescription("Save a drink in the journal on this phone.")

    @Parameter(title: "Drink")
    var drink: DrinkEntity

    @Parameter(title: "Ounces", description: "Amount in ounces. Optional.")
    var ounces: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$drink)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = FormValues.clean(drink.name, limit: 80)
        guard !name.isEmpty else { throw JournalIntentFailure("Choose a drink.") }
        let entry = JournalEntry(type: .hydration, occurredAt: Date())
        entry.drinkName = JournalIntentStore.catalogDrinkName(name)
        if let ounces {
            try JournalIntentStore.applyOunces(ounces, to: entry)
        }
        try JournalIntentStore.commit(entry)
        if let ounces {
            return .result(dialog: "Logged \(entry.drinkName ?? name), \(FormValues.display(ounces)) ounces.")
        }
        return .result(dialog: "Logged \(entry.drinkName ?? name).")
    }
}

struct LogMoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Mood"
    static var description = IntentDescription("Save a mood score in the journal on this phone.")

    @Parameter(title: "Score", description: "A mood score from 1 to 10.")
    var score: Int

    @Parameter(title: "Note", description: "An optional note.")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log mood \(\.$score)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (1...10).contains(score) else {
            throw JournalIntentFailure("Choose a score from 1 to 10.")
        }
        let entry = JournalEntry(type: .mood, occurredAt: Date())
        entry.moodScore = score
        if let note {
            let cleaned = FormValues.clean(note, limit: 2000)
            entry.note = cleaned.isEmpty ? nil : cleaned
        }
        try JournalIntentStore.commit(entry)
        return .result(dialog: "Logged mood \(score).")
    }
}

struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Water"
    static var description = IntentDescription("Save water you drank in the journal on this phone.")

    @Parameter(title: "Ounces", description: "How many ounces of water.")
    var ounces: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$ounces) ounces of water")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let entry = JournalEntry(type: .hydration, occurredAt: Date())
        entry.drinkName = JournalIntentStore.catalogDrinkName("Water")
        try JournalIntentStore.applyOunces(ounces, to: entry)
        try JournalIntentStore.commit(entry)
        return .result(dialog: "Logged \(FormValues.display(ounces)) ounces of water.")
    }
}

struct LogSleepIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Sleep"
    static var description = IntentDescription("Save hours slept in the journal on this phone.")

    @Parameter(title: "Hours", description: "Hours slept, from 0.1 to 24.")
    var hours: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$hours) hours of sleep")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard hours.isFinite, hours >= 0.1, hours <= 24 else {
            throw JournalIntentFailure("Enter hours between 0.1 and 24.")
        }
        let entry = JournalEntry(type: .sleep, occurredAt: Date())
        entry.sleepHours = hours
        try JournalIntentStore.commit(entry)
        return .result(dialog: "Logged \(FormValues.display(hours)) hours of sleep.")
    }
}

struct LogDoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a Dose"
    static var description = IntentDescription("Save a catalog dose in the journal on this phone.")

    @Parameter(title: "Substance")
    var substance: SubstanceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$substance)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = SharedContainer.context
        let substances = (try? context.fetch(FetchDescriptor<Substance>())) ?? []
        guard let item = substances.first(where: { $0.uuid.uuidString == substance.id }) else {
            throw JournalIntentFailure("Choose one.")
        }
        guard item.dose > 0, item.dose.isFinite else {
            throw JournalIntentFailure("Enter an amount.")
        }
        let entry = JournalEntry(type: .dose, occurredAt: Date())
        entry.substanceName = item.name
        entry.doseAmount = item.dose
        entry.doseUnit = item.unit
        try JournalIntentStore.commit(entry)
        let amount = FormValues.display(item.dose)
        let detail = item.unit.isEmpty ? amount : "\(amount) \(item.unit)"
        return .result(dialog: "Logged \(item.name), \(detail).")
    }
}

struct CheckInLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Check In Location"
    static var description = IntentDescription("Save one location check-in on this phone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tracker = LocationTracker.shared
        tracker.checkInNow()
        let deadline = Date().addingTimeInterval(30)
        while tracker.checkingIn, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        let message = tracker.lastEvent.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return .result(dialog: "The location check-in was requested.")
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

@available(*, deprecated)
extension CheckInLocationIntent {
    static var openAppWhenRun: Bool = true
}

struct TodaySummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's Summary"
    static var description = IntentDescription("Speak a short summary of today's journal on this phone.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rows = try JournalIntentStore.entries()
        let summary = JournalRollups.summaries(rows, days: 1).last
        let speech = summary.map { JournalRollups.spokenDay($0) } ?? "Nothing is logged for today yet."
        return .result(dialog: IntentDialog(stringLiteral: speech))
    }
}
