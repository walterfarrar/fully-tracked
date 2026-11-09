import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var tracker: LocationTracker
    @State private var checkIn: CheckInKind?
    @State private var settings: SettingsTab?
    @State private var queuedSettings: SettingsTab?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Fully Tracked")
                    .font(Theme.font(13))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)
                HStack(alignment: .center) {
                    Text("Log")
                        .font(Theme.font(28, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button {
                        settings = .hydration
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(.top, 6)

                LazyVGrid(columns: columns, spacing: 12) {
                    actionButton("Location", symbol: "mappin.and.ellipse") {
                        tracker.checkInNow()
                    }
                    .disabled(tracker.checkingIn)
                    .opacity(tracker.checkingIn ? 0.45 : 1)
                    actionButton("Meal", symbol: "fork.knife") { checkIn = .meal }
                    actionButton("Hydration", symbol: "drop") { checkIn = .hydration }
                    actionButton("Bathroom", symbol: "toilet") { checkIn = .bathroom }
                    actionButton("Life event", symbol: "calendar") { checkIn = .lifeEvent }
                    actionButton("Mood", symbol: "face.smiling") { checkIn = .mood }
                    actionButton("Sleep", symbol: "moon") { checkIn = .sleep }
                    actionButton("Dose", symbol: "pills") { checkIn = .dose }
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text(tracker.statusLine)
                    if tracker.checkingIn {
                        Text("Reading location…")
                    }
                    if !tracker.lastEvent.isEmpty {
                        Text(tracker.lastEvent)
                    }
                }
                .font(Theme.font(14))
                .foregroundStyle(Theme.muted)
                .padding(.top, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .background(Theme.background)
        .sheet(item: $checkIn) { kind in
            CheckInSheet(kind: kind) { tab in
                queuedSettings = tab
                checkIn = nil
            }
        }
        .sheet(item: $settings) { tab in
            SettingsView(initialTab: tab)
        }
        .onChange(of: checkIn) { _, newValue in
            guard newValue == nil, let tab = queuedSettings else { return }
            queuedSettings = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                settings = tab
            }
        }
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                Text(title)
                    .font(Theme.font(17))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
