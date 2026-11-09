import SwiftData
import SwiftUI

struct HydrationForm: View {
    var openSettings: (SettingsTab) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var drinks: [Drink]
    @Query private var amounts: [HydrationAmount]
    @Query private var strengths: [StrengthLevel]
    @State private var when = Date()
    @State private var selectedDrink: String?
    @State private var selectedAmount: String?
    @State private var selectedStrength: String?
    @State private var newDrink = ""
    @State private var error = ""

    private var orderedDrinks: [Drink] {
        drinks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var orderedAmounts: [HydrationAmount] {
        amounts.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var orderedStrengths: [StrengthLevel] {
        strengths.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        CheckInChrome(title: "Hydration", when: $when, error: $error, saveTitle: "Save hydration", save: save) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Drink")
                ChipRow(
                    titles: orderedDrinks.map(\.name),
                    isSelected: { $0 == selectedDrink },
                    onTap: { selectedDrink = $0 }
                )
                AddRow(placeholder: "Add a drink", text: $newDrink, action: addDrink)
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Amount")
                ChipRow(
                    titles: orderedAmounts.map(\.label),
                    isSelected: { $0 == selectedAmount },
                    onTap: { selectedAmount = $0 }
                )
                GearButton(label: "Hydration") { openSettings(.hydration) }
            }
            .padding(.top, 8)
            if !orderedStrengths.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Strength")
                    ChipRow(
                        titles: orderedStrengths.map(\.label),
                        isSelected: { $0 == selectedStrength },
                        onTap: toggleStrength
                    )
                }
                .padding(.top, 8)
            }
        }
    }

    private func addDrink() {
        guard let drink = CatalogStore.addDrink(named: newDrink, existing: drinks, context: context) else { return }
        selectedDrink = drink.name
        newDrink = ""
    }

    private func toggleStrength(_ label: String) {
        if selectedStrength == label {
            selectedStrength = nil
        } else {
            selectedStrength = label
        }
    }

    private func save() {
        error = ""
        guard let drinkName = selectedDrink, !drinkName.isEmpty else {
            error = "Choose a drink."
            return
        }
        guard let amount = orderedAmounts.first(where: { $0.label == selectedAmount }) else {
            error = "Choose an amount."
            return
        }
        let entry = JournalEntry(type: .hydration, occurredAt: when)
        entry.drinkName = drinkName
        entry.amountLabel = amount.label
        entry.amountOz = amount.ounces
        entry.amountMl = amount.ounces * JournalCatalog.ouncesToMilliliters
        if let selectedStrength, !selectedStrength.isEmpty {
            entry.strength = selectedStrength
        }
        let entryID = entry.id
        let when = entry.occurredAt
        let drink = drinkName
        let milliliters = entry.amountMl
        let strength = entry.strength
        do {
            try JournalSave.commit(entry, in: context)
        } catch {
            self.error = "The entry could not be saved."
            return
        }
        Task {
            await HealthWriter.writeHydration(
                entryID: entryID,
                occurredAt: when,
                drinkName: drink,
                amountMl: milliliters,
                strength: strength
            )
        }
        dismiss()
    }
}
