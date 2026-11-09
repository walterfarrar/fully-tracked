import SwiftData
import SwiftUI

struct LifeEventForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var events: [EventType]
    @State private var when = Date()
    @State private var selected: String?
    @State private var newName = ""
    @State private var details = ""
    @State private var error = ""

    private var ordered: [EventType] {
        events.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        CheckInChrome(title: "Life event", when: $when, error: $error, saveTitle: "Save life event", save: save) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Type")
                ChipRow(
                    titles: ordered.map(\.name),
                    isSelected: { $0 == selected },
                    onTap: { selected = $0 }
                )
                AddRow(placeholder: "Add a type", text: $newName, action: addEvent)
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Description (optional)")
                TextField("Description", text: $details, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .underlineField()
            }
            .padding(.top, 8)
        }
    }

    private func addEvent() {
        guard let event = CatalogStore.addEvent(named: newName, existing: events, context: context) else { return }
        selected = event.name
        newName = ""
    }

    private func save() {
        error = ""
        var title = selected ?? ""
        if !FormValues.clean(newName).isEmpty {
            if let event = CatalogStore.addEvent(named: newName, existing: events, context: context) {
                title = event.name
                newName = ""
            }
        }
        guard !title.isEmpty else {
            error = "Choose a type."
            return
        }
        let entry = JournalEntry(type: .lifeEvent, occurredAt: when)
        entry.title = title
        let description = FormValues.clean(details, limit: 4000)
        entry.descriptionText = description.isEmpty ? nil : description
        do {
            try JournalSave.commit(entry, in: context)
            dismiss()
        } catch {
            self.error = "The entry could not be saved."
        }
    }
}
