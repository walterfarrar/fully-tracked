import Foundation
import HealthKit
import SwiftData

struct StepDay: Sendable {
    var day: Date
    var count: Int
}

@MainActor
final class HealthSteps: ObservableObject {
    static let shared = HealthSteps()

    @Published private(set) var status = "Steps appear after Apple Health shares a daily total. None are invented."

    private let store = HKHealthStore()
    private var container: ModelContainer?
    private var timer: Timer?
    private var activeQuery: HKStatisticsCollectionQuery?
    private var lastRefresh: Date?
    private let interval: TimeInterval = 30 * 60

    func attach(_ container: ModelContainer) {
        self.container = container
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refreshIfDue() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval {
            return
        }
        refresh()
    }

    func refresh() {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Apple Health is not available on this device. No step total was invented."
            return
        }
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            status = "Apple Health did not provide step totals. No step total was invented."
            return
        }
        lastRefresh = Date()
        store.requestAuthorization(toShare: [], read: [type]) { [weak self] success, _ in
            Task { @MainActor in
                guard let self else { return }
                if !success {
                    self.status = "Apple Health did not share steps. No step total was invented."
                    return
                }
                self.query(type)
            }
        }
    }

    private func query(_ type: HKQuantityType) {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: end)) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: calendar.startOfDay(for: end),
            intervalComponents: DateComponents(day: 1)
        )
        query.initialResultsHandler = { [weak self] _, results, error in
            if let error {
                Task { @MainActor in
                    self?.status = "Steps could not be read. No step total was invented."
                    _ = error
                }
                return
            }
            var days: [StepDay] = []
            results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                guard let sum = statistics.sumQuantity() else { return }
                let count = Int(sum.doubleValue(for: HKUnit.count()))
                days.append(StepDay(day: statistics.startDate, count: count))
            }
            Task { @MainActor in
                self?.store(days)
            }
        }
        activeQuery = query
        store.execute(query)
    }

    private func store(_ days: [StepDay]) {
        guard let context = container?.mainContext else { return }
        let existing = ((try? context.fetch(FetchDescriptor<JournalEntry>())) ?? [])
            .filter { $0.entryType == .steps && $0.source == "apple-health" }
        let calendar = Calendar.current
        for day in days {
            if let match = existing.first(where: { calendar.isDate($0.occurredAt, inSameDayAs: day.day) }) {
                match.stepCount = day.count
                match.occurredAt = calendar.startOfDay(for: day.day)
                match.savedAt = Date()
                match.source = "apple-health"
            } else {
                let entry = JournalEntry(type: .steps, occurredAt: calendar.startOfDay(for: day.day))
                entry.stepCount = day.count
                entry.source = "apple-health"
                context.insert(entry)
            }
        }
        do {
            try context.save()
            if days.isEmpty {
                status = "No step totals were shared by Apple Health. None were invented."
            } else {
                status = "Steps are daily totals from Apple Health."
            }
        } catch {
            status = "Steps could not be saved. No step total was invented."
        }
    }
}
