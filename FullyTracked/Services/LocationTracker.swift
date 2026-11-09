import CoreLocation
import Foundation
import SwiftData
import UIKit

struct LocationFix: Sendable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var altitude: Double?
    var timestamp: Date

    init(latitude: Double, longitude: Double, accuracy: Double, altitude: Double?, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.timestamp = timestamp
    }

    init(location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy < 0 ? nil : location.altitude,
            timestamp: location.timestamp
        )
    }

    func isRecordable(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        let coordinatesOK = latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
        return accuracy >= 0 && age >= -60 && age < 5 * 60 && coordinatesOK
    }
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    @Published private(set) var statusLine = "Location is on. Check-ins are saved on the interval, including while the app is not on screen."
    @Published private(set) var lastEvent = ""
    @Published private(set) var checkingIn = false
    @Published private(set) var trackingEnabled: Bool

    private let manager = CLLocationManager()
    private let floorManager = CLLocationManager()
    private var container: ModelContainer?
    private var configured = false
    private var floorConfigured = false
    private var lastAcceptedAt: Date?
    private var manualCheckIn = false
    /// iOS 18 keeps Always authorization effective only while this session is retained.
    private var alwaysServiceSession: CLServiceSession?
    private static let intervalKey = "locationIntervalMinutes"
    private static let enabledKey = "locationTrackingEnabled"

    var intervalMinutes: Int {
        guard UserDefaults.standard.object(forKey: Self.intervalKey) != nil else { return 30 }
        let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
        return min(10_080, max(1, stored))
    }

    var canTrackInBackground: Bool {
        trackingEnabled && manager.authorizationStatus == .authorizedAlways
    }

    override init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            trackingEnabled = true
        } else {
            trackingEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        super.init()
        publishStatus()
    }

    func attach(_ container: ModelContainer) {
        self.container = container
        PlaceNamer.attach(container)
        MotionActivityMonitor.shared.attach(container)
    }

    func setInterval(minutes: Int) {
        let clamped = min(10_080, max(1, minutes))
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        publishStatus()
    }

    func setTrackingEnabled(_ enabled: Bool) {
        trackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if !configured {
            start()
            return
        }
        if enabled {
            apply(manager.authorizationStatus)
        } else {
            manager.stopUpdatingLocation()
            endFloorMonitoring()
            MotionActivityMonitor.shared.stop()
            releaseAlwaysSession()
            publishStatus()
        }
    }

    /// One reading, saved even when the interval has not elapsed.
    func checkInNow() {
        if !configured {
            start()
        }
        checkingIn = true
        manualCheckIn = true
        lastEvent = ""
        manager.desiredAccuracy = kCLLocationAccuracyBest
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finishManual(message: "Location was not recorded.")
        @unknown default:
            finishManual(message: "Location was not recorded.")
        }
    }

    func start() {
        if !configured {
            configured = true
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone
            manager.activityType = .other
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
            manager.allowsBackgroundLocationUpdates = true
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        guard trackingEnabled else {
            manager.stopUpdatingLocation()
            endFloorMonitoring()
            MotionActivityMonitor.shared.stop()
            releaseAlwaysSession()
            publishStatus()
            return
        }
        apply(manager.authorizationStatus)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func mostRecentLocation() -> CLLocation? {
        guard let latest = allEntries()
            .filter({ $0.entryType == .location || $0.entryType == .visit })
            .filter({ $0.latitude != nil && $0.longitude != nil })
            .max(by: { $0.occurredAt < $1.occurredAt }),
              let latitude = latest.latitude,
              let longitude = latest.longitude else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }

    @discardableResult
    func recordTripFix(_ fix: LocationFix) -> Bool {
        guard fix.isRecordable() else { return false }
        return save(fix, source: "trip", manual: false, announce: false)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.apply(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { LocationFix(location: $0) }
        let managerID = ObjectIdentifier(manager)
        Task { @MainActor in
            let fromFloor = managerID == ObjectIdentifier(self.floorManager)
            if fromFloor {
                if !self.manualCheckIn {
                    self.consume(fixes, manual: false, source: "significant")
                }
                MotionActivityMonitor.shared.noteAwake()
                return
            }
            let manual = self.manualCheckIn
            self.consume(fixes, manual: manual, source: "device")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let arrival = visit.arrivalDate
        let departure = visit.departureDate
        let latitude = visit.coordinate.latitude
        let longitude = visit.coordinate.longitude
        let accuracy = visit.horizontalAccuracy
        Task { @MainActor in
            self.recordVisit(
                arrival: arrival,
                departure: departure,
                latitude: latitude,
                longitude: longitude,
                accuracy: accuracy
            )
            MotionActivityMonitor.shared.noteAwake()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        let managerID = ObjectIdentifier(manager)
        Task { @MainActor in
            guard managerID == ObjectIdentifier(self.manager) else { return }
            if self.manualCheckIn {
                self.finishManual(message: "Location was not recorded.")
                return
            }
            self.lastEvent = "Location could not be read. \(message) No check-in was invented."
        }
    }

    private func apply(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
            if !manualCheckIn {
                publishStatus()
            }
        case .authorizedAlways:
            holdAlwaysSession()
            if trackingEnabled {
                manager.startUpdatingLocation()
                beginFloorMonitoring()
                MotionActivityMonitor.shared.start()
                if !manualCheckIn {
                    publishStatus()
                }
            } else {
                manager.stopUpdatingLocation()
                endFloorMonitoring()
                MotionActivityMonitor.shared.stop()
                if !manualCheckIn {
                    publishStatus()
                }
            }
            if manualCheckIn {
                manager.requestLocation()
            }
        case .authorizedWhenInUse:
            releaseAlwaysSession()
            endFloorMonitoring()
            if trackingEnabled {
                manager.startUpdatingLocation()
                MotionActivityMonitor.shared.start()
            } else {
                manager.stopUpdatingLocation()
                MotionActivityMonitor.shared.stop()
            }
            manager.requestAlwaysAuthorization()
            if !manualCheckIn {
                statusLine = "Always location is still needed for check-ins while the app is not on screen."
            }
            if manualCheckIn {
                manager.requestLocation()
            }
        case .denied, .restricted:
            releaseAlwaysSession()
            manager.stopUpdatingLocation()
            endFloorMonitoring()
            MotionActivityMonitor.shared.stop()
            if manualCheckIn {
                finishManual(message: "Location was not recorded.")
            }
            statusLine = "Location is not allowed. Allow Always location so check-ins can be saved while the app is not on screen."
        @unknown default:
            if !manualCheckIn {
                publishStatus()
            }
        }
    }

    private func beginFloorMonitoring() {
        if !floorConfigured {
            floorConfigured = true
            floorManager.delegate = self
            floorManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            floorManager.distanceFilter = kCLDistanceFilterNone
            floorManager.activityType = .other
            floorManager.pausesLocationUpdatesAutomatically = true
        }
        floorManager.startMonitoringVisits()
        floorManager.startMonitoringSignificantLocationChanges()
    }

    private func endFloorMonitoring() {
        floorManager.stopMonitoringVisits()
        floorManager.stopMonitoringSignificantLocationChanges()
    }

    private func holdAlwaysSession() {
        guard alwaysServiceSession == nil else { return }
        alwaysServiceSession = CLServiceSession(authorization: .always)
    }

    private func releaseAlwaysSession() {
        alwaysServiceSession = nil
    }

    private func publishStatus() {
        if !trackingEnabled {
            statusLine = "Location check-ins are off. A one-time check-in still saves when you ask."
            return
        }
        statusLine = "Location is on. A check-in is saved every \(intervalMinutes) minutes, including while the app is not on screen."
    }

    private func finishManual(message: String) {
        manualCheckIn = false
        checkingIn = false
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lastEvent = message
    }

    /// Updates may arrive often. Only one automatic check-in is stored per interval.
    /// A manual check-in ignores that gap. Trip fixes do not use this path.
    private func consume(_ fixes: [LocationFix], manual: Bool, source: String) {
        guard let fix = fixes.last else {
            if manual {
                finishManual(message: "Location was not recorded.")
            }
            return
        }
        guard fix.isRecordable() else {
            if manual {
                let message = fix.accuracy < 0
                    ? "The device returned a reading without a usable accuracy, so it was not saved."
                    : "Location was not recorded."
                finishManual(message: message)
            }
            return
        }
        if !manual && !shouldRecord(at: Date()) {
            return
        }
        _ = save(fix, source: source, manual: manual, announce: true)
    }

    @discardableResult
    private func save(_ fix: LocationFix, source: String, manual: Bool, announce: Bool) -> Bool {
        if manual {
            manualCheckIn = false
            checkingIn = false
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
        guard let context = container?.mainContext else {
            if manual || announce {
                lastEvent = "The check-in could not be saved. No substitute reading was stored."
            }
            return false
        }

        let countsTowardInterval = source != "trip"
        let previous = lastAcceptedAt
        if countsTowardInterval {
            lastAcceptedAt = Date()
        }
        let entry = JournalEntry(type: .location, occurredAt: fix.timestamp)
        entry.latitude = fix.latitude
        entry.longitude = fix.longitude
        entry.accuracyMeters = fix.accuracy
        entry.altitude = fix.altitude
        entry.source = source
        fillBattery(entry)
        context.insert(entry)
        do {
            try context.save()
        } catch {
            if countsTowardInterval {
                lastAcceptedAt = previous
            }
            context.delete(entry)
            if manual || announce {
                lastEvent = "The check-in could not be saved. No substitute reading was stored."
            }
            return false
        }

        if manual {
            lastEvent = "Location recorded."
        }

        let entryID = entry.id
        let latitude = fix.latitude
        let longitude = fix.longitude
        Task {
            let reading = await WeatherClient.fetch(latitude: latitude, longitude: longitude)
            await MainActor.run {
                self.attachWeather(reading, to: entryID, announce: announce)
            }
        }
        schedulePlaceName(latitude: latitude, longitude: longitude, entryID: entryID)
        HealthSteps.shared.refreshIfDue()
        return true
    }

    private func recordVisit(
        arrival: Date,
        departure: Date,
        latitude: Double,
        longitude: Double,
        accuracy: Double
    ) {
        let departureOpen = departure == Date.distantFuture
        let arrivalOpen = arrival == Date.distantFuture
        let kind: String
        let occurredAt: Date
        if departureOpen {
            guard !arrivalOpen else { return }
            kind = "arrival"
            occurredAt = arrival
        } else {
            kind = "departure"
            occurredAt = departure
        }
        guard latitude.isFinite, longitude.isFinite,
              latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            return
        }
        guard let context = container?.mainContext else { return }
        if visitExists(kind: kind, occurredAt: occurredAt, latitude: latitude, longitude: longitude) {
            return
        }

        let entry = JournalEntry(type: .visit, occurredAt: occurredAt)
        entry.kind = kind
        entry.latitude = latitude
        entry.longitude = longitude
        entry.accuracyMeters = accuracy.isFinite && accuracy >= 0 ? accuracy : nil
        entry.source = "visit"
        if kind == "departure", !arrivalOpen, departure > arrival {
            entry.durationMinutes = departure.timeIntervalSince(arrival) / 60
        }
        fillBattery(entry)
        context.insert(entry)
        do {
            try context.save()
        } catch {
            context.delete(entry)
            return
        }
        schedulePlaceName(latitude: latitude, longitude: longitude, entryID: entry.id)
    }

    private func visitExists(kind: String, occurredAt: Date, latitude: Double, longitude: Double) -> Bool {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return allEntries().contains { entry in
            guard entry.entryType == .visit, entry.kind == kind else { return false }
            guard abs(entry.occurredAt.timeIntervalSince(occurredAt)) < 1 else { return false }
            guard let lat = entry.latitude, let lon = entry.longitude else { return false }
            return CLLocation(latitude: lat, longitude: lon).distance(from: here) < 50
        }
    }

    private func shouldRecord(at now: Date) -> Bool {
        let gap = TimeInterval(intervalMinutes * 60)
        if let lastAcceptedAt, now.timeIntervalSince(lastAcceptedAt) < gap {
            return false
        }
        if let stored = latestIntervalAnchor(), now.timeIntervalSince(stored) < gap {
            return false
        }
        return true
    }

    /// Trip points are extra. They do not move the interval check-in clock.
    private func latestIntervalAnchor() -> Date? {
        allEntries()
            .filter { $0.entryType == .location && $0.source != "trip" }
            .map(\.savedAt)
            .max()
    }

    private func allEntries() -> [JournalEntry] {
        guard let context = container?.mainContext else { return [] }
        return (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []
    }

    private func fillBattery(_ entry: JournalEntry) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = Double(device.batteryLevel)
        entry.batteryLevel = level >= 0 && level.isFinite ? level : nil
        entry.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func schedulePlaceName(latitude: Double, longitude: Double, entryID: UUID) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        Task {
            guard let name = await PlaceNamer.name(for: coordinate) else { return }
            await MainActor.run {
                self.applyPlaceName(name, to: entryID)
            }
        }
    }

    private func applyPlaceName(_ name: String, to id: UUID) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let context = container?.mainContext else { return }
        guard let entry = allEntries().first(where: { $0.id == id }) else { return }
        if let existing = entry.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return
        }
        entry.placeName = cleaned
        try? context.save()
    }

    private func attachWeather(_ reading: WeatherReading?, to id: UUID, announce: Bool) {
        guard let context = container?.mainContext else { return }
        guard let entry = allEntries().first(where: { $0.id == id }) else { return }
        guard let reading else {
            entry.temperatureCelsius = nil
            entry.condition = nil
            entry.weatherObservedAt = nil
            try? context.save()
            if announce {
                let reason = WeatherClient.lastFailure.map { " \($0)" } ?? ""
                lastEvent = "The last check-in has no weather. The weather request failed, and no reading was invented.\(reason)"
            }
            return
        }
        entry.weatherObservedAt = reading.observedAt
        entry.temperatureCelsius = reading.temperatureCelsius
        entry.condition = reading.condition
        do {
            try context.save()
            if announce {
                lastEvent = "Last check-in, \(JournalMath.formatFahrenheit(reading.temperatureCelsius)), \(reading.condition)."
            }
        } catch {
            entry.temperatureCelsius = nil
            entry.condition = nil
            entry.weatherObservedAt = nil
            try? context.save()
            if announce {
                lastEvent = "The last check-in has no weather. The weather request failed, and no reading was invented."
            }
        }
    }
}
