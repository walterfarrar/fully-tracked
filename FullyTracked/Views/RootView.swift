import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var importingJournal = false
    @State private var importNote = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Import journal") {
                    importingJournal = true
                }
                .buttonStyle(.plain)
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            if !importNote.isEmpty {
                Text(importNote)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
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
        .fileImporter(isPresented: $importingJournal, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importJournal(from: url)
            case .failure:
                importNote = "The journal file could not be opened."
            }
        }
        .task {
            JournalSeed.seed(context)
            LocationTracker.shared.start()
            HealthSteps.shared.start()
        }
    }

    private func importJournal(from url: URL) {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let outcome = try JournalImporter.importJournal(data, context: context)
            var parts = ["Imported \(outcome.inserted)."]
            if outcome.skipped > 0 {
                parts.append("Skipped \(outcome.skipped) already saved.")
            }
            if outcome.rejected > 0 {
                parts.append("\(outcome.rejected) could not be read.")
            }
            importNote = parts.joined(separator: " ")
        } catch {
            importNote = error.localizedDescription
        }
    }
}

struct ScreenNav: View {
    @Binding var screen: Screen

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Screen.allCases) { item in
                Button {
                    screen = item
                } label: {
                    if item == .analyze {
                        AnalyzeBarIcon()
                    } else {
                        Text(item.title)
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(screen == item ? Theme.ink : Theme.muted)
                .accessibilityLabel(item.title)
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

private struct AnalyzeBarIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale, y: y * scale)
            }
            var lens = Path()
            lens.addEllipse(in: CGRect(x: 5.25 * scale, y: 5.25 * scale, width: 10.5 * scale, height: 10.5 * scale))
            var handle = Path()
            handle.move(to: point(14.5, 14.5))
            handle.addLine(to: point(19.5, 19.5))
            var lines = Path()
            lines.move(to: point(8.2, 10.5))
            lines.addLine(to: point(12.8, 10.5))
            lines.move(to: point(8.7, 8.6))
            lines.addLine(to: point(12.3, 8.6))
            let style = StrokeStyle(lineWidth: 1.75 * scale, lineCap: .round, lineJoin: .round)
            context.stroke(lens, with: .foreground, style: style)
            context.stroke(handle, with: .foreground, style: style)
            context.stroke(lines, with: .foreground, style: style)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
