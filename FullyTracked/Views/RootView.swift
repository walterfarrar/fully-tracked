import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = AppNavigation()

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.screen) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Screen.home)
            LogView()
                .tabItem { Label("Log", systemImage: "list.bullet") }
                .tag(Screen.log)
            GraphsView()
                .tabItem { Label("Graphs", systemImage: "chart.bar") }
                .tag(Screen.graphs)
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Screen.map)
            CorrelationsView()
                .tabItem { Label("Compare", systemImage: "circle.grid.2x1") }
                .tag(Screen.correlations)
            AnalyzeView()
                .tabItem { Label("Analyze", systemImage: "magnifyingglass") }
                .tag(Screen.analyze)
        }
        .tint(Theme.ink)
        .toolbarBackground(Theme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .background(Theme.background.ignoresSafeArea())
        .environment(navigation)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                LocationTracker.shared.start()
            }
        }
        .task {
            JournalSeed.seed(context)
            LocationTracker.shared.start()
            HealthSteps.shared.start()
        }
    }
}
