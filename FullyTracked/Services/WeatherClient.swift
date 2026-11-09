import CoreLocation
import Foundation
import SwiftUI
import WeatherKit

struct WeatherReading: Sendable {
    var observedAt: Date
    var latitude: Double
    var longitude: Double
    var temperatureCelsius: Double
    var condition: String
}

enum WeatherClient {
    /// Current conditions from WeatherKit. A failed request returns nil.
    /// The caller stores no weather in that case.
    static func fetch(latitude: Double, longitude: Double) async -> WeatherReading? {
        guard latitude >= -90, latitude <= 90, longitude >= -180, longitude <= 180 else {
            return nil
        }
        if let cached = await WeatherMemory.shared.cached(latitude: latitude, longitude: longitude) {
            return cached
        }
        guard let reading = await request(latitude: latitude, longitude: longitude) else {
            return nil
        }
        await WeatherMemory.shared.store(reading)
        return reading
    }

    private static func request(latitude: Double, longitude: Double) async -> WeatherReading? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let current = try await WeatherService.shared.weather(for: location, including: .current)
            let celsius = current.temperature.converted(to: .celsius).value
            guard celsius.isFinite else { return nil }
            let condition = conditionText(current.condition)
            return WeatherReading(
                observedAt: current.date,
                latitude: latitude,
                longitude: longitude,
                temperatureCelsius: celsius,
                condition: condition
            )
        } catch {
            return nil
        }
    }

    /// Stable English labels. `description` is localized, and later conditions fall back to it.
    private static func conditionText(_ condition: WeatherCondition) -> String {
        let english: String? = switch condition {
        case .clear: "Clear"
        case .mostlyClear: "Mostly clear"
        case .mostlyCloudy: "Mostly cloudy"
        case .partlyCloudy: "Partly cloudy"
        case .cloudy: "Cloudy"
        case .foggy: "Fog"
        case .haze: "Haze"
        case .smoky: "Smoky"
        case .blowingDust: "Blowing dust"
        case .breezy: "Breezy"
        case .windy: "Windy"
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .sunShowers: "Sun showers"
        case .freezingDrizzle: "Freezing drizzle"
        case .freezingRain: "Freezing rain"
        case .flurries: "Flurries"
        case .sunFlurries: "Sun flurries"
        case .snow: "Snow"
        case .heavySnow: "Heavy snow"
        case .blizzard: "Blizzard"
        case .blowingSnow: "Blowing snow"
        case .sleet: "Sleet"
        case .wintryMix: "Wintry mix"
        case .hail: "Hail"
        case .thunderstorms: "Thunderstorm"
        case .isolatedThunderstorms: "Isolated thunderstorms"
        case .scatteredThunderstorms: "Scattered thunderstorms"
        case .strongStorms: "Strong storms"
        case .hot: "Hot"
        case .frigid: "Frigid"
        case .hurricane: "Hurricane"
        case .tropicalStorm: "Tropical storm"
        default: nil
        }
        if let english {
            return english
        }
        let fallback = condition.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Unknown" : fallback
    }
}

/// Reuses a reading when the same neighborhood was checked within the last hour.
private actor WeatherMemory {
    static let shared = WeatherMemory()

    private struct Slot {
        var latitude: Double
        var longitude: Double
        var reading: WeatherReading
        var fetchedAt: Date
    }

    private var slots: [Slot] = []

    func cached(latitude: Double, longitude: Double, now: Date = Date()) -> WeatherReading? {
        slots.removeAll { now.timeIntervalSince($0.fetchedAt) >= 60 * 60 }
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return slots
            .filter { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= 1_000 }
            .max { $0.fetchedAt < $1.fetchedAt }?
            .reading
    }

    func store(_ reading: WeatherReading, fetchedAt: Date = Date()) {
        slots.removeAll { fetchedAt.timeIntervalSince($0.fetchedAt) >= 60 * 60 }
        slots.append(
            Slot(
                latitude: reading.latitude,
                longitude: reading.longitude,
                reading: reading,
                fetchedAt: fetchedAt
            )
        )
        if slots.count > 24 {
            slots.removeFirst(slots.count - 24)
        }
    }
}

struct WeatherAttributionView: View {
    @State private var markURL: URL?
    @State private var legalURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let markURL {
                AsyncImage(url: markURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(height: 20)
                            .frame(maxWidth: 140, alignment: .leading)
                    case .failure:
                        EmptyView()
                    default:
                        Color.clear.frame(width: 88, height: 20)
                    }
                }
                .accessibilityLabel("Apple Weather")
            }
            if let legalURL {
                Link("Other data sources", destination: legalURL)
                    .font(Theme.font(12))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await load()
        }
    }

    private func load() async {
        guard markURL == nil, legalURL == nil else { return }
        guard let attribution = try? await WeatherService.shared.attribution else { return }
        markURL = attribution.combinedMarkDarkURL
        legalURL = attribution.legalPageURL
    }
}
