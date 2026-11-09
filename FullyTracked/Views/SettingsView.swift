import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var tracker: LocationTracker
    @Query private var entries: [JournalEntry]
    @Query private var amounts: [HydrationAmount]
    @Query private var foods: [FoodItem]
    @Query private var substances: [Substance]

    @State private var tab: SettingsTab
    @State private var note = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: JournalDocument?
    @State private var shareURL: URL?
    @State private var minutes = 30
    @State private var newLabel = ""
    @State private var newOunces = ""
    @State private var newFood = ""
    @State private var newSubstanceName = ""
    @State private var newSubstanceDose = ""
    @State private var newSubstanceUnit = "mg"

    init(initialTab: SettingsTab) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Settings")
                        .font(Theme.font(28, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .light))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                Button("Export journal", action: exportJournal)
                    .buttonStyle(QuietButtonStyle())
                Button("Import journal") { importing = true }
                    .buttonStyle(QuietButtonStyle())
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Text("Share journal")
                            .font(Theme.font(18))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 14)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(Theme.accent).frame(height: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(Theme.font(14))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(SettingsTab.allCases) { item in
                            Button {
                                tab = item
                            } label: {
                                Text(item.title)
                                    .font(Theme.font(16))
                                    .foregroundStyle(tab == item ? Theme.ink : Theme.muted)
                                    .padding(.bottom, 6)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(tab == item ? Theme.accent : Color.clear)
                                            .frame(height: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(tab == item ? .isSelected : AccessibilityTraits())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                switch tab {
                case .hydration:
                    hydrationPanel
                case .food:
                    foodPanel
                case .medication:
                    medicationPanel
                case .location:
                    locationPanel
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .presentationBackground(Theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            minutes = tracker.intervalMinutes
            refreshShare()
        }
        .onChange(of: entries.count) { _, _ in
            refreshShare()
        }
        .onChange(of: minutes) { _, newValue in
            tracker.setInterval(minutes: newValue)
            let stored = tracker.intervalMinutes
            if stored != minutes {
                minutes = stored
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importJournal(from: url)
            case .failure:
                note = "The journal file could not be opened."
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: JournalExporter.filename()
        ) { result in
            switch result {
            case .success:
                note = "Journal exported."
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                    return
                }
                note = error.localizedDescription
            }
        }
    }

    private var orderedAmounts: [HydrationAmount] {
        amounts.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var orderedFoods: [FoodItem] {
        foods.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var orderedSubstances: [Substance] {
        substances.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var hydrationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ounces per label.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
            if orderedAmounts.isEmpty {
                Text("None yet.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(orderedAmounts) { amount in
                HydrationAmountRow(amount: amount) {
                    CatalogStore.delete(amount, context: context)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                TextField("Label", text: $newLabel)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .textInputAutocapitalization(.never)
                TextField("Ounces", text: $newOunces)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: 110)
                Button("Add", action: addAmount)
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    private var foodPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if orderedFoods.isEmpty {
                Text("None yet.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(orderedFoods) { food in
                HStack {
                    Text(food.name)
                        .font(Theme.font(17))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove") {
                        CatalogStore.delete(food, context: context)
                    }
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
            AddRow(placeholder: "Food", text: $newFood, action: addFood)
        }
    }

    private var medicationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name, dose, unit.")
                .font(Theme.font(15))
                .foregroundStyle(Theme.muted)
            if orderedSubstances.isEmpty {
                Text("None yet.")
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.muted)
            }
            ForEach(orderedSubstances) { substance in
                SubstanceEditor(substance: substance) {
                    CatalogStore.delete(substance, context: context)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $newSubstanceName)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .textInputAutocapitalization(.words)
                TextField("Dose", text: $newSubstanceDose)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .keyboardType(.decimalPad)
                ChipFlow {
                    ForEach(JournalCatalog.doseUnits, id: \.self) { unit in
                        Chip(title: unit, selected: newSubstanceUnit == unit) {
                            newSubstanceUnit = unit
                        }
                    }
                }
                Button("Add", action: addSubstance)
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, 8)
        }
    }

    private var locationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldLabel(text: "Minutes")
            HStack(spacing: 12) {
                TextField("Minutes", value: $minutes, format: .number)
                    .textFieldStyle(.plain)
                    .underlineField()
                    .keyboardType(.numberPad)
                    .frame(maxWidth: 120)
                Stepper("Minutes", value: $minutes, in: 1...10_080, step: 1)
                    .labelsHidden()
            }
            FieldLabel(text: "Tracking")
            Picker("Tracking", selection: Binding(
                get: { tracker.trackingEnabled },
                set: { tracker.setTrackingEnabled($0) }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .pickerStyle(.segmented)
            .tint(Theme.accent)
            Text(tracker.statusLine)
                .font(Theme.font(14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addAmount() {
        guard let ounces = FormValues.decimal(newOunces) else { return }
        guard CatalogStore.addHydration(label: newLabel, ounces: ounces, existing: amounts, context: context) != nil else { return }
        newLabel = ""
        newOunces = ""
    }

    private func addFood() {
        guard CatalogStore.addFood(named: newFood, existing: foods, context: context) != nil else { return }
        newFood = ""
    }

    private func addSubstance() {
        guard let dose = FormValues.decimal(newSubstanceDose) else { return }
        guard CatalogStore.addSubstance(
            name: newSubstanceName,
            dose: dose,
            unit: newSubstanceUnit,
            existing: substances,
            context: context
        ) != nil else { return }
        newSubstanceName = ""
        newSubstanceDose = ""
    }

    private func exportJournal() {
        do {
            let data = try JournalExporter.data(entries: JournalMath.sortedNewest(entries))
            exportDocument = JournalDocument(data: data)
            shareURL = try writeShareFile(data)
            exporting = true
        } catch {
            note = "The journal could not be exported."
        }
    }

    private func refreshShare() {
        guard let data = try? JournalExporter.data(entries: JournalMath.sortedNewest(entries)) else {
            shareURL = nil
            return
        }
        shareURL = try? writeShareFile(data)
    }

    private func writeShareFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(JournalExporter.filename())
            .appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
        return url
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
            note = parts.joined(separator: " ")
            refreshShare()
        } catch {
            note = error.localizedDescription
        }
    }
}

private struct HydrationAmountRow: View {
    @Bindable var amount: HydrationAmount
    var onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @State private var ouncesText = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(amount.label)
                .font(Theme.font(17))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Ounces", text: $ouncesText)
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(Theme.font(17))
                .foregroundStyle(Theme.ink)
                .frame(width: 72)
            Button("Remove", action: onDelete)
                .font(Theme.font(15))
                .foregroundStyle(Theme.ink)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .onAppear { ouncesText = FormValues.display(amount.ounces) }
        .onSubmit(commit)
        .onChange(of: ouncesText) { _, _ in
            commit()
        }
    }

    private func commit() {
        guard let ounces = FormValues.decimal(ouncesText), ounces > 0 else { return }
        amount.ounces = ounces
        try? context.save()
    }
}

private struct SubstanceEditor: View {
    @Bindable var substance: Substance
    var onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @State private var doseText = ""
    @State private var originalName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Name", text: $substance.name)
                    .textFieldStyle(.plain)
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.ink)
                    .onSubmit(commitName)
                TextField("Dose", text: $doseText)
                    .textFieldStyle(.plain)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Theme.font(17))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 72)
                Button("Remove", action: onDelete)
                    .font(Theme.font(15))
                    .foregroundStyle(Theme.ink)
                    .buttonStyle(.plain)
            }
            ChipFlow {
                ForEach(JournalCatalog.doseUnits, id: \.self) { unit in
                    Chip(title: unit, selected: substance.unit == unit) {
                        substance.unit = unit
                        try? context.save()
                    }
                }
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .onAppear {
            doseText = FormValues.display(substance.dose)
            originalName = substance.name
        }
        .onChange(of: doseText) { _, _ in
            commitDose()
        }
    }

    private func commitName() {
        let clean = FormValues.clean(substance.name, limit: 80)
        substance.name = clean.isEmpty ? originalName : clean
        try? context.save()
    }

    private func commitDose() {
        guard let dose = FormValues.decimal(doseText), dose > 0 else { return }
        substance.dose = dose
        try? context.save()
    }
}
