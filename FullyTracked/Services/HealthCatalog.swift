import Foundation
import HealthKit

enum HealthGroup: String, CaseIterable, Identifiable {
    case activity
    case heart
    case body
    case sleep
    case vitals
    case nutrition
    case hearing
    case workouts
    case mindfulness
    case mood
    case symptoms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: "Activity"
        case .heart: "Heart"
        case .body: "Body"
        case .sleep: "Sleep"
        case .vitals: "Vitals"
        case .nutrition: "Nutrition"
        case .hearing: "Hearing"
        case .workouts: "Workouts"
        case .mindfulness: "Mindfulness"
        case .mood: "Mood"
        case .symptoms: "Symptoms"
        }
    }
}

enum HealthAggregate: Sendable {
    case sum
    case average
    case latest
}

enum HealthKind: Sendable {
    case quantity
    case sleep
    case mindful
    case standHour
    case event
    case severity
    case appetite
    case menstrual
    case workout
    case workoutEnergy
    case stateOfMind
}

enum HealthSyncStyle: Sendable {
    case anchored
    case stateOfMind
    case displayOnly
}

struct HealthReadType: Identifiable {
    var typeRaw: String
    var title: String
    var group: HealthGroup
    var unitLabel: String
    var aggregate: HealthAggregate
    var kind: HealthKind
    var sampleType: HKSampleType
    var unit: HKUnit?
    var scale: Double
    var sync: HealthSyncStyle

    var id: String { typeRaw }

    var prefersStatistics: Bool {
        kind == .quantity && aggregate == .sum
    }
}

struct HealthDraft: Sendable {
    var typeRaw: String
    var startDate: Date
    var endDate: Date
    var value: Double
    var unitRaw: String
    var categoryValue: Int?
    var sourceName: String?
    var sourceBundle: String?
    var hkUUID: UUID
    var day: Date
    var labels: [String]?
}

enum HealthDay {
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func next(_ day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    static func starts(count: Int, now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let today = start(of: now, calendar: calendar)
        let days = count == 30 ? 30 : 7
        return (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - (days - 1), to: today)
        }
    }
}

enum HealthIdentity {
    /// Stable id for the energy row of a workout. The workout keeps HealthKit's UUID,
    /// and `hkUUID` is unique, so the second row cannot reuse it.
    static func energyID(for workoutID: UUID) -> UUID {
        var bytes = workoutID.uuid
        bytes.0 ^= 0xA5
        bytes.15 ^= 0x5A
        return UUID(uuid: bytes)
    }
}

enum HealthSleep {
    static let inBed = "sleepAnalysis.inBed"
    static let awake = "sleepAnalysis.awake"
    static let asleep = "sleepAnalysis.asleep"
    static let core = "sleepAnalysis.core"
    static let deep = "sleepAnalysis.deep"
    static let rem = "sleepAnalysis.rem"

    static func rollupKey(for category: Int) -> String {
        switch category {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: inBed
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: asleep
        case HKCategoryValueSleepAnalysis.awake.rawValue: awake
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: core
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: deep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: rem
        default: "sleepAnalysis.\(category)"
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case inBed: "In bed"
        case awake: "Awake"
        case asleep: "Asleep"
        case core: "Core"
        case deep: "Deep"
        case rem: "REM"
        default: "Sleep"
        }
    }

    /// Stages that can be drawn together without counting one night twice.
    static func chartKeys(present: Set<String>) -> [String] {
        let staged = [core, deep, rem].filter { present.contains($0) }
        var keys: [String] = []
        if present.contains(awake) {
            keys.append(awake)
        }
        if staged.isEmpty {
            if present.contains(asleep) {
                keys.append(asleep)
            }
        } else {
            keys.append(contentsOf: staged)
        }
        if keys.isEmpty, present.contains(inBed) {
            keys.append(inBed)
        }
        return keys
    }

    static func summaryKeys(present: Set<String>) -> [String] {
        let charted = chartKeys(present: present)
        let asleepKeys = charted.filter { $0 != awake && $0 != inBed }
        return asleepKeys.isEmpty ? charted : asleepKeys
    }
}

enum HealthWriteKey {
    static let water = "health.write.water"
    static let caffeine = "health.write.caffeine"
    static let nutrition = "health.write.nutrition"
    static let sleep = "health.write.sleep"
    static let mood = "health.write.mood"

    static func enabled(_ key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: key)
    }
}

enum HealthMoodLabels {
    static let pairs: [(HKStateOfMind.Label, String)] = [
        (.amazed, "amazed"),
        (.amused, "amused"),
        (.angry, "angry"),
        (.anxious, "anxious"),
        (.ashamed, "ashamed"),
        (.brave, "brave"),
        (.calm, "calm"),
        (.content, "content"),
        (.disappointed, "disappointed"),
        (.discouraged, "discouraged"),
        (.disgusted, "disgusted"),
        (.embarrassed, "embarrassed"),
        (.excited, "excited"),
        (.frustrated, "frustrated"),
        (.grateful, "grateful"),
        (.guilty, "guilty"),
        (.happy, "happy"),
        (.hopeless, "hopeless"),
        (.irritated, "irritated"),
        (.jealous, "jealous"),
        (.joyful, "joyful"),
        (.lonely, "lonely"),
        (.passionate, "passionate"),
        (.peaceful, "peaceful"),
        (.proud, "proud"),
        (.relieved, "relieved"),
        (.sad, "sad"),
        (.scared, "scared"),
        (.stressed, "stressed"),
        (.surprised, "surprised"),
        (.worried, "worried"),
        (.annoyed, "annoyed"),
        (.confident, "confident"),
        (.drained, "drained"),
        (.hopeful, "hopeful"),
        (.indifferent, "indifferent"),
        (.overwhelmed, "overwhelmed"),
        (.satisfied, "satisfied"),
    ]

    static func names(for labels: [HKStateOfMind.Label]) -> [String]? {
        let known = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, $0.1) })
        var seen = Set<String>()
        var names: [String] = []
        for label in labels {
            let name = known[label] ?? "label-\(label.rawValue)"
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names.isEmpty ? nil : names
    }

    static func labels(matching emotions: [String]) -> [HKStateOfMind.Label] {
        let known = Dictionary(uniqueKeysWithValues: pairs.map { ($0.1, $0.0) })
        var seen = Set<String>()
        var labels: [HKStateOfMind.Label] = []
        for emotion in emotions {
            let key = emotion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted, let label = known[key] else { continue }
            labels.append(label)
        }
        return labels
    }
}

enum HealthUnits {
    static let count = HKUnit.count()
    static let meter = HKUnit.meter()
    static let kilocalorie = HKUnit.kilocalorie()
    static let minute = HKUnit.minute()
    static let beatsPerMinute = HKUnit(from: "count/min")
    static let milliseconds = HKUnit.secondUnit(with: .milli)
    static let percent = HKUnit.percent()
    static let celsius = HKUnit.degreeCelsius()
    static let millimetersOfMercury = HKUnit.millimeterOfMercury()
    static let milligramsPerDeciliter = HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
    static let kilogram = HKUnit.gramUnit(with: .kilo)
    static let gram = HKUnit.gram()
    static let milligram = HKUnit.gramUnit(with: .milli)
    static let milliliter = HKUnit.literUnit(with: .milli)
    static let vo2 = HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: HKUnit.minute()))
    static let metersPerSecond = HKUnit.meter().unitDivided(by: HKUnit.second())
    static let decibel = HKUnit.decibelAWeightedSoundPressureLevel()
}

enum HealthCatalog {
    static let types: [HealthReadType] = makeTypes()
    static let byRaw: [String: HealthReadType] = Dictionary(uniqueKeysWithValues: types.map { ($0.typeRaw, $0) })

    static var synced: [HealthReadType] {
        types.filter { $0.sync != .displayOnly }
    }

    static var readObjectTypes: Set<HKObjectType> {
        Set(synced.map(\.sampleType))
    }

    static var shareTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        let quantities: [HKQuantityTypeIdentifier] = [
            .dietaryWater,
            .dietaryCaffeine,
            .dietaryEnergyConsumed,
            .dietaryProtein,
            .dietaryCarbohydrates,
            .dietaryFatTotal,
            .dietarySugar,
            .dietarySodium,
            .dietaryFiber,
        ]
        for identifier in quantities {
            set.insert(HKQuantityType(identifier))
        }
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKSampleType.stateOfMindType())
        return set
    }

    static func value(_ rollup: HealthDailyRollup, aggregate: HealthAggregate) -> Double? {
        switch aggregate {
        case .sum:
            return rollup.sum
        case .average, .latest:
            return rollup.avg ?? rollup.sum
        }
    }

    static func format(_ value: Double, type: HealthReadType) -> String {
        if let word = categoryWord(kind: type.kind, value: value) {
            return word
        }
        return format(value, typeRaw: type.typeRaw, unit: type.unitLabel)
    }

    static func format(_ value: Double, typeRaw: String, unit: String) -> String {
        guard value.isFinite else { return "" }
        switch typeRaw {
        case "stepCount", "flightsClimbed", "numberOfAlcoholicBeverages", "numberOfTimesFallen":
            return grouped(value, unit: unit)
        case "distanceWalkingRunning":
            return String(format: "%.2f km", locale: Locale(identifier: "en_US_POSIX"), value)
        case "stateOfMind":
            return String(format: "%+.2f", locale: Locale(identifier: "en_US_POSIX"), value)
        case "bodyMass", "leanBodyMass":
            return String(format: "%.1f kg", locale: Locale(identifier: "en_US_POSIX"), value)
        case "bodyTemperature", "appleSleepingWristTemperature":
            return String(format: "%.1f °C", locale: Locale(identifier: "en_US_POSIX"), value)
        case "walkingSpeed":
            return String(format: "%.2f m/s", locale: Locale(identifier: "en_US_POSIX"), value)
        case "vo2Max":
            return String(format: "%.1f mL/kg·min", locale: Locale(identifier: "en_US_POSIX"), value)
        default:
            break
        }
        if unit == "%" {
            return String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        if unit == "h" {
            return String(format: "%.1f h", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        let shown: String
        if abs(value) >= 100 || value.rounded() == value {
            shown = grouped(value, unit: "")
        } else {
            shown = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return unit.isEmpty ? shown : "\(shown) \(unit)"
    }

    static func categoryWord(kind: HealthKind, value: Double) -> String? {
        let raw = Int(value.rounded())
        switch kind {
        case .severity:
            guard let severity = HKCategoryValueSeverity(rawValue: raw) else { return nil }
            switch severity {
            case .notPresent: return "None"
            case .mild: return "Mild"
            case .moderate: return "Moderate"
            case .severe: return "Severe"
            case .unspecified: return "Unspecified"
            @unknown default: return nil
            }
        case .appetite:
            guard let appetite = HKCategoryValueAppetiteChanges(rawValue: raw) else { return nil }
            switch appetite {
            case .noChange: return "No change"
            case .decreased: return "Decreased"
            case .increased: return "Increased"
            case .unspecified: return "Unspecified"
            @unknown default: return nil
            }
        case .menstrual:
            guard let flow = HKCategoryValueMenstrualFlow(rawValue: raw) else { return nil }
            switch flow {
            case .light: return "Light"
            case .medium: return "Medium"
            case .heavy: return "Heavy"
            case .none: return "None"
            case .unspecified: return "Unspecified"
            @unknown default: return nil
            }
        default:
            return nil
        }
    }

    private static func grouped(_ value: Double, unit: String) -> String {
        let number = Int(value.rounded()).formatted(.number.grouping(.automatic))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private static func makeTypes() -> [HealthReadType] {
        var rows: [HealthReadType] = []
        func add(_ row: HealthReadType) {
            rows.append(row)
        }
        func quantity(
            _ identifier: HKQuantityTypeIdentifier,
            raw: String,
            title: String,
            group: HealthGroup,
            unitLabel: String,
            aggregate: HealthAggregate,
            unit: HKUnit,
            scale: Double = 1
        ) {
            add(HealthReadType(
                typeRaw: raw,
                title: title,
                group: group,
                unitLabel: unitLabel,
                aggregate: aggregate,
                kind: .quantity,
                sampleType: HKQuantityType(identifier),
                unit: unit,
                scale: scale,
                sync: .anchored
            ))
        }
        func category(
            _ identifier: HKCategoryTypeIdentifier,
            raw: String,
            title: String,
            group: HealthGroup,
            unitLabel: String,
            aggregate: HealthAggregate,
            kind: HealthKind
        ) {
            add(HealthReadType(
                typeRaw: raw,
                title: title,
                group: group,
                unitLabel: unitLabel,
                aggregate: aggregate,
                kind: kind,
                sampleType: HKCategoryType(identifier),
                unit: nil,
                scale: 1,
                sync: .anchored
            ))
        }

        quantity(.stepCount, raw: "stepCount", title: "Steps", group: .activity, unitLabel: "steps", aggregate: .sum, unit: HealthUnits.count)
        quantity(.distanceWalkingRunning, raw: "distanceWalkingRunning", title: "Distance", group: .activity, unitLabel: "km", aggregate: .sum, unit: HealthUnits.meter, scale: 0.001)
        quantity(.flightsClimbed, raw: "flightsClimbed", title: "Flights", group: .activity, unitLabel: "flights", aggregate: .sum, unit: HealthUnits.count)
        quantity(.activeEnergyBurned, raw: "activeEnergyBurned", title: "Active energy", group: .activity, unitLabel: "kcal", aggregate: .sum, unit: HealthUnits.kilocalorie)
        quantity(.basalEnergyBurned, raw: "basalEnergyBurned", title: "Resting energy", group: .activity, unitLabel: "kcal", aggregate: .sum, unit: HealthUnits.kilocalorie)
        quantity(.appleExerciseTime, raw: "appleExerciseTime", title: "Exercise", group: .activity, unitLabel: "min", aggregate: .sum, unit: HealthUnits.minute)
        quantity(.appleStandTime, raw: "appleStandTime", title: "Stand time", group: .activity, unitLabel: "min", aggregate: .sum, unit: HealthUnits.minute)
        quantity(.timeInDaylight, raw: "timeInDaylight", title: "Daylight", group: .activity, unitLabel: "min", aggregate: .sum, unit: HealthUnits.minute)
        quantity(.appleWalkingSteadiness, raw: "appleWalkingSteadiness", title: "Walking steadiness", group: .activity, unitLabel: "%", aggregate: .latest, unit: HealthUnits.percent, scale: 100)
        quantity(.walkingSpeed, raw: "walkingSpeed", title: "Walking speed", group: .activity, unitLabel: "m/s", aggregate: .average, unit: HealthUnits.metersPerSecond)
        quantity(.walkingStepLength, raw: "walkingStepLength", title: "Step length", group: .activity, unitLabel: "cm", aggregate: .average, unit: HealthUnits.meter, scale: 100)
        quantity(.walkingAsymmetryPercentage, raw: "walkingAsymmetryPercentage", title: "Walking asymmetry", group: .activity, unitLabel: "%", aggregate: .average, unit: HealthUnits.percent, scale: 100)
        quantity(.walkingDoubleSupportPercentage, raw: "walkingDoubleSupportPercentage", title: "Double support", group: .activity, unitLabel: "%", aggregate: .average, unit: HealthUnits.percent, scale: 100)
        quantity(.vo2Max, raw: "vo2Max", title: "VO₂ max", group: .activity, unitLabel: "mL/kg·min", aggregate: .latest, unit: HealthUnits.vo2)
        quantity(.numberOfTimesFallen, raw: "numberOfTimesFallen", title: "Falls", group: .activity, unitLabel: "falls", aggregate: .sum, unit: HealthUnits.count)

        quantity(.heartRate, raw: "heartRate", title: "Heart rate", group: .heart, unitLabel: "bpm", aggregate: .average, unit: HealthUnits.beatsPerMinute)
        quantity(.restingHeartRate, raw: "restingHeartRate", title: "Resting heart rate", group: .heart, unitLabel: "bpm", aggregate: .average, unit: HealthUnits.beatsPerMinute)
        quantity(.walkingHeartRateAverage, raw: "walkingHeartRateAverage", title: "Walking heart rate", group: .heart, unitLabel: "bpm", aggregate: .average, unit: HealthUnits.beatsPerMinute)
        quantity(.heartRateVariabilitySDNN, raw: "heartRateVariabilitySDNN", title: "Heart rate variability", group: .heart, unitLabel: "ms", aggregate: .average, unit: HealthUnits.milliseconds)
        // Apple documents this sample as a count, not count/time. The count is the bpm drop.
        quantity(.heartRateRecoveryOneMinute, raw: "heartRateRecoveryOneMinute", title: "Heart rate recovery", group: .heart, unitLabel: "bpm", aggregate: .latest, unit: HealthUnits.count)
        category(.highHeartRateEvent, raw: "highHeartRateEvent", title: "High heart rate", group: .heart, unitLabel: "events", aggregate: .sum, kind: .event)
        category(.lowHeartRateEvent, raw: "lowHeartRateEvent", title: "Low heart rate", group: .heart, unitLabel: "events", aggregate: .sum, kind: .event)
        category(.irregularHeartRhythmEvent, raw: "irregularHeartRhythmEvent", title: "Irregular rhythm", group: .heart, unitLabel: "events", aggregate: .sum, kind: .event)

        quantity(.bodyMass, raw: "bodyMass", title: "Weight", group: .body, unitLabel: "kg", aggregate: .latest, unit: HealthUnits.kilogram)
        quantity(.bodyMassIndex, raw: "bodyMassIndex", title: "Body mass index", group: .body, unitLabel: "BMI", aggregate: .latest, unit: HealthUnits.count)
        quantity(.bodyFatPercentage, raw: "bodyFatPercentage", title: "Body fat", group: .body, unitLabel: "%", aggregate: .latest, unit: HealthUnits.percent, scale: 100)
        quantity(.leanBodyMass, raw: "leanBodyMass", title: "Lean body mass", group: .body, unitLabel: "kg", aggregate: .latest, unit: HealthUnits.kilogram)
        quantity(.height, raw: "height", title: "Height", group: .body, unitLabel: "cm", aggregate: .latest, unit: HealthUnits.meter, scale: 100)
        quantity(.waistCircumference, raw: "waistCircumference", title: "Waist", group: .body, unitLabel: "cm", aggregate: .latest, unit: HealthUnits.meter, scale: 100)
        category(.menstrualFlow, raw: "menstrualFlow", title: "Menstrual flow", group: .body, unitLabel: "", aggregate: .latest, kind: .menstrual)

        category(.sleepAnalysis, raw: "sleepAnalysis", title: "Sleep", group: .sleep, unitLabel: "h", aggregate: .sum, kind: .sleep)

        quantity(.respiratoryRate, raw: "respiratoryRate", title: "Respiratory rate", group: .vitals, unitLabel: "breaths/min", aggregate: .average, unit: HealthUnits.beatsPerMinute)
        quantity(.oxygenSaturation, raw: "oxygenSaturation", title: "Oxygen saturation", group: .vitals, unitLabel: "%", aggregate: .average, unit: HealthUnits.percent, scale: 100)
        quantity(.bodyTemperature, raw: "bodyTemperature", title: "Body temperature", group: .vitals, unitLabel: "°C", aggregate: .latest, unit: HealthUnits.celsius)
        quantity(.appleSleepingWristTemperature, raw: "appleSleepingWristTemperature", title: "Wrist temperature", group: .vitals, unitLabel: "°C", aggregate: .latest, unit: HealthUnits.celsius)
        quantity(.bloodPressureSystolic, raw: "bloodPressureSystolic", title: "Systolic pressure", group: .vitals, unitLabel: "mmHg", aggregate: .latest, unit: HealthUnits.millimetersOfMercury)
        quantity(.bloodPressureDiastolic, raw: "bloodPressureDiastolic", title: "Diastolic pressure", group: .vitals, unitLabel: "mmHg", aggregate: .latest, unit: HealthUnits.millimetersOfMercury)
        quantity(.bloodGlucose, raw: "bloodGlucose", title: "Blood glucose", group: .vitals, unitLabel: "mg/dL", aggregate: .latest, unit: HealthUnits.milligramsPerDeciliter)

        quantity(.dietaryWater, raw: "dietaryWater", title: "Water", group: .nutrition, unitLabel: "ml", aggregate: .sum, unit: HealthUnits.milliliter)
        quantity(.dietaryCaffeine, raw: "dietaryCaffeine", title: "Caffeine", group: .nutrition, unitLabel: "mg", aggregate: .sum, unit: HealthUnits.milligram)
        quantity(.dietaryEnergyConsumed, raw: "dietaryEnergyConsumed", title: "Energy consumed", group: .nutrition, unitLabel: "kcal", aggregate: .sum, unit: HealthUnits.kilocalorie)
        quantity(.dietaryProtein, raw: "dietaryProtein", title: "Protein", group: .nutrition, unitLabel: "g", aggregate: .sum, unit: HealthUnits.gram)
        quantity(.dietaryCarbohydrates, raw: "dietaryCarbohydrates", title: "Carbohydrates", group: .nutrition, unitLabel: "g", aggregate: .sum, unit: HealthUnits.gram)
        quantity(.dietaryFatTotal, raw: "dietaryFatTotal", title: "Fat", group: .nutrition, unitLabel: "g", aggregate: .sum, unit: HealthUnits.gram)
        quantity(.dietarySugar, raw: "dietarySugar", title: "Sugar", group: .nutrition, unitLabel: "g", aggregate: .sum, unit: HealthUnits.gram)
        quantity(.dietarySodium, raw: "dietarySodium", title: "Sodium", group: .nutrition, unitLabel: "mg", aggregate: .sum, unit: HealthUnits.milligram)
        quantity(.dietaryFiber, raw: "dietaryFiber", title: "Fiber", group: .nutrition, unitLabel: "g", aggregate: .sum, unit: HealthUnits.gram)
        quantity(.numberOfAlcoholicBeverages, raw: "numberOfAlcoholicBeverages", title: "Alcoholic drinks", group: .nutrition, unitLabel: "drinks", aggregate: .sum, unit: HealthUnits.count)

        quantity(.headphoneAudioExposure, raw: "headphoneAudioExposure", title: "Headphone audio", group: .hearing, unitLabel: "dB", aggregate: .average, unit: HealthUnits.decibel)
        quantity(.environmentalAudioExposure, raw: "environmentalAudioExposure", title: "Environmental audio", group: .hearing, unitLabel: "dB", aggregate: .average, unit: HealthUnits.decibel)
        category(.headphoneAudioExposureEvent, raw: "headphoneAudioExposureEvent", title: "Headphone exposure", group: .hearing, unitLabel: "events", aggregate: .sum, kind: .event)
        category(.environmentalAudioExposureEvent, raw: "environmentalAudioExposureEvent", title: "Environmental exposure", group: .hearing, unitLabel: "events", aggregate: .sum, kind: .event)

        add(HealthReadType(
            typeRaw: "workout",
            title: "Workouts",
            group: .workouts,
            unitLabel: "min",
            aggregate: .sum,
            kind: .workout,
            sampleType: HKObjectType.workoutType(),
            unit: nil,
            scale: 1,
            sync: .anchored
        ))
        add(HealthReadType(
            typeRaw: "workoutEnergy",
            title: "Workout energy",
            group: .workouts,
            unitLabel: "kcal",
            aggregate: .sum,
            kind: .workoutEnergy,
            sampleType: HKObjectType.workoutType(),
            unit: HealthUnits.kilocalorie,
            scale: 1,
            sync: .displayOnly
        ))

        category(.mindfulSession, raw: "mindfulSession", title: "Mindful minutes", group: .mindfulness, unitLabel: "min", aggregate: .sum, kind: .mindful)
        category(.appleStandHour, raw: "appleStandHour", title: "Stand hours", group: .activity, unitLabel: "h", aggregate: .sum, kind: .standHour)

        add(HealthReadType(
            typeRaw: "stateOfMind",
            title: "State of mind",
            group: .mood,
            unitLabel: "",
            aggregate: .latest,
            kind: .stateOfMind,
            sampleType: HKSampleType.stateOfMindType(),
            unit: nil,
            scale: 1,
            sync: .stateOfMind
        ))

        let symptoms: [(HKCategoryTypeIdentifier, String, String, HealthKind)] = [
            (.abdominalCramps, "abdominalCramps", "Abdominal cramps", .severity),
            (.acne, "acne", "Acne", .severity),
            (.appetiteChanges, "appetiteChanges", "Appetite", .appetite),
            (.bladderIncontinence, "bladderIncontinence", "Bladder incontinence", .severity),
            (.bloating, "bloating", "Bloating", .severity),
            (.breastPain, "breastPain", "Breast pain", .severity),
            (.chestTightnessOrPain, "chestTightnessOrPain", "Chest tightness", .severity),
            (.chills, "chills", "Chills", .severity),
            (.constipation, "constipation", "Constipation", .severity),
            (.coughing, "coughing", "Coughing", .severity),
            (.diarrhea, "diarrhea", "Diarrhea", .severity),
            (.dizziness, "dizziness", "Dizziness", .severity),
            (.drySkin, "drySkin", "Dry skin", .severity),
            (.fainting, "fainting", "Fainting", .severity),
            (.fatigue, "fatigue", "Fatigue", .severity),
            (.fever, "fever", "Fever", .severity),
            (.generalizedBodyAche, "generalizedBodyAche", "Body ache", .severity),
            (.hairLoss, "hairLoss", "Hair loss", .severity),
            (.headache, "headache", "Headache", .severity),
            (.heartburn, "heartburn", "Heartburn", .severity),
            (.hotFlashes, "hotFlashes", "Hot flashes", .severity),
            (.lossOfSmell, "lossOfSmell", "Loss of smell", .severity),
            (.lossOfTaste, "lossOfTaste", "Loss of taste", .severity),
            (.lowerBackPain, "lowerBackPain", "Lower back pain", .severity),
            (.memoryLapse, "memoryLapse", "Memory lapse", .severity),
            (.moodChanges, "moodChanges", "Mood changes", .severity),
            (.nausea, "nausea", "Nausea", .severity),
            (.nightSweats, "nightSweats", "Night sweats", .severity),
            (.pelvicPain, "pelvicPain", "Pelvic pain", .severity),
            (.rapidPoundingOrFlutteringHeartbeat, "rapidPoundingOrFlutteringHeartbeat", "Racing heartbeat", .severity),
            (.runnyNose, "runnyNose", "Runny nose", .severity),
            (.shortnessOfBreath, "shortnessOfBreath", "Shortness of breath", .severity),
            (.sinusCongestion, "sinusCongestion", "Sinus congestion", .severity),
            (.skippedHeartbeat, "skippedHeartbeat", "Skipped heartbeat", .severity),
            (.sleepChanges, "sleepChanges", "Sleep changes", .severity),
            (.soreThroat, "soreThroat", "Sore throat", .severity),
            (.vaginalDryness, "vaginalDryness", "Vaginal dryness", .severity),
            (.vomiting, "vomiting", "Vomiting", .severity),
            (.wheezing, "wheezing", "Wheezing", .severity),
        ]
        for symptom in symptoms {
            category(symptom.0, raw: symptom.1, title: symptom.2, group: .symptoms, unitLabel: "", aggregate: .latest, kind: symptom.3)
        }
        return rows
    }
}

enum HealthConvert {
    static func drafts(from samples: [HKSample], type: HealthReadType) -> [HealthDraft] {
        samples.flatMap { make($0, type: type) }
    }

    private static func make(_ sample: HKSample, type: HealthReadType) -> [HealthDraft] {
        switch type.kind {
        case .quantity:
            guard let quantity = sample as? HKQuantitySample, let unit = type.unit else { return [] }
            guard quantity.quantity.is(compatibleWith: unit) else { return [] }
            let value = quantity.quantity.doubleValue(for: unit) * type.scale
            guard value.isFinite else { return [] }
            return [row(sample, typeRaw: type.typeRaw, value: value, unit: type.unitLabel, category: nil, labels: nil, uuid: sample.uuid)]
        case .sleep:
            guard let category = sample as? HKCategorySample else { return [] }
            let hours = max(0, sample.endDate.timeIntervalSince(sample.startDate) / 3600)
            guard hours.isFinite else { return [] }
            return [row(sample, typeRaw: type.typeRaw, value: hours, unit: "h", category: category.value, labels: nil, uuid: sample.uuid)]
        case .mindful:
            guard let category = sample as? HKCategorySample else { return [] }
            let minutes = max(0, sample.endDate.timeIntervalSince(sample.startDate) / 60)
            guard minutes.isFinite else { return [] }
            return [row(sample, typeRaw: type.typeRaw, value: minutes, unit: "min", category: category.value, labels: nil, uuid: sample.uuid)]
        case .standHour:
            guard let category = sample as? HKCategorySample else { return [] }
            let stood = category.value == HKCategoryValueAppleStandHour.stood.rawValue ? 1.0 : 0
            return [row(sample, typeRaw: type.typeRaw, value: stood, unit: "h", category: category.value, labels: nil, uuid: sample.uuid)]
        case .event:
            guard let category = sample as? HKCategorySample else { return [] }
            return [row(sample, typeRaw: type.typeRaw, value: 1, unit: type.unitLabel, category: category.value, labels: nil, uuid: sample.uuid)]
        case .severity, .appetite, .menstrual:
            guard let category = sample as? HKCategorySample else { return [] }
            return [row(sample, typeRaw: type.typeRaw, value: Double(category.value), unit: type.unitLabel, category: category.value, labels: nil, uuid: sample.uuid)]
        case .workout:
            guard let workout = sample as? HKWorkout else { return [] }
            let minutes = max(0, workout.duration / 60)
            guard minutes.isFinite else { return [] }
            var rows = [
                row(
                    sample,
                    typeRaw: "workout",
                    value: minutes,
                    unit: "min",
                    category: Int(workout.workoutActivityType.rawValue),
                    labels: nil,
                    uuid: sample.uuid
                ),
            ]
            if let quantity = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity(),
               quantity.is(compatibleWith: HealthUnits.kilocalorie) {
                let kcal = quantity.doubleValue(for: HealthUnits.kilocalorie)
                if kcal.isFinite, kcal > 0 {
                    rows.append(row(
                        sample,
                        typeRaw: "workoutEnergy",
                        value: kcal,
                        unit: "kcal",
                        category: nil,
                        labels: nil,
                        uuid: HealthIdentity.energyID(for: sample.uuid)
                    ))
                }
            }
            return rows
        case .stateOfMind:
            guard let mind = sample as? HKStateOfMind else { return [] }
            guard mind.valence.isFinite else { return [] }
            return [row(
                sample,
                typeRaw: "stateOfMind",
                value: mind.valence,
                unit: "",
                category: mind.kind.rawValue,
                labels: HealthMoodLabels.names(for: mind.labels),
                uuid: sample.uuid
            )]
        case .workoutEnergy:
            return []
        }
    }

    private static func row(
        _ sample: HKSample,
        typeRaw: String,
        value: Double,
        unit: String,
        category: Int?,
        labels: [String]?,
        uuid: UUID
    ) -> HealthDraft {
        let source = sample.sourceRevision.source
        return HealthDraft(
            typeRaw: typeRaw,
            startDate: sample.startDate,
            endDate: sample.endDate,
            value: value,
            unitRaw: unit,
            categoryValue: category,
            sourceName: source.name,
            sourceBundle: source.bundleIdentifier,
            hkUUID: uuid,
            day: HealthDay.start(of: sample.startDate),
            labels: labels
        )
    }
}

enum HealthChartMetric: String, CaseIterable, Identifiable {
    case steps
    case distance
    case activeEnergy
    case exercise
    case restingHeartRate
    case hrv
    case sleep
    case oxygen
    case weight
    case daylight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps: "Steps"
        case .distance: "Distance"
        case .activeEnergy: "Active energy"
        case .exercise: "Exercise"
        case .restingHeartRate: "Resting HR"
        case .hrv: "HRV"
        case .sleep: "Sleep"
        case .oxygen: "Oxygen"
        case .weight: "Weight"
        case .daylight: "Daylight"
        }
    }

    var detail: String {
        switch self {
        case .steps: "Daily total from Apple Health"
        case .distance: "Daily walking and running distance"
        case .activeEnergy: "Daily active energy"
        case .exercise: "Daily exercise minutes"
        case .restingHeartRate: "Daily resting heart rate"
        case .hrv: "Daily heart rate variability"
        case .sleep: "Daily sleep by stage"
        case .oxygen: "Daily average oxygen saturation"
        case .weight: "Latest weight each day"
        case .daylight: "Daily time in daylight"
        }
    }

    var typeRaw: String? {
        switch self {
        case .steps: "stepCount"
        case .distance: "distanceWalkingRunning"
        case .activeEnergy: "activeEnergyBurned"
        case .exercise: "appleExerciseTime"
        case .restingHeartRate: "restingHeartRate"
        case .hrv: "heartRateVariabilitySDNN"
        case .sleep: nil
        case .oxygen: "oxygenSaturation"
        case .weight: "bodyMass"
        case .daylight: "timeInDaylight"
        }
    }

    var unit: String {
        switch self {
        case .steps: "Steps"
        case .distance: "km"
        case .activeEnergy: "kcal"
        case .exercise: "min"
        case .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .sleep: "Hours"
        case .oxygen: "%"
        case .weight: "kg"
        case .daylight: "min"
        }
    }
}

struct HealthDayValue: Identifiable, Sendable {
    var day: Date
    var value: Double
    var series: String

    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(series)-\(value)" }
}

final class HealthResume: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func run(_ body: () -> Void) {
        lock.lock()
        let shouldRun = !resumed
        resumed = true
        lock.unlock()
        if shouldRun {
            body()
        }
    }
}

final class HealthQueryBox: @unchecked Sendable {
    var query: HKQuery?
}
