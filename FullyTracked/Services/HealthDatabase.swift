import Foundation
import SwiftData

/// SwiftData writes for HealthKit sync. Each call builds its own `ModelContext`
/// so the view context stays free for journal edits.
enum HealthDatabase {
    static func readAnchor(container: ModelContainer, typeRaw: String) throws -> Data? {
        let context = makeContext(container)
        let rows = try anchors(typeRaw: typeRaw, context: context)
        return rows.max { $0.updatedAt < $1.updatedAt }?.anchorData
    }

    static func count(container: ModelContainer) throws -> Int {
        let context = makeContext(container)
        return try context.fetchCount(FetchDescriptor<HealthSample>())
    }

    static func apply(
        container: ModelContainer,
        drafts: [HealthDraft],
        deleted: [UUID]
    ) throws -> [String: [Date]] {
        var affected: [String: Set<Date>] = [:]
        let context = makeContext(container)
        let rows = deduped(drafts)
        let live = Set(rows.map(\.hkUUID))
        try remove(uuids: deleted.filter { !live.contains($0) }, context: context, affected: &affected)
        let grouped = Dictionary(grouping: rows, by: \.typeRaw)
        for (typeRaw, group) in grouped {
            if group.count <= 800 {
                try upsertSmall(group, context: context, affected: &affected)
            } else {
                try upsertLarge(typeRaw: typeRaw, drafts: group, context: context, affected: &affected)
            }
        }
        try context.save()
        return affected.mapValues { Array($0) }
    }

    static func recompute(
        container: ModelContainer,
        typeRaw: String,
        days: [Date],
        aggregate: HealthAggregate
    ) throws {
        let uniqueDays = Array(Set(days.map { HealthDay.start(of: $0) }))
        guard !uniqueDays.isEmpty else { return }
        let context = makeContext(container)
        let samples = try samples(typeRaw: typeRaw, days: uniqueDays, context: context)
        let grouped = Dictionary(grouping: samples, by: { HealthDay.start(of: $0.day) })
        for day in uniqueDays {
            let rows = grouped[day] ?? []
            if rows.isEmpty {
                try deleteRollups(typeRaw: typeRaw, day: day, context: context)
            } else {
                try writeAggregate(
                    typeRaw: typeRaw,
                    day: day,
                    samples: rows,
                    aggregate: aggregate,
                    context: context
                )
            }
        }
        try context.save()
    }

    static func recomputeSleep(container: ModelContainer, days: [Date]) throws {
        let uniqueDays = Array(Set(days.map { HealthDay.start(of: $0) }))
        guard !uniqueDays.isEmpty else { return }
        let context = makeContext(container)
        let samples = try samples(typeRaw: "sleepAnalysis", days: uniqueDays, context: context)
        let grouped = Dictionary(grouping: samples, by: { HealthDay.start(of: $0.day) })
        for day in uniqueDays {
            let rows = grouped[day] ?? []
            var totals: [String: (hours: Double, count: Int)] = [:]
            for sample in rows {
                let key = HealthSleep.rollupKey(for: sample.categoryValue ?? -1)
                var entry = totals[key] ?? (0, 0)
                entry.hours += sample.value
                entry.count += 1
                totals[key] = entry
            }
            let existing = try rollups(on: day, context: context).filter {
                $0.typeRaw == "sleepAnalysis" || $0.typeRaw.hasPrefix("sleepAnalysis.")
            }
            var kept = Set<String>()
            for (key, total) in totals where total.hours > 0 && total.hours.isFinite {
                kept.insert(key)
                try upsertRollup(
                    typeRaw: key,
                    day: day,
                    sum: total.hours,
                    avg: total.hours,
                    min: total.hours,
                    max: total.hours,
                    count: total.count,
                    unitRaw: "h",
                    context: context
                )
            }
            for row in existing where !kept.contains(row.typeRaw) {
                context.delete(row)
            }
        }
        try context.save()
    }

    static func replaceSums(
        container: ModelContainer,
        typeRaw: String,
        unit: String,
        values: [Date: Double],
        windowStart: Date
    ) throws {
        let context = makeContext(container)
        let existing = try rollups(typeRaw: typeRaw, from: windowStart, context: context)
        var byDay: [Date: [HealthDailyRollup]] = [:]
        for row in existing {
            byDay[HealthDay.start(of: row.day), default: []].append(row)
        }
        var seen = Set<Date>()
        for (rawDay, value) in values where value.isFinite {
            let day = HealthDay.start(of: rawDay)
            seen.insert(day)
            let matches = byDay[day] ?? []
            if let first = matches.first {
                first.sum = value
                first.avg = value
                first.min = value
                first.max = value
                first.count = max(first.count, 1)
                first.unitRaw = unit
                first.updatedAt = Date()
                for extra in matches.dropFirst() {
                    context.delete(extra)
                }
            } else {
                context.insert(HealthDailyRollup(
                    typeRaw: typeRaw,
                    day: day,
                    sum: value,
                    avg: value,
                    min: value,
                    max: value,
                    count: 1,
                    unitRaw: unit
                ))
            }
        }
        for (day, matches) in byDay where !seen.contains(day) {
            for row in matches {
                context.delete(row)
            }
        }
        try context.save()
    }

    static func replaceStateOfMind(
        container: ModelContainer,
        drafts: [HealthDraft],
        windowStart: Date
    ) throws {
        let context = makeContext(container)
        let key = "stateOfMind"
        let lower = windowStart
        let descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { sample in
                sample.typeRaw == key && sample.startDate >= lower
            }
        )
        let existing = try context.fetch(descriptor)
        let live = Set(drafts.map(\.hkUUID))
        var days = Set<Date>()
        for sample in existing {
            days.insert(HealthDay.start(of: sample.day))
            if let identifier = sample.hkUUID, live.contains(identifier) {
                continue
            }
            context.delete(sample)
        }
        var affected: [String: Set<Date>] = [:]
        try upsertSmall(deduped(drafts), context: context, affected: &affected)
        for day in affected[key] ?? [] {
            days.insert(day)
        }
        try context.save()
        let savedDays = Array(days)
        guard !savedDays.isEmpty else { return }
        try recompute(container: container, typeRaw: key, days: savedDays, aggregate: .latest)
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.undoManager = nil
        return context
    }

    private static func deduped(_ drafts: [HealthDraft]) -> [HealthDraft] {
        var byID: [UUID: HealthDraft] = [:]
        var order: [UUID] = []
        for draft in drafts {
            if byID[draft.hkUUID] == nil {
                order.append(draft.hkUUID)
            }
            byID[draft.hkUUID] = draft
        }
        return order.compactMap { byID[$0] }
    }

    private static func remove(
        uuids: [UUID],
        context: ModelContext,
        affected: inout [String: Set<Date>]
    ) throws {
        for uuid in Set(uuids) {
            for sample in try samples(uuid: uuid, context: context) {
                affected[sample.typeRaw, default: []].insert(HealthDay.start(of: sample.day))
                context.delete(sample)
            }
        }
    }

    private static func upsertSmall(
        _ drafts: [HealthDraft],
        context: ModelContext,
        affected: inout [String: Set<Date>]
    ) throws {
        for draft in drafts {
            let matches = try samples(uuid: draft.hkUUID, context: context)
            if let sample = matches.first {
                affected[sample.typeRaw, default: []].insert(HealthDay.start(of: sample.day))
                fill(sample, with: draft)
                for extra in matches.dropFirst() {
                    affected[extra.typeRaw, default: []].insert(HealthDay.start(of: extra.day))
                    context.delete(extra)
                }
            } else {
                context.insert(makeSample(draft))
            }
            affected[draft.typeRaw, default: []].insert(draft.day)
        }
    }

    private static func upsertLarge(
        typeRaw: String,
        drafts: [HealthDraft],
        context: ModelContext,
        affected: inout [String: Set<Date>]
    ) throws {
        let key = typeRaw
        let existing = try context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { sample in
                sample.typeRaw == key
            }
        ))
        var byID: [UUID: HealthSample] = [:]
        for sample in existing {
            if let identifier = sample.hkUUID {
                byID[identifier] = sample
            }
        }
        var inserted = 0
        for draft in drafts {
            if let sample = byID[draft.hkUUID] {
                affected[sample.typeRaw, default: []].insert(HealthDay.start(of: sample.day))
                fill(sample, with: draft)
            } else {
                let sample = makeSample(draft)
                context.insert(sample)
                byID[draft.hkUUID] = sample
                inserted += 1
                if inserted.isMultiple(of: 1_500) {
                    try context.save()
                }
            }
            affected[draft.typeRaw, default: []].insert(draft.day)
        }
    }

    static func storeAnchor(container: ModelContainer, typeRaw: String, data: Data?) throws {
        guard let data else { return }
        let context = makeContext(container)
        try writeAnchor(typeRaw: typeRaw, data: data, context: context)
        try context.save()
    }

    private static func samples(uuid: UUID, context: ModelContext) throws -> [HealthSample] {
        let identifier: UUID? = uuid
        var descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { sample in
                sample.hkUUID == identifier
            }
        )
        descriptor.fetchLimit = 4
        return try context.fetch(descriptor)
    }

    private static func samples(typeRaw: String, days: [Date], context: ModelContext) throws -> [HealthSample] {
        guard let first = days.min(), let last = days.max() else { return [] }
        let key = typeRaw
        let lower = HealthDay.start(of: first)
        let upper = HealthDay.next(HealthDay.start(of: last))
        return try context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { sample in
                sample.typeRaw == key && sample.day >= lower && sample.day < upper
            }
        ))
    }

    private static func anchors(typeRaw: String, context: ModelContext) throws -> [HealthSyncAnchor] {
        let key = typeRaw
        return try context.fetch(FetchDescriptor<HealthSyncAnchor>(
            predicate: #Predicate<HealthSyncAnchor> { anchor in
                anchor.typeRaw == key
            }
        ))
    }

    private static func writeAnchor(typeRaw: String, data: Data?, context: ModelContext) throws {
        let rows = try anchors(typeRaw: typeRaw, context: context)
        if let first = rows.max(by: { $0.updatedAt < $1.updatedAt }) {
            first.anchorData = data
            first.updatedAt = Date()
            for extra in rows where extra !== first {
                context.delete(extra)
            }
        } else {
            context.insert(HealthSyncAnchor(typeRaw: typeRaw, anchorData: data))
        }
    }

    private static func writeAggregate(
        typeRaw: String,
        day: Date,
        samples: [HealthSample],
        aggregate: HealthAggregate,
        context: ModelContext
    ) throws {
        let values = samples.map(\.value).filter(\.isFinite)
        guard !values.isEmpty else {
            try deleteRollups(typeRaw: typeRaw, day: day, context: context)
            return
        }
        let sum = values.reduce(0, +)
        let count = values.count
        let average = sum / Double(count)
        let lowest = values.min()
        let highest = values.max()
        let unit = samples.last?.unitRaw ?? ""
        switch aggregate {
        case .sum, .average:
            try upsertRollup(
                typeRaw: typeRaw,
                day: day,
                sum: sum,
                avg: average,
                min: lowest,
                max: highest,
                count: count,
                unitRaw: unit,
                context: context
            )
        case .latest:
            let latest = samples.max { $0.endDate < $1.endDate }?.value
            try upsertRollup(
                typeRaw: typeRaw,
                day: day,
                sum: nil,
                avg: latest,
                min: lowest,
                max: highest,
                count: count,
                unitRaw: unit,
                context: context
            )
        }
    }

    private static func upsertRollup(
        typeRaw: String,
        day: Date,
        sum: Double?,
        avg: Double?,
        min: Double?,
        max: Double?,
        count: Int,
        unitRaw: String,
        context: ModelContext
    ) throws {
        let matches = try rollups(typeRaw: typeRaw, day: day, context: context)
        let row: HealthDailyRollup
        if let first = matches.first {
            row = first
            for extra in matches.dropFirst() {
                context.delete(extra)
            }
        } else {
            row = HealthDailyRollup(
                typeRaw: typeRaw,
                day: day,
                count: count,
                unitRaw: unitRaw
            )
            context.insert(row)
        }
        row.sum = sum
        row.avg = avg
        row.min = min
        row.max = max
        row.count = count
        row.unitRaw = unitRaw
        row.updatedAt = Date()
    }

    private static func deleteRollups(typeRaw: String, day: Date, context: ModelContext) throws {
        for row in try rollups(typeRaw: typeRaw, day: day, context: context) {
            context.delete(row)
        }
    }

    private static func rollups(typeRaw: String, day: Date, context: ModelContext) throws -> [HealthDailyRollup] {
        let key = typeRaw
        let lower = HealthDay.start(of: day)
        let upper = HealthDay.next(lower)
        return try context.fetch(FetchDescriptor<HealthDailyRollup>(
            predicate: #Predicate<HealthDailyRollup> { row in
                row.typeRaw == key && row.day >= lower && row.day < upper
            }
        ))
    }

    private static func rollups(on day: Date, context: ModelContext) throws -> [HealthDailyRollup] {
        let lower = HealthDay.start(of: day)
        let upper = HealthDay.next(lower)
        return try context.fetch(FetchDescriptor<HealthDailyRollup>(
            predicate: #Predicate<HealthDailyRollup> { row in
                row.day >= lower && row.day < upper
            }
        ))
    }

    private static func rollups(
        typeRaw: String,
        from windowStart: Date,
        context: ModelContext
    ) throws -> [HealthDailyRollup] {
        let key = typeRaw
        let lower = windowStart
        return try context.fetch(FetchDescriptor<HealthDailyRollup>(
            predicate: #Predicate<HealthDailyRollup> { row in
                row.typeRaw == key && row.day >= lower
            }
        ))
    }

    private static func fill(_ sample: HealthSample, with draft: HealthDraft) {
        sample.typeRaw = draft.typeRaw
        sample.startDate = draft.startDate
        sample.endDate = draft.endDate
        sample.value = draft.value
        sample.unitRaw = draft.unitRaw
        sample.categoryValue = draft.categoryValue
        sample.sourceName = draft.sourceName
        sample.sourceBundle = draft.sourceBundle
        sample.hkUUID = draft.hkUUID
        sample.day = draft.day
        sample.savedAt = Date()
        sample.labels = draft.labels
    }

    private static func makeSample(_ draft: HealthDraft) -> HealthSample {
        HealthSample(
            typeRaw: draft.typeRaw,
            startDate: draft.startDate,
            endDate: draft.endDate,
            value: draft.value,
            unitRaw: draft.unitRaw,
            categoryValue: draft.categoryValue,
            sourceName: draft.sourceName,
            sourceBundle: draft.sourceBundle,
            hkUUID: draft.hkUUID,
            day: draft.day,
            labels: draft.labels
        )
    }
}
