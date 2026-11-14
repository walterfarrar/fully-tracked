import Foundation
import SwiftData

enum JournalQueries {
    static func latestCheckIn(in context: ModelContext, byOccurrence: Bool = false) throws -> JournalEntry? {
        var descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { entry in
                entry.typeRaw == "location" && (entry.source == nil || entry.source != "trip")
            },
            sortBy: byOccurrence
                ? [SortDescriptor(\JournalEntry.occurredAt, order: .reverse)]
                : [SortDescriptor(\JournalEntry.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func entry(id: UUID, in context: ModelContext) throws -> JournalEntry? {
        let targetID = id
        var descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate<JournalEntry> { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
