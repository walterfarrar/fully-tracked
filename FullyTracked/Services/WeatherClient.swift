import Foundation

struct WeatherReading: Sendable {
    var observedAt: Date
    var latitude: Double
    var longitude: Double
    var temperatureCelsius: Double
    var condition: String
}

enum WeatherClient {
    /// Asks Open-Meteo for the current temperature and condition.
    /// A failed request returns nil. The caller stores no weather in that case.
    static func fetch(latitude: Double, longitude: Double) async -> WeatherReading? {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return decode(data, latitude: latitude, longitude: longitude)
        } catch {
            return nil
        }
    }

    private static func decode(_ data: Data, latitude: Double, longitude: Double) -> WeatherReading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int,
              let condition = condition(for: code),
              let time = current["time"] as? String,
              let observedAt = parseTime(time) else {
            return nil
        }
        return WeatherReading(
            observedAt: observedAt,
            latitude: latitude,
            longitude: longitude,
            temperatureCelsius: temperature,
            condition: condition
        )
    }

    private static func parseTime(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    static func condition(for code: Int) -> String? {
        switch code {
        case 0: "Clear"
        case 1: "Mainly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75: "Snow"
        case 77: "Snow grains"
        case 80, 81, 82: "Rain showers"
        case 85, 86: "Snow showers"
        case 95, 96, 99: "Thunderstorm"
        default: nil
        }
    }
}
