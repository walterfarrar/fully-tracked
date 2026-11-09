import SwiftData
import SwiftUI

struct BathroomForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date()
    @State private var stoolOn = true
    @State private var urineOn = false
    @State private var bristol = 0
    @State private var stoolColor = ""
    @State private var stoolAmount = ""
    @State private var urineColor = ""
    @State private var urineClarity = ""
    @State private var urineAmount = ""
    @State private var noteText = ""
    @State private var error = ""

    var body: some View {
        CheckInChrome(title: "Bathroom", when: $when, error: $error, saveTitle: "Save", save: save) {
            ChipFlow {
                Chip(title: "Stool", selected: stoolOn) { stoolOn.toggle() }
                Chip(title: "Urine", selected: urineOn) { urineOn.toggle() }
            }
            .padding(.top, 16)
            if stoolOn {
                choiceBlock("Bristol", titles: JournalCatalog.bristolTypes.map(String.init), selected: bristol == 0 ? "" : String(bristol)) { title in
                    bristol = Int(title) ?? 0
                }
                choiceBlock("Color", titles: JournalCatalog.stoolColors, selected: stoolColor) { stoolColor = $0 }
                choiceBlock("Amount", titles: JournalCatalog.stoolAmounts, selected: stoolAmount) { stoolAmount = $0 }
            }
            if urineOn {
                choiceBlock("Color", titles: JournalCatalog.urineColors, selected: urineColor) { urineColor = $0 }
                choiceBlock("Clarity", titles: JournalCatalog.urineClarity, selected: urineClarity) { urineClarity = $0 }
                choiceBlock("Amount", titles: JournalCatalog.urineAmounts, selected: urineAmount) { urineAmount = $0 }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Note")
                TextField("Note", text: $noteText)
                    .textFieldStyle(.plain)
                    .underlineField()
            }
            .padding(.top, 8)
        }
    }

    private func choiceBlock(_ title: String, titles: [String], selected: String, onTap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: title)
            ChipRow(titles: titles, isSelected: { $0 == selected }, onTap: onTap)
        }
        .padding(.top, 12)
    }

    private func save() {
        error = ""
        guard stoolOn || urineOn else {
            error = "Choose stool, urine, or both."
            return
        }
        if stoolOn {
            guard (1...7).contains(bristol) else {
                error = "Choose a Bristol type."
                return
            }
            guard !stoolColor.isEmpty, !stoolAmount.isEmpty else {
                error = "Choose a stool color and amount."
                return
            }
        }
        if urineOn {
            guard !urineColor.isEmpty, !urineClarity.isEmpty, !urineAmount.isEmpty else {
                error = "Choose a urine color, clarity, and amount."
                return
            }
        }
        let entry = JournalEntry(type: .bathroom, occurredAt: when)
        if stoolOn && urineOn {
            entry.kind = "both"
        } else if stoolOn {
            entry.kind = "stool"
        } else {
            entry.kind = "urine"
        }
        entry.stool = stoolOn
        entry.urine = urineOn
        if stoolOn {
            entry.bristolScale = bristol
            entry.stoolColor = stoolColor
            entry.stoolAmount = stoolAmount
        }
        if urineOn {
            entry.urineColor = urineColor
            entry.urineClarity = urineClarity
            entry.urineAmount = urineAmount
        }
        let note = FormValues.clean(noteText, limit: 2000)
        entry.note = note.isEmpty ? nil : note
        do {
            try JournalSave.commit(entry, in: context)
            dismiss()
        } catch {
            self.error = "The entry could not be saved."
        }
    }
}
