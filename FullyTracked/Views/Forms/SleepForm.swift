import SwiftData
import SwiftUI

struct SleepForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var when = Date()
    @State private var hoursText = ""
    @State private var noteText = ""
    @State private var error = ""

    var body: some View {
        CheckInChrome(title: "Sleep", when: $when, error: $error, saveTitle: "Save sleep", save: save) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Hours slept")
                TextField("Hours", text: $hoursText)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .keyboardType(.decimalPad)
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Note (optional)")
                TextField("Note", text: $noteText)
                    .textFieldStyle(.plain)
                    .underlineField()
            }
            .padding(.top, 8)
        }
    }

    private func save() {
        error = ""
        let hours: Double
        switch FormValues.readDecimal(hoursText) {
        case .empty, .invalid:
            error = "Enter hours slept."
            return
        case .value(let value):
            hours = value
        }
        guard hours >= 0.1, hours <= 24 else {
            error = "Enter hours between 0.1 and 24."
            return
        }
        let entry = JournalEntry(type: .sleep, occurredAt: when)
        entry.sleepHours = hours
        let note = FormValues.clean(noteText, limit: 2000)
        entry.note = note.isEmpty ? nil : note
        let entryID = entry.id
        let when = entry.occurredAt
        let slept = hours
        do {
            try JournalSave.commit(entry, in: context)
        } catch {
            self.error = "The entry could not be saved."
            return
        }
        Task {
            await HealthWriter.writeSleep(entryID: entryID, occurredAt: when, hours: slept)
        }
        dismiss()
    }
}
