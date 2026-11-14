import Foundation
import SwiftData
import XCTest
@testable import FullyTracked

final class JournalPersistenceTests: XCTestCase {
    @MainActor
    func testUnchangedStepTotalsKeepTheirSavedTimeAndChangedTotalsUpdateInPlace() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let day = Calendar.current.startOfDay(for: Date())
        let originalSave = day.addingTimeInterval(-3600)
        let steps = JournalEntry(type: .steps, occurredAt: day)
        steps.source = "apple-health"
        steps.stepCount = 5000
        steps.savedAt = originalSave
        let id = steps.id
        context.insert(steps)
        let meal = JournalEntry(type: .meal, occurredAt: day)
        meal.descriptionText = "Lunch"
        context.insert(meal)
        try context.save()

        try await Task.detached(priority: .utility) {
            try JournalBackgroundWriter.saveSteps([StepDay(day: day, count: 5000)], container: container)
        }.value
        let unchangedContext = ModelContext(container)
        let unchanged = try XCTUnwrap(JournalQueries.entry(id: id, in: unchangedContext))
        XCTAssertEqual(unchanged.savedAt, originalSave)
        XCTAssertEqual(unchanged.stepCount, 5000)

        try await Task.detached(priority: .utility) {
            try JournalBackgroundWriter.saveSteps([StepDay(day: day, count: 5500)], container: container)
        }.value
        let changedContext = ModelContext(container)
        let changed = try XCTUnwrap(JournalQueries.entry(id: id, in: changedContext))
        XCTAssertEqual(changed.stepCount, 5500)
        XCTAssertNotEqual(changed.savedAt, originalSave)
        XCTAssertEqual(try changedContext.fetchCount(FetchDescriptor<JournalEntry>()), 2)
        XCTAssertEqual(try JournalQueries.entry(id: meal.id, in: changedContext)?.descriptionText, "Lunch")
    }

    @MainActor
    func testActivityReplayIsDeduplicatedWithinAndAcrossBatches() async throws {
        let container = try makeContainer()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let drafts = [
            ActivityDraft(kind: "walking", startedAt: start, durationMinutes: 10),
            ActivityDraft(kind: "walking", startedAt: start.addingTimeInterval(1), durationMinutes: 10),
            ActivityDraft(kind: "cycling", startedAt: start.addingTimeInterval(600), durationMinutes: 20),
            ActivityDraft(kind: "stationary", startedAt: start.addingTimeInterval(1800), durationMinutes: 1),
        ]
        try await Task.detached(priority: .utility) {
            try JournalBackgroundWriter.saveActivities(drafts, container: container)
            try JournalBackgroundWriter.saveActivities(drafts, container: container)
        }.value
        let context = ModelContext(container)
        let saved = try context.fetch(FetchDescriptor<JournalEntry>())
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.compactMap(\.kind)), Set(["walking", "cycling"]))
        XCTAssertTrue(saved.allSatisfy { $0.source == "motion" && $0.entryType == .activity })
    }

    @MainActor
    func testLatestCheckInQueryPreservesNilAndSignificantSourcesAndExcludesTrips() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let olderSave = JournalEntry(type: .location, occurredAt: start.addingTimeInterval(100))
        olderSave.savedAt = start
        context.insert(olderSave)
        let latestSave = JournalEntry(type: .location, occurredAt: start)
        latestSave.source = "significant"
        latestSave.savedAt = start.addingTimeInterval(100)
        context.insert(latestSave)
        let trip = JournalEntry(type: .location, occurredAt: start.addingTimeInterval(200))
        trip.source = "trip"
        trip.savedAt = start.addingTimeInterval(200)
        context.insert(trip)
        try context.save()

        XCTAssertEqual(try JournalQueries.latestCheckIn(in: context)?.id, latestSave.id)
        XCTAssertEqual(try JournalQueries.latestCheckIn(in: context, byOccurrence: true)?.id, olderSave.id)
        XCTAssertEqual(try JournalQueries.entry(id: olderSave.id, in: context)?.id, olderSave.id)
        XCTAssertNil(try JournalQueries.entry(id: UUID(), in: context))
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([JournalEntry.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}
