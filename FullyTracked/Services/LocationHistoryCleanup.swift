import Foundation
import SwiftData

enum LocationHistoryCleanup {
    /// Preserve check-ins and other journal entries; remove the retired travel history.
    /// A separate context keeps a failed cleanup from changing the UI's pending edits.
    @MainActor
    @discardableResult
    static func run(in container: ModelContainer) throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let entries = try context.fetch(FetchDescriptor<JournalEntry>())
        let caches = try context.fetch(FetchDescriptor<PlaceCacheEntry>())
        let obsolete = entries.filter {
            $0.entryType == .visit || ($0.entryType == .location && $0.source == "trip")
        }
        let obsoleteIDs = Set(obsolete.map(\.id))
        let keptPlaces = Set(entries.compactMap { entry -> String? in
            guard !obsoleteIDs.contains(entry.id),
                  let latitude = entry.latitude, let longitude = entry.longitude else { return nil }
            return "\(PlaceNamer.key(latitude))|\(PlaceNamer.key(longitude))"
        })
        for entry in obsolete {
            context.delete(entry)
        }
        // Clear cached coordinates that no surviving journal entry needs.
        for cache in caches where !keptPlaces.contains("\(cache.latKey)|\(cache.lonKey)") {
            context.delete(cache)
        }
        try context.save()
        return obsolete.count
    }
}
