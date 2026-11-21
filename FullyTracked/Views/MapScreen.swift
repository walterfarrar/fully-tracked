import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct MapScreen: View {
    @Query(filter: #Predicate<JournalEntry> { $0.typeRaw == "location" }) private var entries: [JournalEntry]

    var body: some View {
        // This view depends only on saved entries. Live location and camera
        // updates happen in the child without rebuilding the historical grid.
        let points = entries.filter { entry in
            guard entry.isLocationCheckIn,
                  let latitude = entry.latitude, let longitude = entry.longitude else { return false }
            return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
        }
        LiveCheckInMap(cells: HeatCell.make(from: points), checkInCount: points.count,
                       lastCheckInAt: points.map(\.occurredAt).max())
    }
}

private struct LiveCheckInMap: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tracker: LocationTracker
    @ObservedObject private var liveLocation = LocationTracker.shared.liveMapLocation
    let cells: [HeatCell]
    let checkInCount: Int
    let lastCheckInAt: Date?
    @State private var follow = true
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var latestRegion: MKCoordinateRegion?
    @State private var appliedToken: UUID?

    private var countLabel: String {
        switch checkInCount {
        case 0: ""
        case 1: "1 check-in"
        default: "\(checkInCount) check-ins"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Map")
                    .font(Theme.font(28, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(countLabel)
                    .font(Theme.font(12))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
            }
            if checkInCount == 0 {
                Text("Allow location to center this map. Visited cells darken with each check-in.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
            }
            HStack(spacing: 8) {
                CapsuleButton(title: "Follow me", filled: follow) {
                    if follow {
                        follow = false
                        if let latestRegion {
                            camera = .region(latestRegion)
                        }
                    } else {
                        follow = true
                        followLatestLocation()
                        tracker.refreshMapLocation()
                    }
                }
                CapsuleButton(title: tracker.checkingIn ? "Checking in" : "Check in now", filled: false) {
                    tracker.checkInNow()
                }
                .disabled(tracker.checkingIn)
                .opacity(tracker.checkingIn ? 0.45 : 1)
            }
            Map(position: $camera) {
                UserAnnotation()
                ForEach(cells) { cell in
                    MapPolygon(coordinates: cell.coordinates)
                        .foregroundStyle(cell.color.opacity(cell.opacity))
                }
            }
            .mapStyle(.standard)
            .onMapCameraChange(frequency: .continuous) { context in
                latestRegion = context.region
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { _ in
                    guard follow, let latestRegion else { return }
                    follow = false
                    camera = .region(latestRegion)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(Theme.surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)
            .accessibilityLabel(mapAccessLabel)
            if follow, let fix = liveLocation.fix {
                (Text("Latest location: ") + Text(fix.timestamp, style: .relative) + Text(" ago"))
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            if let lastCheckInAt {
                (Text("Last saved check-in: ") + Text(lastCheckInAt, style: .relative) + Text(" ago"))
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            } else {
                Text("No saved check-ins yet.")
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            if !tracker.lastEvent.isEmpty {
                Text(tracker.lastEvent)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
            WeatherAttributionView()
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(Theme.background)
        .onAppear {
            tracker.setMapVisible(true)
            applyFocusIfNeeded()
            if follow {
                followLatestLocation()
                tracker.refreshMapLocation()
            }
        }
        .onDisappear { tracker.setMapVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            tracker.setMapVisible(phase == .active && navigation.screen == .map)
            if phase == .active, navigation.screen == .map, follow {
                followLatestLocation()
                tracker.refreshMapLocation()
            }
        }
        .onChange(of: liveLocation.fix?.timestamp) { _, _ in
            if follow, navigation.screen == .map {
                followLatestLocation()
            }
        }
        .onChange(of: navigation.mapFocus?.token) { _, _ in
            applyFocusIfNeeded()
        }
    }

    private var mapAccessLabel: String {
        checkInCount == 1 ? "1 location check-in" : "\(checkInCount) location check-ins"
    }

    private func followLatestLocation() {
        let fallback: MapCameraPosition
        if let fix = liveLocation.fix,
           fix.latitude >= -90, fix.latitude <= 90,
           fix.longitude >= -180, fix.longitude <= 180 {
            fallback = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            ))
        } else {
            fallback = .automatic
        }
        camera = .userLocation(fallback: fallback)
    }

    private func applyFocusIfNeeded() {
        guard let focus = navigation.mapFocus, focus.token != appliedToken else { return }
        appliedToken = focus.token
        follow = false
        camera = .region(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
        )
    }
}

struct HeatCell: Identifiable {
    /// Half the save-policy cell on each side, so one policy cell is four map cells.
    static let degrees = LocationGridCell.degrees / 2

    var id: String
    var south: Double
    var west: Double
    var north: Double
    var east: Double
    var count: Int

    var coordinates: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: south, longitude: west),
            CLLocationCoordinate2D(latitude: south, longitude: east),
            CLLocationCoordinate2D(latitude: north, longitude: east),
            CLLocationCoordinate2D(latitude: north, longitude: west),
        ]
    }

    var color: Color { Self.color(count: count) }
    var opacity: Double { Self.opacity(count: count) }

    static func make(from entries: [JournalEntry]) -> [HeatCell] {
        var buckets: [String: HeatCell] = [:]
        let size = degrees
        for entry in entries {
            guard let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            let row = Int((latitude / size).rounded(.down))
            let column = Int((longitude / size).rounded(.down))
            let south = Double(row) * size
            let west = Double(column) * size
            let key = "\(row),\(column)"
            if var cell = buckets[key] {
                cell.count += 1
                buckets[key] = cell
            } else {
                buckets[key] = HeatCell(
                    id: key,
                    south: south,
                    west: west,
                    north: south + degrees,
                    east: west + degrees,
                    count: 1
                )
            }
        }
        return buckets.values.sorted { $0.count > $1.count }
    }

    private static func mix(count: Int) -> Double {
        min(1, max(0, Double(count - 1) / 99))
    }

    static func color(count: Int) -> Color {
        let mix = mix(count: count)
        return Color(
            red: (214 + (192 - 214) * mix) / 255,
            green: (236 + (48 - 236) * mix) / 255,
            blue: (196 + (42 - 196) * mix) / 255
        )
    }

    /// Visits darken the cell color, and denser cells are also more opaque.
    static func opacity(count: Int) -> Double {
        0.35 + 0.55 * min(1, Double(max(count, 1)) / 12)
    }
}
