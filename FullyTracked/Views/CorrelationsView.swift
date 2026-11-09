import SwiftData
import SwiftUI

struct CorrelationsView: View {
    @Query private var entries: [JournalEntry]
    @State private var comparison: ComparisonKind = .meals

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Compare")
                    .font(Theme.font(28, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Picker("Comparison", selection: $comparison) {
                    ForEach(ComparisonKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Theme.accent)
                Text(JournalMath.sentence(entries, comparison: comparison))
                    .font(Theme.font(20))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(JournalMath.comparisonNote)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }
}
