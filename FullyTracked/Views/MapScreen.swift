import MapKit
import SwiftData
import SwiftUI

struct MapScreen: View {
    @Environment(AppNavigation.self) private var navigation
    @EnvironmentObject private var tracker: LocationTracker
    @Query private var entries: [JournalEntry]
    @State private var follow = true
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var latestRegion: MKCoordinateRegion?
    @State private var appliedToken: UUID?

    private var points: [JournalEntry] {
        entries.filter { entry in
            guard entry.entryType == .location,
                  let latitude = entry.latitude,
                  let longitude = entry.longitude else { return false }
            return latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
        }
    }

    private var cells: [HeatCell] {
        HeatCell.make(from: points)
    }

    private var countLabel: String {
        switch points.count {
        case 0: ""
        case 1: "1 check-in"
        default: "\(points.count) check-ins"
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
            if points.isEmpty {
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
                        camera = .userLocation(fallback: .automatic)
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
            .accessibilityLabel(points.count == 1 ? "1 location check-in" : "\(points.count) location check-ins")
            if !tracker.lastEvent.isEmpty {
                Text(tracker.lastEvent)
                    .font(Theme.font(14))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background(Theme.background)
        .onAppear(perform: applyFocusIfNeeded)
        .onChange(of: navigation.mapFocus?.token) { _, _ in
            applyFocusIfNeeded()
        }
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
    static let degrees = 0.00125

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
        for entry in entries {
            guard let latitude = entry.latitude, let longitude = entry.longitude else { continue }
            let south = origin(latitude)
            let west = origin(longitude)
            let key = String(format: "%.5f,%.5f", locale: Locale(identifier: "en_US_POSIX"), south, west)
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

    private static func origin(_ value: Double) -> Double {
        (value / degrees).rounded(.down) * degrees
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
