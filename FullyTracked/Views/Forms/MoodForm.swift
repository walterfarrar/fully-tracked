import SwiftData
import SwiftUI

struct MoodForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var emotions: [Emotion]
    @State private var when = Date()
    @State private var score = 6
    @State private var picked: Set<String> = []
    @State private var newEmotion = ""
    @State private var error = ""

    private var ordered: [Emotion] {
        emotions.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var scoreBinding: Binding<Double> {
        Binding(
            get: { Double(score) },
            set: { score = Int($0.rounded()) }
        )
    }

    var body: some View {
        CheckInChrome(title: "Mood", when: $when, error: $error, saveTitle: "Save mood", save: save) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Score")
                HStack(alignment: .center, spacing: 16) {
                    MoodFace(score: score)
                    Text("\(score)")
                        .font(Theme.font(28, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                Slider(value: scoreBinding, in: 1...10, step: 1)
                    .tint(Theme.accent)
                    .accessibilityLabel("Score")
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Emotions")
                ChipRow(
                    titles: ordered.map(\.name),
                    isSelected: { picked.contains($0) },
                    onTap: toggle
                )
                AddRow(placeholder: "Add an emotion", text: $newEmotion, action: addEmotion)
            }
            .padding(.top, 8)
        }
    }

    private func toggle(_ name: String) {
        if picked.contains(name) {
            picked.remove(name)
        } else {
            picked.insert(name)
        }
    }

    private func addEmotion() {
        guard let emotion = CatalogStore.addEmotion(named: newEmotion, existing: emotions, context: context) else { return }
        picked.insert(emotion.name)
        newEmotion = ""
    }

    private func save() {
        error = ""
        guard (1...10).contains(score) else {
            error = "Choose a score from 1 to 10."
            return
        }
        let entry = JournalEntry(type: .mood, occurredAt: when)
        entry.moodScore = score
        let names = ordered.map(\.name).filter { picked.contains($0) }
        entry.emotions = names.isEmpty ? nil : names
        let entryID = entry.id
        let when = entry.occurredAt
        let savedScore = score
        let savedEmotions = entry.emotions ?? []
        do {
            try JournalSave.commit(entry, in: context)
        } catch {
            self.error = "The entry could not be saved."
            return
        }
        Task {
            await HealthWriter.writeMood(
                entryID: entryID,
                occurredAt: when,
                score: savedScore,
                emotions: savedEmotions
            )
        }
        dismiss()
    }
}

private struct MoodFace: View {
    var score: Int

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            let style = StrokeStyle(lineWidth: 1.75 * scale, lineCap: .round, lineJoin: .round)
            var face = Path()
            face.addEllipse(in: CGRect(x: 4 * scale, y: 4 * scale, width: 16 * scale, height: 16 * scale))
            context.stroke(face, with: .color(Theme.accent), style: style)

            var eyes = Path()
            eyes.addEllipse(in: CGRect(x: 8.4 * scale, y: 9.4 * scale, width: 1.2 * scale, height: 1.2 * scale))
            eyes.addEllipse(in: CGRect(x: 14.4 * scale, y: 9.4 * scale, width: 1.2 * scale, height: 1.2 * scale))
            context.fill(eyes, with: .color(Theme.accent))

            var mouth = Path()
            switch score {
            case ...2:
                mouth.move(to: point(8, 16, scale))
                mouth.addCurve(to: point(12, 13.8, scale), control1: point(9.2, 14.4, scale), control2: point(10.4, 13.8, scale))
                mouth.addCurve(to: point(16, 16, scale), control1: point(13.6, 13.8, scale), control2: point(14.8, 14.4, scale))
            case 3...4:
                mouth.move(to: point(8.5, 15.5, scale))
                mouth.addCurve(to: point(12, 14.1, scale), control1: point(9.6, 14.5, scale), control2: point(10.7, 14.1, scale))
                mouth.addCurve(to: point(15.5, 15.5, scale), control1: point(13.3, 14.1, scale), control2: point(14.4, 14.5, scale))
            case 5...6:
                mouth.move(to: point(8.5, 15, scale))
                mouth.addLine(to: point(15.5, 15, scale))
            case 7...8:
                mouth.move(to: point(8.5, 14.2, scale))
                mouth.addCurve(to: point(12, 15.8, scale), control1: point(9.6, 15.3, scale), control2: point(10.8, 15.8, scale))
                mouth.addCurve(to: point(15.5, 14.2, scale), control1: point(13.2, 15.8, scale), control2: point(14.4, 15.3, scale))
            default:
                mouth.move(to: point(8, 13.5, scale))
                mouth.addCurve(to: point(12, 16.5, scale), control1: point(9.2, 15.5, scale), control2: point(10.6, 16.5, scale))
                mouth.addCurve(to: point(16, 13.5, scale), control1: point(13.4, 16.5, scale), control2: point(14.8, 15.5, scale))
            }
            context.stroke(mouth, with: .color(Theme.accent), style: style)
        }
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> CGPoint {
        CGPoint(x: x * scale, y: y * scale)
    }
}
