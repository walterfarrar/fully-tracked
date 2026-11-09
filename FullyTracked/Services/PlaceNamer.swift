import CoreLocation
import Foundation
import MapKit
import SwiftData

@MainActor
enum PlaceNamer {
    private static var memory: [String: String] = [:]
    private static var inflight: [String: Task<String?, Never>] = [:]
    private static var container: ModelContainer?
    private static var persistenceOK: Bool?
    private static var geocodeGate: Task<Void, Never> = Task {}

    static func attach(_ container: ModelContainer) {
        self.container = container
    }

    static func name(for coordinate: CLLocationCoordinate2D) async -> String? {
        guard coordinate.latitude >= -90, coordinate.latitude <= 90,
              coordinate.longitude >= -180, coordinate.longitude <= 180 else {
            return nil
        }
        let latKey = key(coordinate.latitude)
        let lonKey = key(coordinate.longitude)
        let cacheKey = "\(latKey)|\(lonKey)"
        if let cached = memory[cacheKey] {
            return cached
        }
        if let stored = readStored(latKey: latKey, lonKey: lonKey) {
            memory[cacheKey] = stored
            return stored
        }
        if let pending = inflight[cacheKey] {
            return await pending.value
        }
        let task = Task<String?, Never> {
            await resolveQueued(coordinate)
        }
        inflight[cacheKey] = task
        let resolved = await task.value
        inflight[cacheKey] = nil
        guard let resolved else { return nil }
        let cleaned = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        memory[cacheKey] = cleaned
        writeStored(latKey: latKey, lonKey: lonKey, name: cleaned)
        return cleaned
    }

    private static func resolveQueued(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let previous = geocodeGate
        let task = Task<String?, Never> {
            _ = await previous.value
            return await resolve(coordinate)
        }
        geocodeGate = Task { _ = await task.value }
        return await task.value
    }

    private static func resolve(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26, *) {
            return await resolveMapKit(location)
        }
        return await resolveCoreLocation(location)
    }

    @available(iOS 26, *)
    private static func resolveMapKit(_ location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return nil }
            return shortName(from: item)
        } catch let error as MKError {
            if error.code == .loadingThrottled {
                return nil
            }
            return nil
        } catch is CLError {
            return nil
        } catch {
            return nil
        }
    }

    private static func resolveCoreLocation(_ location: CLLocation) async -> String? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return nil }
            return shortName(from: placemark)
        } catch is CLError {
            return nil
        } catch {
            return nil
        }
    }

    @available(iOS 26, *)
    private static func shortName(from item: MKMapItem) -> String? {
        if item.pointOfInterestCategory != nil, let poi = trimmed(item.name) {
            return poi
        }
        if let address = item.address, let short = trimmed(address.shortAddress) {
            return short
        }
        return trimmed(item.name)
    }

    private static func shortName(from placemark: CLPlacemark) -> String? {
        if let poi = placemark.areasOfInterest?.compactMap(trimmed).first {
            return poi
        }
        let street = trimmed(placemark.thoroughfare)
        let city = trimmed(placemark.locality)
        if let name = trimmed(placemark.name) {
            let number = trimmed(placemark.subThoroughfare)
            let streetLine = [number, street].compactMap { $0 }.joined(separator: " ")
            let matchesStreet = name == street || name == streetLine || (street != nil && name.contains(street!))
            if !matchesStreet {
                return name
            }
        }
        if let street, let city {
            return "\(street), \(city)"
        }
        return street ?? city ?? trimmed(placemark.name)
    }

    /// Skip SwiftData until PlaceCacheEntry is in the app schema. Fetching an unregistered model can trap.
    private static func canPersist() -> Bool {
        if let persistenceOK {
            return persistenceOK
        }
        guard let container else { return false }
        let included = container.schema.entities.contains { $0.name == "PlaceCacheEntry" }
        persistenceOK = included
        return included
    }

    private static func readStored(latKey: String, lonKey: String) -> String? {
        guard canPersist(), let context = container?.mainContext else { return nil }
        let lat = latKey
        let lon = lonKey
        var descriptor = FetchDescriptor<PlaceCacheEntry>(
            predicate: #Predicate<PlaceCacheEntry> { entry in
                entry.latKey == lat && entry.lonKey == lon
            }
        )
        descriptor.fetchLimit = 1
        do {
            let rows = try context.fetch(descriptor)
            persistenceOK = true
            guard let name = rows.first?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            return name
        } catch {
            persistenceOK = false
            return nil
        }
    }

    private static func writeStored(latKey: String, lonKey: String, name: String) {
        guard canPersist(), let context = container?.mainContext else { return }
        let row = PlaceCacheEntry(latKey: latKey, lonKey: lonKey, name: name, savedAt: Date())
        context.insert(row)
        do {
            try context.save()
        } catch {
            context.delete(row)
        }
    }

    private static func key(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        if rounded == 0 {
            return "0.000"
        }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
