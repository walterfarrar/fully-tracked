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
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    @Published private(set) var statusLine = "Location is on. Check-ins are saved on the interval, including while the app is not on screen."
    @Published private(set) var lastEvent = ""
    @Published private(set) var checkingIn = false
    @Published private(set) var trackingEnabled: Bool

    private let manager = CLLocationManager()
    private var container: ModelContainer?
    private var configured = false
    private var lastAcceptedAt: Date?
    private var manualCheckIn = false
    private static let intervalKey = "locationIntervalMinutes"
    private static let enabledKey = "locationTrackingEnabled"

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
        publishStatus()
    }

    func attach(_ container: ModelContainer) {
        self.container = container
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
        }
        guard trackingEnabled else {
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
        Task { @MainActor in
            self.apply(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { location in
            LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                altitude: location.verticalAccuracy < 0 ? nil : location.altitude,
                timestamp: location.timestamp
            )
        }
        Task { @MainActor in
            let manual = self.manualCheckIn
            self.consume(fixes, manual: manual)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
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
            if trackingEnabled {
                manager.startUpdatingLocation()
                if !manualCheckIn {
                    publishStatus()
                }
            } else {
                manager.stopUpdatingLocation()
                if !manualCheckIn {
                    publishStatus()
                }
            }
            if manualCheckIn {
                manager.requestLocation()
            }
        case .authorizedWhenInUse:
            if trackingEnabled {
                manager.startUpdatingLocation()
            } else {
                manager.stopUpdatingLocation()
            }
            manager.requestAlwaysAuthorization()
            if !manualCheckIn {
                statusLine = "Always location is still needed for check-ins while the app is not on screen."
            }
            if manualCheckIn {
                manager.requestLocation()
            }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
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
    /// A manual check-in ignores that gap.
    private func consume(_ fixes: [LocationFix], manual: Bool) {
        guard let fix = fixes.last else {
            if manual {
                finishManual(message: "Location was not recorded.")
            }
            return
        }
        let age = Date().timeIntervalSince(fix.timestamp)
        let coordinatesOK = fix.latitude >= -90 && fix.latitude <= 90 && fix.longitude >= -180 && fix.longitude <= 180
        let fresh = fix.accuracy >= 0 && age >= -60 && age < 5 * 60 && coordinatesOK
        guard fresh else {
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
        if manual {
            manualCheckIn = false
            checkingIn = false
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
        guard let context = container?.mainContext else {
            if manual {
                lastEvent = "The check-in could not be saved. No substitute reading was stored."
            }
            return
        }

        let previous = lastAcceptedAt
        lastAcceptedAt = Date()
        let entry = JournalEntry(type: .location, occurredAt: fix.timestamp)
        entry.latitude = fix.latitude
        entry.longitude = fix.longitude
        entry.accuracyMeters = fix.accuracy
        entry.altitude = fix.altitude
        entry.source = "device"
        context.insert(entry)
        do {
            try context.save()
        } catch {
            lastAcceptedAt = previous
            context.delete(entry)
            lastEvent = "The check-in could not be saved. No substitute reading was stored."
            return
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
                self.attachWeather(reading, to: entryID)
            }
        }
        HealthSteps.shared.refreshIfDue()
    }

    private func shouldRecord(at now: Date) -> Bool {
        let gap = TimeInterval(intervalMinutes * 60)
        if let lastAcceptedAt, now.timeIntervalSince(lastAcceptedAt) < gap {
            return false
        }
        if let stored = latestSavedAt(), now.timeIntervalSince(stored) < gap {
            return false
        }
        return true
    }

    private func latestSavedAt() -> Date? {
        guard let context = container?.mainContext else { return nil }
        let descriptor = FetchDescriptor<JournalEntry>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows
            .filter { $0.entryType == .location }
            .map(\.savedAt)
            .max()
    }

    private func attachWeather(_ reading: WeatherReading?, to id: UUID) {
        guard let context = container?.mainContext else { return }
        let descriptor = FetchDescriptor<JournalEntry>()
        let rows = (try? context.fetch(descriptor)) ?? []
        guard let entry = rows.first(where: { $0.id == id }) else { return }
        guard let reading else {
            entry.temperatureCelsius = nil
            entry.condition = nil
            entry.weatherObservedAt = nil
            try? context.save()
            lastEvent = "The last check-in has no weather. The weather request failed, and no reading was invented."
            return
        }
        entry.weatherObservedAt = reading.observedAt
        entry.temperatureCelsius = reading.temperatureCelsius
        entry.condition = reading.condition
        do {
            try context.save()
            lastEvent = "Last check-in, \(JournalMath.formatFahrenheit(reading.temperatureCelsius)), \(reading.condition)."
        } catch {
            entry.temperatureCelsius = nil
            entry.condition = nil
            entry.weatherObservedAt = nil
            try? context.save()
            lastEvent = "The last check-in has no weather. The weather request failed, and no reading was invented."
        }
    }
}
