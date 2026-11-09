import Combine
import Foundation
import HealthKit
import SwiftData

struct StepDay: Sendable {
    var day: Date
    var count: Int
}

private struct TypeSyncResult: Sendable {
    var failed: Bool
    var stepDays: Int
}

/// Reads Apple Health into the on-device journal.
/// `HealthSteps` stays as the name `FullyTrackedApp`, `HomeView`, and `LocationTracker` already call.
typealias HealthSteps = HealthSync

@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()

    @Published private(set) var status = "Steps appear after Apple Health shares a daily total. None are invented."
    @Published private(set) var lastSync: Date?
    @Published private(set) var sampleCount = 0

    private let store = HKHealthStore()
    private var container: ModelContainer?
    private var timer: Timer?
    private var observerQueries: [HKObserverQuery] = []
    private var observersInstalled = false
    private var started = false
    private var lastRefresh: Date?
    private var chain: Task<Void, Never>?
    private var busy = false
    private var pendingTypeRaws: Set<String> = []
    private let interval: TimeInterval = 30 * 60

    private init() {}

    func attach(_ container: ModelContainer) {
        self.container = container
    }

    func start() {
        guard !started else { return }
        started = true
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Apple Health is not available on this device. No step total was invented."
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func refreshIfDue() {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < interval {
            return
        }
        refresh()
    }

    func refresh() {
        lastRefresh = Date()
        enqueue { await self.syncAll() }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            self.busy = true
            await work()
            await self.finishQueue()
            self.busy = false
            if !self.pendingTypeRaws.isEmpty {
                self.busy = true
                await self.finishQueue()
                self.busy = false
            }
            if let container = self.container {
                if let count = try? await Task.detached(priority: .utility, operation: {
                    try HealthDatabase.count(container: container)
                }).value {
                    self.sampleCount = count
                }
            }
        }
    }

    private func finishQueue() async {
        while !pendingTypeRaws.isEmpty {
            let raws = pendingTypeRaws
            pendingTypeRaws.removeAll()
            for raw in raws {
                guard let type = HealthCatalog.byRaw[raw] else { continue }
                _ = await syncType(type)
            }
        }
    }

    private func noteObserver(typeRaw: String, completion: @escaping @Sendable () -> Void) {
        if busy {
            pendingTypeRaws.insert(typeRaw)
            completion()
            return
        }
        enqueue {
            if let type = HealthCatalog.byRaw[typeRaw] {
                let result = await self.syncType(type)
                if !result.failed {
                    self.lastSync = Date()
                }
            }
            completion()
        }
    }

    private func syncAll() async {
        status = "Reading Apple Health on this device."
        guard await prepare() else { return }
        guard let container else {
            status = "Health data is not attached to the journal yet."
            return
        }
        var failed = 0
        var stepDays = 0
        for type in HealthCatalog.synced {
            let result = await syncType(type)
            if result.failed {
                failed += 1
            }
            if type.typeRaw == "stepCount" {
                stepDays = result.stepDays
            }
        }
        if let count = try? await Task.detached(priority: .utility, operation: {
            try HealthDatabase.count(container: container)
        }).value {
            sampleCount = count
        }
        lastSync = Date()
        if failed == HealthCatalog.synced.count {
            status = "Apple Health could not be read. Nothing was invented."
            return
        }
        if sampleCount == 0 && stepDays == 0 {
            status = "No Health samples were shared. Nothing was invented."
        } else if stepDays == 0 {
            status = "Health data is on this device. No step totals were shared. None were invented."
        } else {
            status = "Health data is on this device. Steps are daily totals from Apple Health."
        }
        if failed > 0 {
            status += " Some types could not be read."
        }
    }

    private func prepare() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Apple Health is not available on this device. No step total was invented."
            return false
        }
        let granted = await requestAuthorization()
        guard granted else {
            status = "Apple Health did not share data. Nothing was invented."
            return false
        }
        installObservers()
        return true
    }

    private func requestAuthorization() async -> Bool {
        let share = HealthCatalog.shareTypes
        let read = HealthCatalog.readObjectTypes
        return await withCheckedContinuation { continuation in
            let gate = HealthResume()
            store.requestAuthorization(toShare: share, read: read) { success, _ in
                gate.run {
                    continuation.resume(returning: success)
                }
            }
        }
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        for type in HealthCatalog.synced {
            let raw = type.typeRaw
            let sampleType = type.sampleType
            store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { _, _ in }
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
                if error != nil {
                    completion()
                    return
                }
                Task { @MainActor in
                    HealthSync.shared.noteObserver(typeRaw: raw, completion: completion)
                }
            }
            observerQueries.append(query)
            store.execute(query)
        }
    }

    private func syncType(_ type: HealthReadType) async -> TypeSyncResult {
        guard HKHealthStore.isHealthDataAvailable(), let container else {
            return TypeSyncResult(failed: true, stepDays: 0)
        }
        switch type.sync {
        case .displayOnly:
            return TypeSyncResult(failed: false, stepDays: 0)
        case .stateOfMind:
            do {
                let start = windowStart(for: type.typeRaw)
                let drafts = try await fetchStateOfMind(windowStart: start, type: type)
                try await Task.detached(priority: .utility) {
                    try HealthDatabase.replaceStateOfMind(
                        container: container,
                        drafts: drafts,
                        windowStart: start
                    )
                }.value
                return TypeSyncResult(failed: false, stepDays: 0)
            } catch {
                return TypeSyncResult(failed: true, stepDays: 0)
            }
        case .anchored:
            do {
                let batch = try await fetchAnchored(type)
                var deleted = batch.deleted
                if type.kind == .workout {
                    deleted.append(contentsOf: batch.deleted.map(HealthIdentity.energyID(for:)))
                    let energies = Set(batch.drafts.filter { $0.typeRaw == "workoutEnergy" }.map(\.hkUUID))
                    for draft in batch.drafts where draft.typeRaw == "workout" {
                        let energy = HealthIdentity.energyID(for: draft.hkUUID)
                        if !energies.contains(energy) {
                            deleted.append(energy)
                        }
                    }
                }
                let affected = try await Task.detached(priority: .utility) {
                    try HealthDatabase.apply(
                        container: container,
                        drafts: batch.drafts,
                        deleted: deleted
                    )
                }.value
                let result = try await rollup(type, affected: affected, container: container)
                if let anchorData = batch.anchorData {
                    try await Task.detached(priority: .utility) {
                        try HealthDatabase.storeAnchor(
                            container: container,
                            typeRaw: type.typeRaw,
                            data: anchorData
                        )
                    }.value
                }
                return result
            } catch {
                return TypeSyncResult(failed: true, stepDays: 0)
            }
        }
    }

    private func rollup(
        _ type: HealthReadType,
        affected: [String: [Date]],
        container: ModelContainer
    ) async throws -> TypeSyncResult {
        if type.prefersStatistics {
            let start = windowStart(for: type.typeRaw)
            if let sums = await dailySums(type, from: start, to: Date()) {
                try await Task.detached(priority: .utility) {
                    try HealthDatabase.replaceSums(
                        container: container,
                        typeRaw: type.typeRaw,
                        unit: type.unitLabel,
                        values: sums,
                        windowStart: start
                    )
                }.value
                if type.typeRaw == "stepCount" {
                    return TypeSyncResult(failed: false, stepDays: storeStepJournal(sums))
                }
                return TypeSyncResult(failed: false, stepDays: 0)
            }
            try await recomputeSamples(typeRaw: type.typeRaw, days: affected[type.typeRaw] ?? [], aggregate: type.aggregate, container: container)
            return TypeSyncResult(failed: false, stepDays: 0)
        }
        if type.kind == .sleep {
            try await Task.detached(priority: .utility) {
                try HealthDatabase.recomputeSleep(container: container, days: affected["sleepAnalysis"] ?? [])
            }.value
            return TypeSyncResult(failed: false, stepDays: 0)
        }
        if type.kind == .workout {
            for raw in ["workout", "workoutEnergy"] {
                try await recomputeSamples(typeRaw: raw, days: affected[raw] ?? [], aggregate: .sum, container: container)
            }
            return TypeSyncResult(failed: false, stepDays: 0)
        }
        try await recomputeSamples(
            typeRaw: type.typeRaw,
            days: affected[type.typeRaw] ?? [],
            aggregate: type.aggregate,
            container: container
        )
        return TypeSyncResult(failed: false, stepDays: 0)
    }

    private func recomputeSamples(
        typeRaw: String,
        days: [Date],
        aggregate: HealthAggregate,
        container: ModelContainer
    ) async throws {
        guard !days.isEmpty else { return }
        try await Task.detached(priority: .utility) {
            try HealthDatabase.recompute(
                container: container,
                typeRaw: typeRaw,
                days: days,
                aggregate: aggregate
            )
        }.value
    }

    private func fetchAnchored(
        _ type: HealthReadType
    ) async throws -> (drafts: [HealthDraft], deleted: [UUID], anchorData: Data?) {
        let raw = type.typeRaw
        let storedContainer = container
        let anchorData = try await Task.detached(priority: .utility) { () -> Data? in
            guard let storedContainer else { return nil }
            return try HealthDatabase.readAnchor(container: storedContainer, typeRaw: raw)
        }.value
        let anchor = anchorData.flatMap { data in
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }
        let start = windowStart(for: type.typeRaw)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let previousAnchor = anchorData
        return try await withCheckedThrowingContinuation { continuation in
            let gate = HealthResume()
            let box = HealthQueryBox()
            let query = HKAnchoredObjectQuery(
                type: type.sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                box.query = nil
                gate.run {
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let drafts = HealthConvert.drafts(from: samples ?? [], type: type)
                    let removed = (deleted ?? []).map(\.uuid)
                    let archived: Data?
                    if let newAnchor,
                       let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                        archived = data
                    } else {
                        archived = previousAnchor
                    }
                    continuation.resume(returning: (drafts, removed, archived))
                }
            }
            box.query = query
            store.execute(query)
        }
    }

    private func fetchStateOfMind(windowStart: Date, type: HealthReadType) async throws -> [HealthDraft] {
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: nil, options: .strictStartDate)
        let typed = HKSamplePredicate<HKStateOfMind>.stateOfMind(predicate)
        let descriptor = HKSampleQueryDescriptor<HKStateOfMind>(
            predicates: [typed],
            sortDescriptors: [] as [SortDescriptor<HKStateOfMind>]
        )
        let samples = try await descriptor.result(for: store)
        return HealthConvert.drafts(from: samples, type: type)
    }

    /// Phone and Watch both record steps, distance, and energy. Summing the raw samples
    /// counts the same walk twice. Daily totals come from HealthKit statistics, which deduplicates.
    private func dailySums(_ type: HealthReadType, from start: Date, to end: Date) async -> [Date: Double]? {
        guard let quantity = type.sampleType as? HKQuantityType, let unit = type.unit, start < end else {
            return nil
        }
        let scale = type.scale
        return await withCheckedContinuation { continuation in
            let gate = HealthResume()
            let box = HealthQueryBox()
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let anchor = HealthDay.start(of: start)
            let query = HKStatisticsCollectionQuery(
                quantityType: quantity,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, results, error in
                box.query = nil
                gate.run {
                    if error != nil {
                        continuation.resume(returning: nil)
                        return
                    }
                    var values: [Date: Double] = [:]
                    results?.enumerateStatistics(from: start, to: end) { statistics, _ in
                        guard let sum = statistics.sumQuantity(), sum.is(compatibleWith: unit) else { return }
                        let scaled = sum.doubleValue(for: unit) * scale
                        if scaled.isFinite {
                            values[HealthDay.start(of: statistics.startDate)] = scaled
                        }
                    }
                    continuation.resume(returning: values)
                }
            }
            box.query = query
            store.execute(query)
        }
    }

    private func storeStepJournal(_ sums: [Date: Double]) -> Int {
        guard let context = container?.mainContext else { return 0 }
        let days = sums.compactMap { day, value -> StepDay? in
            guard value.isFinite, value > 0 else { return nil }
            let count = Int(value.rounded())
            guard count > 0 else { return nil }
            return StepDay(day: HealthDay.start(of: day), count: count)
        }
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
            return days.count
        } catch {
            return 0
        }
    }

    /// The first query is limited to the last 365 days. Later queries keep that same start
    /// so the saved anchor still matches the predicate.
    private func windowStart(for typeRaw: String) -> Date {
        let key = "health.sync.window.\(typeRaw)"
        if let stored = UserDefaults.standard.object(forKey: key) as? Date {
            return stored
        }
        let start = Calendar.current.date(byAdding: .day, value: -365, to: HealthDay.start(of: Date()))
            ?? Date().addingTimeInterval(-365 * 86_400)
        UserDefaults.standard.set(start, forKey: key)
        return start
    }
}
