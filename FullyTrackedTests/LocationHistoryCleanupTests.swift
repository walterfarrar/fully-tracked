import SwiftData
import XCTest
@testable import FullyTracked

final class LocationHistoryCleanupTests: XCTestCase {
    @MainActor
    func testCleanupPreservesCheckInsAndOtherJournalEntries() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var kept: [JournalEntry] = []
        // Significant-change readings already used the interval limit. Unknown
        // imported sources are preserved conservatively, as are older nil sources.
        let sources: [String?] = [nil, "device", "significant", "imported"]
        for source in sources {
            let checkIn = JournalEntry(type: .location, occurredAt: .now)
            checkIn.source = source
            checkIn.latitude = 41.123
            checkIn.longitude = -87.456
            checkIn.accuracyMeters = 25
            checkIn.placeName = "Saved place"
            context.insert(checkIn)
            kept.append(checkIn)
        }
        for type in EntryType.allCases where type != .location && type != .visit {
            let entry = JournalEntry(type: type, occurredAt: .now)
            context.insert(entry)
            kept.append(entry)
        }
        let trip = JournalEntry(type: .location, occurredAt: .now)
        trip.source = "trip"
        context.insert(trip)
        for kind in ["arrival", "departure"] {
            let visit = JournalEntry(type: .visit, occurredAt: .now)
            visit.kind = kind
            context.insert(visit)
        }
        try context.save()
        let keptIDs = Set(kept.map(\.id))

        XCTAssertEqual(try LocationHistoryCleanup.run(in: container), 3)

        let verification = ModelContext(container)
        let remaining = try verification.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(Set(remaining.map(\.id)), keptIDs)
        for entry in remaining where entry.isLocationCheckIn {
            XCTAssertEqual(entry.latitude, 41.123)
            XCTAssertEqual(entry.longitude, -87.456)
            XCTAssertEqual(entry.accuracyMeters, 25)
            XCTAssertEqual(entry.placeName, "Saved place")
        }
    }

    @MainActor
    func testCleanupPrunesUnusedCoordinatesAndCanRunAgain() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let checkIn = JournalEntry(type: .location, occurredAt: .now)
        checkIn.source = "device"
        checkIn.latitude = 41.1234
        checkIn.longitude = -87.4564
        context.insert(checkIn)
        let trip = JournalEntry(type: .location, occurredAt: .now)
        trip.source = "trip"
        trip.latitude = checkIn.latitude
        trip.longitude = checkIn.longitude
        context.insert(trip)
        let sharedCache = PlaceCacheEntry(latKey: "41.123", lonKey: "-87.456", name: "Shared place")
        context.insert(sharedCache)
        context.insert(PlaceCacheEntry(latKey: "42.000", lonKey: "-88.000", name: "Old trip place"))
        try context.save()
        let checkInID = checkIn.id

        XCTAssertEqual(try LocationHistoryCleanup.run(in: container), 1)
        XCTAssertEqual(try LocationHistoryCleanup.run(in: container), 0)

        let verification = ModelContext(container)
        let remaining = try verification.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(remaining.map(\.id), [checkInID])
        let caches = try verification.fetch(FetchDescriptor<PlaceCacheEntry>())
        XCTAssertEqual(caches.count, 1)
        XCTAssertEqual(caches.first?.name, "Shared place")
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([JournalEntry.self, PlaceCacheEntry.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
