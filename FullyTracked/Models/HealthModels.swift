import Foundation
import SwiftData

@Model
final class HealthSample {
    #Index<HealthSample>([\.typeRaw, \.startDate], [\.day])
    #Unique<HealthSample>([\.hkUUID])

    var id: UUID = UUID()
    var typeRaw: String = ""
    var startDate: Date = Date()
    var endDate: Date = Date()
    var value: Double = 0
    var unitRaw: String = ""
    var categoryValue: Int? = nil
    var sourceName: String? = nil
    var sourceBundle: String? = nil
    var hkUUID: UUID? = nil
    var day: Date = Date()
    var savedAt: Date = Date()
    /// State of Mind label names. Empty for every other sample.
    var labels: [String]? = nil

    init(
        id: UUID = UUID(),
        typeRaw: String,
        startDate: Date,
        endDate: Date,
        value: Double,
        unitRaw: String,
        categoryValue: Int? = nil,
        sourceName: String? = nil,
        sourceBundle: String? = nil,
        hkUUID: UUID? = nil,
        day: Date,
        savedAt: Date = Date(),
        labels: [String]? = nil
    ) {
        self.id = id
        self.typeRaw = typeRaw
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unitRaw = unitRaw
        self.categoryValue = categoryValue
        self.sourceName = sourceName
        self.sourceBundle = sourceBundle
        self.hkUUID = hkUUID
        self.day = day
        self.savedAt = savedAt
        self.labels = labels
    }
}

@Model
final class HealthDailyRollup {
    var typeRaw: String = ""
    var day: Date = Date()
    var sum: Double? = nil
    var avg: Double? = nil
    var min: Double? = nil
    var max: Double? = nil
    var count: Int = 0
    var unitRaw: String = ""
    var updatedAt: Date = Date()

    init(
        typeRaw: String,
        day: Date,
        sum: Double? = nil,
        avg: Double? = nil,
        min: Double? = nil,
        max: Double? = nil,
        count: Int,
        unitRaw: String,
        updatedAt: Date = Date()
    ) {
        self.typeRaw = typeRaw
        self.day = day
        self.sum = sum
        self.avg = avg
        self.min = min
        self.max = max
        self.count = count
        self.unitRaw = unitRaw
        self.updatedAt = updatedAt
    }
}

@Model
final class HealthSyncAnchor {
    var typeRaw: String = ""
    var anchorData: Data? = nil
    var updatedAt: Date = Date()

    init(typeRaw: String, anchorData: Data? = nil, updatedAt: Date = Date()) {
        self.typeRaw = typeRaw
        self.anchorData = anchorData
        self.updatedAt = updatedAt
    }
}
