import Security
import SwiftData
import SwiftUI

struct AnalyzeView: View {
    @Query private var entries: [JournalEntry]
    @StateObject private var analyst = OnDeviceAnalyst()
    @State private var insightDays = 7
    @State private var insight = ""
    @State private var insightError = ""
    @State private var loadingInsight = false
    @State private var question = ""
    @State private var answer = ""
    @State private var answerError = ""
    @State private var asking = false

    private let suggestions = [
        "How did I sleep this week?",
        "Does coffee affect my mood?",
        "Where was I yesterday?",
        "What did I eat on bad mood days?",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Analyze")
                        .font(Theme.font(28, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(availabilityLine)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    FieldLabel(text: "Insights")
                    Picker("Insight window", selection: $insightDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .tint(Theme.accent)
                    if loadingInsight, insight.isEmpty {
                        Text("Looking through the journal…")
                            .font(Theme.font(17))
                            .foregroundStyle(Theme.muted)
                    }
                    if !insightError.isEmpty {
                        Text(insightError)
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.danger)
                    }
                    if !insight.isEmpty {
                        Text(insight)
                            .font(Theme.font(17))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FieldLabel(text: "Ask")
                    TextField("Question", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.ink)
                        .textFieldStyle(.plain)
                        .underlineField()
                        .submitLabel(.send)
                        .onSubmit { Task { await ask() } }
                    ChipRow(titles: suggestions, isSelected: { $0 == question }) { title in
                        Task { await ask(title) }
                    }
                    Button(asking ? "Asking" : "Ask") {
                        Task { await ask() }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(asking ? 0.45 : 1)
                    if !answerError.isEmpty {
                        Text(answerError)
                            .font(Theme.font(15))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if asking, answer.isEmpty {
                        Text("Looking through the journal…")
                            .font(Theme.font(17))
                            .foregroundStyle(Theme.muted)
                    }
                    if !answer.isEmpty {
                        Text(answer)
                            .font(Theme.font(17))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                Text("Nothing leaves this phone.")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.muted)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            LegacyAnalyzeKeyWipe.run()
            analyst.refreshAvailability()
        }
        .task(id: insightToken) {
            await loadInsight()
        }
    }

    private var availabilityLine: String {
        switch analyst.availability {
        case .available:
            "On-device Apple Intelligence"
        case .unavailable(let reason):
            "Pattern summary only on this device: \(reason)"
        }
    }

    private var insightToken: String {
        let latest = entries.map { max($0.savedAt, $0.occurredAt).timeIntervalSinceReferenceDate }.max() ?? 0
        return "\(insightDays)|\(entries.count)|\(latest)"
    }

    private func loadInsight() async {
        let days = insightDays
        loadingInsight = true
        insightError = ""
        defer { loadingInsight = false }
        do {
            let text = try await analyst.dailyInsight(entries: entries, days: days)
            guard !Task.isCancelled, days == insightDays else { return }
            insight = text
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            insight = ""
            insightError = error.localizedDescription
        }
    }

    private func ask(_ preset: String? = nil) async {
        if let preset { question = preset }
        let trimmed = (preset ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !asking else { return }
        asking = true
        answer = ""
        answerError = ""
        defer { asking = false }
        do {
            let text = try await analyst.answer(question: trimmed, entries: entries)
            answer = text
        } catch {
            answerError = error.localizedDescription
        }
    }
}

private enum LegacyAnalyzeKeyWipe {
    static func run() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "fully-tracked-analyze",
        ]
        SecItemDelete(query as CFDictionary)
    }
}
