import Foundation
import HealthKit

/// Writes journal entries back into Apple Health on this device.
/// Each sample's external id is the journal id plus the type, so a later save replaces the same rows.
@MainActor
enum HealthWriter {
    private static let store = HKHealthStore()

    struct MealNutrition: Sendable {
        var calories: Double?
        var protein: Double?
        var carbohydrates: Double?
        var totalFat: Double?
        var sugar: Double?
        var sodium: Double?
        var fiber: Double?
    }

    static func writeHydration(
        entryID: UUID,
        occurredAt: Date,
        drinkName: String,
        amountMl: Double?,
        strength: String?
    ) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        var plans: [QuantityPlan] = []
        if HealthWriteKey.enabled(HealthWriteKey.water) {
            let milliliters = positive(amountMl)?.rounded()
            plans.append(QuantityPlan(
                identifier: .dietaryWater,
                marker: "dietaryWater",
                unit: HealthUnits.milliliter,
                value: milliliters
            ))
        }
        if HealthWriteKey.enabled(HealthWriteKey.caffeine) {
            plans.append(QuantityPlan(
                identifier: .dietaryCaffeine,
                marker: "dietaryCaffeine",
                unit: HealthUnits.milligram,
                value: caffeineMilligrams(drinkName: drinkName, amountMl: amountMl, strength: strength)
            ))
        }
        guard plans.contains(where: { $0.value != nil }) else { return }
        await replaceQuantities(plans, entryID: entryID, occurredAt: occurredAt)
    }

    static func writeMeal(entryID: UUID, occurredAt: Date, nutrition: MealNutrition) async {
        guard HealthWriteKey.enabled(HealthWriteKey.nutrition) else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let plans = [
            QuantityPlan(identifier: .dietaryEnergyConsumed, marker: "dietaryEnergyConsumed", unit: HealthUnits.kilocalorie, value: positive(nutrition.calories)),
            QuantityPlan(identifier: .dietaryProtein, marker: "dietaryProtein", unit: HealthUnits.gram, value: positive(nutrition.protein)),
            QuantityPlan(identifier: .dietaryCarbohydrates, marker: "dietaryCarbohydrates", unit: HealthUnits.gram, value: positive(nutrition.carbohydrates)),
            QuantityPlan(identifier: .dietaryFatTotal, marker: "dietaryFatTotal", unit: HealthUnits.gram, value: positive(nutrition.totalFat)),
            QuantityPlan(identifier: .dietarySugar, marker: "dietarySugar", unit: HealthUnits.gram, value: positive(nutrition.sugar)),
            QuantityPlan(identifier: .dietarySodium, marker: "dietarySodium", unit: HealthUnits.milligram, value: positive(nutrition.sodium)),
            QuantityPlan(identifier: .dietaryFiber, marker: "dietaryFiber", unit: HealthUnits.gram, value: positive(nutrition.fiber)),
        ]
        guard plans.contains(where: { $0.value != nil }) else { return }
        await replaceQuantities(plans, entryID: entryID, occurredAt: occurredAt)
    }

    static func writeSleep(entryID: UUID, occurredAt: Date, hours: Double) async {
        guard HealthWriteKey.enabled(HealthWriteKey.sleep) else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard hours.isFinite, hours >= 0.1, hours <= 24 else { return }
        let type = HKCategoryType(.sleepAnalysis)
        guard await authorize([type]) else { return }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let end = occurredAt
        let start = occurredAt.addingTimeInterval(-hours * 3600)
        guard start < end else { return }
        let overlap = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        guard let overlapping = await samples(type: type, predicate: overlap) else { return }
        let bundle = Bundle.main.bundleIdentifier
        let blocked = overlapping.contains { sample in
            sample.sourceRevision.source.bundleIdentifier != bundle
        }
        if blocked {
            return
        }
        let marker = externalID(entryID, "sleepAnalysis")
        let owned = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [marker])
        guard let stale = await samples(type: type, predicate: owned) else { return }
        let sample = HKCategorySample(
            type: type,
            value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            start: start,
            end: end,
            metadata: [HKMetadataKeyExternalUUID: marker]
        )
        await save([sample], thenDelete: stale)
    }

    static func writeMood(entryID: UUID, occurredAt: Date, score: Int, emotions: [String]) async {
        guard HealthWriteKey.enabled(HealthWriteKey.mood) else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard (1...10).contains(score) else { return }
        let type = HKSampleType.stateOfMindType()
        guard await authorize([type]) else { return }
        guard store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let valence = min(1, max(-1, (Double(score) - 5.5) / 4.5))
        let marker = externalID(entryID, "stateOfMind")
        let owned = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [marker])
        guard let stale = await samples(type: type, predicate: owned) else { return }
        let sample = HKStateOfMind(
            date: occurredAt,
            kind: .momentaryEmotion,
            valence: valence,
            labels: HealthMoodLabels.labels(matching: emotions),
            associations: [HKStateOfMind.Association](),
            metadata: [HKMetadataKeyExternalUUID: marker]
        )
        await save([sample], thenDelete: stale)
    }

    /// Coffee is 60 / 95 / 140 mg per 8 oz for light / medium / strong. Tea is 40 and energy drinks are 80, scaled by volume.
    static func caffeineMilligrams(drinkName: String, amountMl: Double?, strength: String?) -> Double? {
        guard let amountMl = positive(amountMl) else { return nil }
        let name = drinkName.lowercased()
        if name.contains("decaf") {
            return nil
        }
        let eightOunces = 8 * JournalCatalog.ouncesToMilliliters
        guard eightOunces > 0 else { return nil }
        let scale = amountMl / eightOunces
        let perEight: Double
        if name.contains("coffee") {
            switch strength?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "light":
                perEight = 60
            case "strong":
                perEight = 140
            default:
                perEight = 95
            }
        } else if name.contains("tea") {
            perEight = 40
        } else if name.contains("energy") {
            perEight = 80
        } else {
            return nil
        }
        let milligrams = (perEight * scale).rounded()
        guard milligrams.isFinite, milligrams > 0 else { return nil }
        return milligrams
    }

    private struct QuantityPlan {
        var identifier: HKQuantityTypeIdentifier
        var marker: String
        var unit: HKUnit
        var value: Double?
    }

    private static func replaceQuantities(_ plans: [QuantityPlan], entryID: UUID, occurredAt: Date) async {
        let shareTypes = Set(plans.map { HKQuantityType($0.identifier) as HKSampleType })
        guard await authorize(shareTypes) else { return }
        var fresh: [HKObject] = []
        var stale: [HKObject] = []
        for plan in plans {
            let type = HKQuantityType(plan.identifier)
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            let marker = externalID(entryID, plan.marker)
            let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [marker])
            guard let existing = await samples(type: type, predicate: predicate) else { return }
            stale.append(contentsOf: existing)
            guard let value = plan.value, value.isFinite, value >= 0 else { continue }
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: plan.unit, doubleValue: value),
                start: occurredAt,
                end: occurredAt,
                metadata: [HKMetadataKeyExternalUUID: marker]
            )
            fresh.append(sample)
        }
        guard !fresh.isEmpty || !stale.isEmpty else { return }
        await save(fresh, thenDelete: stale)
    }

    private static func authorize(_ types: Set<HKSampleType>) async -> Bool {
        guard !types.isEmpty else { return false }
        let requested = await withCheckedContinuation { continuation in
            let gate = HealthResume()
            store.requestAuthorization(toShare: types, read: nil) { success, _ in
                gate.run {
                    continuation.resume(returning: success)
                }
            }
        }
        guard requested else { return false }
        return types.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    private static func samples(type: HKSampleType, predicate: NSPredicate) async -> [HKSample]? {
        await withCheckedContinuation { continuation in
            let gate = HealthResume()
            let box = HealthQueryBox()
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                box.query = nil
                gate.run {
                    if error != nil {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: samples ?? [])
                    }
                }
            }
            box.query = query
            store.execute(query)
        }
    }

    private static func save(_ fresh: [HKObject], thenDelete stale: [HKObject]) async {
        do {
            if !fresh.isEmpty {
                try await store.save(fresh)
            }
            if !stale.isEmpty {
                try? await store.delete(stale)
            }
        } catch {
            return
        }
    }

    private static func externalID(_ entryID: UUID, _ marker: String) -> String {
        "\(entryID.uuidString)#\(marker)"
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
