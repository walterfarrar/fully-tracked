import SwiftData
import SwiftUI

struct LogView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppNavigation.self) private var navigation
    @Query private var entries: [JournalEntry]
    @State private var filter: EntryType?
    @State private var query = ""

    private var filtered: [JournalEntry] {
        let typed: [JournalEntry]
        if let filter {
            typed = entries.filter { $0.entryType == filter }
        } else {
            typed = entries
        }
        return JournalMath.search(typed, query: query)
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.occurredAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day, entries: grouped[day] ?? [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Log")
                .font(Theme.font(28, weight: .medium))
                .foregroundStyle(Theme.ink)
            ChipFlow {
                Chip(title: "All", selected: filter == nil) { filter = nil }
                ForEach(logTypes) { type in
                    Chip(title: type.title, selected: filter == type) { filter = type }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Entry type")
            HStack(alignment: .lastTextBaseline) {
                Text("Recent")
                    .font(Theme.font(18, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !filtered.isEmpty {
                    Text(countText)
                        .font(Theme.font(12))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Search")
                TextField("Type, meal, note, mood…", text: $query)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if filtered.isEmpty {
                Text(emptyText)
                    .font(Theme.font(16))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.entries, id: \.id) { entry in
                                row(entry)
                                    .listRowBackground(Theme.background)
                                    .listRowSeparatorTint(Theme.line)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button("Delete", role: .destructive) {
                                            delete(entry)
                                        }
                                    }
                            }
                        } header: {
                            Text(dayTitle(group.day))
                                .font(Theme.font(13))
                                .foregroundStyle(Theme.muted)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
    }

    private var logTypes: [EntryType] {
        [.location, .meal, .hydration, .bathroom, .mood, .lifeEvent, .dose, .sleep, .steps]
    }

    private var countText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return filtered.count == 1 ? "1 entry" : "\(filtered.count) entries"
        }
        return filtered.count == 1 ? "1 match" : "\(filtered.count) matches"
    }

    private var emptyText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return "No entries match “\(trimmed)”."
        }
        if let filter {
            return "No \(filter.title) entries yet."
        }
        return "Nothing here yet. Location check-ins appear when tracking is on. Meals, hydration, bathroom, life events, mood, and sleep can be added by hand."
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    @ViewBuilder
    private func row(_ entry: JournalEntry) -> some View {
        if entry.entryType == .location, let latitude = entry.latitude, let longitude = entry.longitude {
            Button {
                navigation.showOnMap(latitude: latitude, longitude: longitude)
            } label: {
                rowLabel(entry)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this check-in on the map")
        } else {
            rowLabel(entry)
        }
    }

    private func rowLabel(_ entry: JournalEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.entryType.title.uppercased())
                    .font(Theme.font(12))
                    .tracking(1.1)
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 8)
                Text(JournalMath.stamp(entry.occurredAt))
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            Text(JournalMath.summary(entry))
                .font(Theme.font(17))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
    }

    private func delete(_ entry: JournalEntry) {
        context.delete(entry)
        try? context.save()
    }
}

private struct DayGroup: Identifiable {
    var day: Date
    var entries: [JournalEntry]
    var id: Date { day }
}
