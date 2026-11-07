import SwiftData
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
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
        case .correlations: "Correlations"
        case .analyze: "Analyze"
        }
    }
}

enum LogKind: String, CaseIterable, Identifiable {
    case location
    case meal
    case drink
    case bathroom
    case life
    case mood
    case sleep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .meal: "Meal"
        case .drink: "Drink"
        case .bathroom: "Bathroom"
        case .life: "Life event"
        case .mood: "Mood"
        case .sleep: "Sleep"
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var screen: Screen = .home
    @State private var logKind: LogKind = .meal

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch screen {
                case .home:
                    HomeView(screen: $screen, logKind: $logKind)
                case .log:
                    LogView(kind: $logKind)
                case .graphs:
                    GraphsView()
                case .map:
                    MapScreen()
                case .correlations:
                    CorrelationsView()
                case .analyze:
                    AnalyzeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ScreenNav(screen: $screen)
        }
        .background(Theme.background)
        .task {
            JournalSeed.seed(context)
            LocationTracker.shared.start()
            HealthSteps.shared.start()
        }
    }
}

struct ScreenNav: View {
    @Binding var screen: Screen

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Screen.allCases) { item in
                Button(item.title) {
                    screen = item
                }
                .buttonStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(screen == item ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(alignment: .top) {
                    if screen == item {
                        Rectangle().fill(Theme.ink).frame(height: 1)
                    }
                }
            }
        }
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}
