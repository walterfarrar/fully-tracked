import CoreLocation
import Foundation
import SwiftData
import UIKit

struct LocationFix: Sendable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var timestamp: Date
}

@MainActor
final class LocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationTracker()

    @Published private(set) var statusLine = "Location is on. Check-ins are saved on the interval, including while the app is not on screen."
    @Published private(set) var lastEvent = ""

    private let manager = CLLocationManager()
    private var container: ModelContainer?
    private var configured = false
    private var lastAcceptedAt: Date?
    private let intervalKey = "locationIntervalMinutes"

    var intervalMinutes: Int {
        guard UserDefaults.standard.object(forKey: intervalKey) != nil else { return 30 }
        let stored = UserDefaults.standard.integer(forKey: intervalKey)
        return min(10_080, max(5, stored))
    }

    func attach(_ container: ModelContainer) {
        self.container = container
    }

    func setInterval(minutes: Int) {
        let clamped = min(10_080, max(5, minutes))
        UserDefaults.standard.set(clamped, forKey: intervalKey)
        publishStatus()
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
                timestamp: location.timestamp
            )
        }
        Task { @MainActor in
            self.consume(fixes)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.lastEvent = "Location could not be read. \(message) No check-in was invented."
        }
    }

    private func apply(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
            publishStatus()
        case .authorizedAlways:
            manager.startUpdatingLocation()
            publishStatus()
        case .authorizedWhenInUse:
            manager.startUpdatingLocation()
            manager.requestAlwaysAuthorization()
            statusLine = "Always location is still needed for check-ins while the app is not on screen."
        case .denied, .restricted:
            statusLine = "Location is not allowed. Allow Always location so check-ins can be saved while the app is not on screen."
        @unknown default:
            publishStatus()
        }
    }

    private func publishStatus() {
        statusLine = "Location is on. A check-in is saved every \(intervalMinutes) minutes, including while the app is not on screen."
    }

    /// Updates may arrive often. Only one check-in is stored per interval.
    private func consume(_ fixes: [LocationFix]) {
        guard let fix = fixes.last else { return }
        let age = Date().timeIntervalSince(fix.timestamp)
        guard fix.accuracy >= 0, age >= -60, age < 5 * 60 else { return }
        guard fix.latitude >= -90, fix.latitude <= 90, fix.longitude >= -180, fix.longitude <= 180 else { return }
        guard shouldRecord(at: Date()) else { return }
        guard let context = container?.mainContext else { return }

        let previous = lastAcceptedAt
        lastAcceptedAt = Date()
        let entry = JournalEntry(type: .location, occurredAt: fix.timestamp)
        entry.latitude = fix.latitude
        entry.longitude = fix.longitude
        entry.accuracyMeters = fix.accuracy
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
