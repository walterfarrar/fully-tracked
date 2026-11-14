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
final class LiveMapLocation: ObservableObject {
    @Published var fix: LocationFix?
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    @Published private(set) var statusLine = "Automatic check-ins are on. Timing depends on location updates from iOS."
    @Published private(set) var lastEvent = ""
    @Published private(set) var checkingIn = false
    @Published private(set) var trackingEnabled: Bool
    /// Live fixes only notify the map, so they do not invalidate journal forms.
    let liveMapLocation = LiveMapLocation()
    private var mapVisible = false
    private var latestFix: LocationFix? {
        didSet {
            if mapVisible { liveMapLocation.fix = latestFix }
        }
    }

    private let manager = CLLocationManager()
    private let floorManager = CLLocationManager()
    private let mapManager = CLLocationManager()
    private var container: ModelContainer?
    private var configured = false
    private var floorConfigured = false
    private var lastAcceptedAt: Date?
    private var lastAutomaticCheckAt: Date?
    private var manualCheckIn = false
    /// Retain our explicit authorization requirement for background check-ins.
    private var alwaysServiceSession: CLServiceSession?
    private static let intervalKey = "locationIntervalMinutes"
    private static let enabledKey = "locationTrackingEnabled"
    private static let cleanupKey = "fullyTracked.location.checkInsOnlyCleanup.v1"
    private static let lastCheckKey = "fullyTracked.location.lastAutomaticCheckAt"

    var intervalMinutes: Int {
        guard UserDefaults.standard.object(forKey: Self.intervalKey) != nil else { return 30 }
        let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
        return min(10_080, max(1, stored))
    }

    override init() {
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            trackingEnabled = true
        } else {
            trackingEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        super.init()
        lastAutomaticCheckAt = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        publishStatus()
    }

    func attach(_ container: ModelContainer) {
        self.container = container
        if !UserDefaults.standard.bool(forKey: Self.cleanupKey) {
            do {
                try LocationHistoryCleanup.run(in: container)
                UserDefaults.standard.set(true, forKey: Self.cleanupKey)
            } catch {
                lastEvent = "Old trip and visit records could not be cleared. Cleanup will retry the next time the app opens."
            }
        }
        PlaceNamer.attach(container)
        MotionActivityMonitor.shared.attach(container)
        lastAcceptedAt = (try? JournalQueries.latestCheckIn(in: container.mainContext))?.savedAt
        if let latest = try? JournalQueries.latestCheckIn(in: container.mainContext, byOccurrence: true) {
            if let latitude = latest.latitude, let longitude = latest.longitude {
                latestFix = LocationFix(
                    latitude: latitude,
                    longitude: longitude,
                    accuracy: latest.accuracyMeters ?? -1,
                    altitude: latest.altitude,
                    timestamp: latest.occurredAt
                )
            }
        }
    }

    func setMapVisible(_ visible: Bool) {
        mapVisible = visible
        if visible { liveMapLocation.fix = latestFix }
    }

    /// A foreground map refresh never creates an extra journal entry.
    func refreshMapLocation() {
        guard UIApplication.shared.applicationState == .active else { return }
        guard manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse else { return }
        mapManager.delegate = self
        mapManager.desiredAccuracy = kCLLocationAccuracyBest
        mapManager.requestLocation()
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

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let managerID = ObjectIdentifier(manager)
        Task { @MainActor in
            guard managerID != ObjectIdentifier(self.mapManager) else { return }
            self.apply(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { LocationFix(location: $0) }
        let managerID = ObjectIdentifier(manager)
        Task { @MainActor in
            if let fix = fixes.last, fix.isRecordable(),
               fix.timestamp > (self.latestFix?.timestamp ?? .distantPast) {
                self.latestFix = fix
            }
            if managerID == ObjectIdentifier(self.mapManager) {
                return
            }
            let fromFloor = managerID == ObjectIdentifier(self.floorManager)
            if fromFloor {
                if !self.manualCheckIn {
                    self.consume(fixes, manual: false)
                }
                MotionActivityMonitor.shared.noteAwake()
                return
            }
            let manual = self.manualCheckIn
            self.consume(fixes, manual: manual)
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
        // Retire visit monitoring registered by earlier versions. Significant changes
        // can wake the app, but still pass through the check-in interval below.
        floorManager.stopMonitoringVisits()
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
        statusLine = "Location is checked about every \(intervalMinutes) minutes, including while the phone is locked. The same grid cell is saved at most once an hour. Timing depends on location updates from iOS."
    }

    private func finishManual(message: String) {
        manualCheckIn = false
        checkingIn = false
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lastEvent = message
    }

    /// Evaluate once per interval, saving a new cell or an hourly same-cell check-in.
    /// A manual check-in bypasses both limits. All automatic readings use this path.
    private func consume(_ fixes: [LocationFix], manual: Bool) {
        guard manual || trackingEnabled else { return }
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
        if !manual && !shouldSaveAutomatic(fix, at: Date()) {
            return
        }
        _ = save(fix, manual: manual, announce: true)
    }

    @discardableResult
    private func save(_ fix: LocationFix, manual: Bool, announce: Bool) -> Bool {
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

        let previous = lastAcceptedAt
        lastAcceptedAt = Date()
        let entry = JournalEntry(type: .location, occurredAt: fix.timestamp)
        entry.latitude = fix.latitude
        entry.longitude = fix.longitude
        entry.accuracyMeters = fix.accuracy
        entry.altitude = fix.altitude
        entry.source = "device"
        fillBattery(entry)
        context.insert(entry)
        do {
            try context.save()
        } catch {
            lastAcceptedAt = previous
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

    private func shouldSaveAutomatic(_ fix: LocationFix, at now: Date) -> Bool {
        guard LocationCheckInPolicy.isCheckDue(
            now: now, intervalMinutes: intervalMinutes,
            lastCheckedAt: lastAutomaticCheckAt, lastSavedAt: lastAcceptedAt
        ) else { return false }

        // Read the latest saved check-in, including imports, manual saves, and
        // significant-change check-ins from earlier app versions.
        guard let context = container?.mainContext else { return false }
        let previous: JournalEntry?
        do {
            previous = try JournalQueries.latestCheckIn(in: context)
        } catch {
            lastEvent = "The last check-in could not be read. This check will retry when location updates arrive."
            return false
        }
        guard LocationCheckInPolicy.isCheckDue(
            now: now, intervalMinutes: intervalMinutes,
            lastCheckedAt: lastAutomaticCheckAt, lastSavedAt: previous?.savedAt
        ) else { return false }

        // Persist even a skipped check so reopening the app does not check early.
        lastAutomaticCheckAt = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)
        let previousCell: LocationGridCell?
        if let latitude = previous?.latitude, let longitude = previous?.longitude {
            previousCell = LocationGridCell(latitude: latitude, longitude: longitude)
        } else {
            previousCell = nil
        }
        let shouldSave = LocationCheckInPolicy.shouldSave(
            cell: LocationGridCell(latitude: fix.latitude, longitude: fix.longitude),
            previousCell: previousCell, lastSavedAt: previous?.savedAt, now: now
        )
        if !shouldSave {
            lastEvent = "Location checked. Still in the same grid cell; the next saved check-in waits until an hour has passed or the cell changes."
        }
        return shouldSave
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
        guard let entry = try? JournalQueries.entry(id: id, in: context) else { return }
        if let existing = entry.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return
        }
        entry.placeName = cleaned
        try? context.save()
    }

    private func attachWeather(_ reading: WeatherReading?, to id: UUID, announce: Bool) {
        guard let context = container?.mainContext else { return }
        guard let entry = try? JournalQueries.entry(id: id, in: context) else { return }
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
