import Foundation
import SwiftData

struct ActivityDraft: Sendable {
    let kind: String
    let startedAt: Date
    let durationMinutes: Double
}

/// Call from a utility task. Each batch owns its context and saves once.
enum JournalBackgroundWriter {
    static func saveActivities(_ drafts: [ActivityDraft], container: ModelContainer) throws {
        guard let first = drafts.map(\.startedAt).min(), let last = drafts.map(\.startedAt).max() else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let lower = first.addingTimeInterval(-2)
        let upper = last.addingTimeInterval(2)
        let existing = try context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { entry in
                entry.typeRaw == "activity" && entry.occurredAt >= lower && entry.occurredAt <= upper
            }
        ))
        var known = Dictionary(grouping: existing, by: { $0.kind ?? "" }).mapValues { $0.map(\.occurredAt) }
        for draft in drafts where draft.durationMinutes >= 2 {
            guard !(known[draft.kind] ?? []).contains(where: { abs($0.timeIntervalSince(draft.startedAt)) < 2 }) else { continue }
            let entry = JournalEntry(type: .activity, occurredAt: draft.startedAt)
            entry.kind = draft.kind
            entry.durationMinutes = draft.durationMinutes
            entry.source = "motion"
            context.insert(entry)
            known[draft.kind, default: []].append(draft.startedAt)
        }
        if context.hasChanges { try context.save() }
    }

    static func saveSteps(_ days: [StepDay], container: ModelContainer) throws {
        guard let lower = days.map(\.day).min(), let last = days.map(\.day).max() else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let calendar = Calendar.current
        let upper = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86400)
        let existing = try context.fetch(FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { entry in
                entry.typeRaw == "steps" && entry.source == "apple-health"
                    && entry.occurredAt >= lower && entry.occurredAt < upper
            }
        ))
        var byDay = Dictionary(grouping: existing, by: { calendar.startOfDay(for: $0.occurredAt) })
        for day in days {
            let start = calendar.startOfDay(for: day.day)
            if let entry = byDay[start]?.first {
                // Unchanged daily totals must not invalidate every journal view.
                if entry.stepCount != day.count || entry.occurredAt != start {
                    entry.stepCount = day.count
                    entry.occurredAt = start
                    entry.savedAt = Date()
                }
            } else {
                let entry = JournalEntry(type: .steps, occurredAt: start)
                entry.stepCount = day.count
                entry.source = "apple-health"
                context.insert(entry)
                byDay[start] = [entry]
            }
        }
        if context.hasChanges { try context.save() }
    }
}
