import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AnalystError: LocalizedError {
    case emptyQuestion

    var errorDescription: String? {
        switch self {
        case .emptyQuestion:
            "Enter a question."
        }
    }
}

@MainActor
final class OnDeviceAnalyst: ObservableObject {
    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    @Published private(set) var availability: Availability

    init() {
        availability = Self.detect()
    }

    func refreshAvailability() {
        availability = Self.detect()
    }

    func answer(question: String, entries: [JournalEntry]) async throws -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AnalystError.emptyQuestion }
        let limited = String(trimmed.prefix(500))
        refreshAvailability()
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = availability {
            do {
                let text = try await AppleJournalModel.answer(question: limited, entries: entries)
                if !text.isEmpty { return text }
            } catch {
                if AppleJournalModel.isContextLimit(error) {
                    return InsightEngine.answer(question: limited, entries: entries)
                }
                throw error
            }
        }
        #endif
        return InsightEngine.answer(question: limited, entries: entries)
    }

    func dailyInsight(entries: [JournalEntry], days: Int = 7) async throws -> String {
        InsightEngine.insight(entries: entries, days: days)
    }

    private static func detect() -> Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return AppleJournalModel.availability()
        }
        #endif
        return .unavailable(reason: "Apple Intelligence needs iOS 26.")
    }
}

#if canImport(FoundationModels)
@available(iOS 26, *)
@MainActor
private enum AppleJournalModel {
    static func availability() -> OnDeviceAnalyst.Availability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "This iPhone cannot run Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "Apple Intelligence is turned off.")
            case .modelNotReady:
                return .unavailable(reason: "The on-device model is still getting ready.")
            @unknown default:
                return .unavailable(reason: "The on-device model is unavailable.")
            }
        }
    }

    static func answer(question: String, entries: [JournalEntry]) async throws -> String {
        let spans = [30, 14, 7]
        for (index, days) in spans.enumerated() {
            let session = makeSession(entries: entries, days: days)
            do {
                let response = try await session.respond(to: question)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                guard isContextLimit(error), index < spans.count - 1 else { throw error }
            }
        }
        return ""
    }

    static func isContextLimit(_ error: Error) -> Bool {
        // iOS 27 adds LanguageModelError.contextSizeExceeded, but that symbol is
        // absent from the iOS 26 SDK that CI builds with, so only the iOS 26
        // error is matched here. Add the iOS 27 case once CI is on Xcode 27.
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize(_) = generation {
            return true
        }
        return false
    }

    private static func makeSession(entries: [JournalEntry], days: Int) -> LanguageModelSession {
        let rows = JournalRollups.summaries(entries, days: days)
        let lines = JournalRollups.searchLines(entries, days: days)
        let tools: [any Tool] = [
            DaySummaryTool(summaries: rows),
            MoodFactorTool(summaries: rows),
            SearchEntriesTool(lines: lines),
            PlacesTool(summaries: rows),
        ]
        let today = JournalRollups.dayLabel(.now)
        return LanguageModelSession(tools: tools) {
            """
            You are the on-device assistant for a personal journal.
            Answer only from tool results. Do not invent entries, scores, places, or causes.
            Use plain language. Do not diagnose or give medical advice.
            Mention how many days or entries a figure comes from.
            Today is \(today). Daily lines are oldest first.
            """
        }
    }
}

@available(iOS 26, *)
struct DaySummaryTool: Tool {
    let name = "daySummaries"
    let description = "Daily journal totals. Each line starts with a date, oldest first."

    let summaries: [DaySummary]

    @Generable
    struct Arguments {
        @Guide(description: "How many recent days to include, from 1 to 30.")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let count = min(30, max(1, arguments.days))
        let slice = Array(summaries.suffix(count))
        let text = JournalRollups.toCompactText(slice)
        if text.isEmpty { return "No journal totals in the last \(slice.count) days." }
        return JournalRollups.clip("window=\(slice.count) days\n\(text)")
    }
}

@available(iOS 26, *)
@Generable
enum ModelMoodFactor: String, CaseIterable {
    case coffee
    case shortSleep
    case rain
}

@available(iOS 26, *)
struct MoodFactorTool: Tool {
    let name = "compareMood"
    let description = "Compares mood on days with and without coffee, short sleep, or rain."

    let summaries: [DaySummary]

    @Generable
    struct Arguments {
        @Guide(description: "coffee, short sleep under 6 hours, or rain.")
        var factor: ModelMoodFactor
    }

    func call(arguments: Arguments) async throws -> String {
        let factor: MoodFactor
        switch arguments.factor {
        case .coffee: factor = .coffee
        case .shortSleep: factor = .shortSleep
        case .rain: factor = .rain
        }
        let split = JournalRollups.split(summaries, factor: factor)
        return JournalRollups.clip(JournalRollups.factorLine(split, factor: factor))
    }
}

@available(iOS 26, *)
struct SearchEntriesTool: Tool {
    let name = "searchJournal"
    let description = "Finds journal lines that contain the given words."

    let lines: [String]

    @Generable
    struct Arguments {
        @Guide(description: "Words to find in the journal.")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        let needle = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return "No search text." }
        let hits = lines.filter { $0.lowercased().contains(needle) }
        if hits.isEmpty { return "No journal lines matched." }
        return JournalRollups.clip(hits.prefix(20).joined(separator: "\n"))
    }
}

@available(iOS 26, *)
struct PlacesTool: Tool {
    let name = "listPlaces"
    let description = "Location check-ins, rounded coordinates, and weather for recent days."

    let summaries: [DaySummary]

    @Generable
    struct Arguments {
        @Guide(description: "How many recent days to include, from 1 to 30.")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let count = min(30, max(1, arguments.days))
        var lines: [String] = []
        for day in summaries.suffix(count) where day.checkIns > 0 || !day.distinctPlaces.isEmpty {
            var line = "\(JournalRollups.dayLabel(day.day)) in=\(day.checkIns)"
            if !day.distinctPlaces.isEmpty {
                line += " places=\(day.distinctPlaces.joined(separator: "|"))"
            }
            if let temp = day.avgTempF {
                line += " temp=\(JournalRollups.number(temp))F"
            }
            if !day.conditions.isEmpty {
                line += " sky=\(day.conditions.joined(separator: "|"))"
            }
            lines.append(line)
        }
        if lines.isEmpty { return "No location check-ins in that span." }
        return JournalRollups.clip(lines.joined(separator: "\n"))
    }
}
#endif
