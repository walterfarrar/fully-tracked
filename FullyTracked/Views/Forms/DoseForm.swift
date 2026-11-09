import SwiftData
import SwiftUI

struct DoseForm: View {
    var openSettings: (SettingsTab) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var substances: [Substance]
    @State private var when = Date()
    @State private var selected: UUID?
    @State private var amountText = ""
    @State private var unitText = ""
    @State private var error = ""

    private var ordered: [Substance] {
        substances.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        CheckInChrome(
            title: "Dose",
            when: $when,
            error: $error,
            saveTitle: "Save",
            canSave: !ordered.isEmpty,
            save: save
        ) {
            if ordered.isEmpty {
                Text("None yet.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 16)
                GearButton(label: "Medication") { openSettings(.medication) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Substance")
                    ChipFlow {
                        ForEach(ordered) { item in
                            Chip(title: item.name, selected: selected == item.uuid) {
                                select(item)
                            }
                        }
                    }
                }
                .padding(.top, 16)
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(text: "Amount")
                    TextField("Amount", text: $amountText)
                        .textFieldStyle(.plain)
                        .underlineField()
                        .keyboardType(.decimalPad)
                    if !unitText.isEmpty {
                        Text(unitText)
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: ordered.map(\.uuid)) { _, ids in
            if let selected, !ids.contains(selected) {
                self.selected = nil
                amountText = ""
                unitText = ""
            }
        }
    }

    private func select(_ item: Substance) {
        selected = item.uuid
        amountText = FormValues.display(item.dose)
        unitText = item.unit
    }

    private func save() {
        error = ""
        guard let item = ordered.first(where: { $0.uuid == selected }) else {
            error = "Choose one."
            return
        }
        guard let amount = FormValues.decimal(amountText), amount > 0 else {
            error = "Enter an amount."
            return
        }
        let entry = JournalEntry(type: .dose, occurredAt: when)
        entry.substanceName = item.name
        entry.doseAmount = amount
        entry.doseUnit = item.unit
        do {
            try JournalSave.commit(entry, in: context)
            dismiss()
        } catch {
            self.error = "The entry could not be saved."
        }
    }
}
