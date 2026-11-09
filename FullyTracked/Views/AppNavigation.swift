import Observation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable, Hashable {
    case home
    case log
    case graphs
    case map
    case correlations
    case analyze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .log: "Log"
        case .graphs: "Graphs"
        case .map: "Map"
        case .correlations: "Compare"
        case .analyze: "Analyze"
        }
    }
}

enum CheckInKind: String, Identifiable, Equatable {
    case meal
    case hydration
    case bathroom
    case lifeEvent
    case mood
    case sleep
    case dose

    var id: String { rawValue }
}

enum SettingsTab: String, CaseIterable, Identifiable, Equatable {
    case hydration
    case food
    case medication
    case location

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hydration: "Hydration"
        case .food: "Food"
        case .medication: "Medication"
        case .location: "Location"
        }
    }
}

@MainActor
@Observable
final class AppNavigation {
    var screen: Screen = .home
    var mapFocus: MapFocus?

    struct MapFocus: Equatable {
        var latitude: Double
        var longitude: Double
        var token: UUID
    }

    func showOnMap(latitude: Double, longitude: Double) {
        mapFocus = MapFocus(latitude: latitude, longitude: longitude, token: UUID())
        screen = .map
    }
}
