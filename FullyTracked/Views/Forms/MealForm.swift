import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct MealForm: View {
    var openSettings: (SettingsTab) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var foods: [FoodItem]
    @State private var when = Date()
    @State private var selected: [String] = []
    @State private var drafts: [String: PortionDraft] = [:]
    @State private var amountHadText = ""
    @State private var draft = NutritionDraft()
    @State private var showFacts = false
    @State private var scanning = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var error = ""

    private var orderedFoods: [FoodItem] {
        foods.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        CheckInChrome(title: "Meal", when: $when, error: $error, saveTitle: "Save meal", save: save) {
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Foods")
                if orderedFoods.isEmpty {
                    Text("None yet.")
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                } else {
                    ChipRow(
                        titles: orderedFoods.map(\.name),
                        isSelected: { selected.contains($0) },
                        onTap: toggleFood
                    )
                }
                ForEach(selected, id: \.self) { name in
                    weightRow(name)
                }
                GearButton(label: "Food") { openSettings(.food) }
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Nutrition label")
                HStack(spacing: 8) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            photoLabel("Take photo")
                        }
                        .buttonStyle(.plain)
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        photoLabel("Choose photo")
                    }
                    .buttonStyle(.plain)
                }
                if scanning {
                    ProgressView()
                        .tint(Theme.accent)
                }
                if !draft.message.isEmpty {
                    Text(draft.message)
                        .font(Theme.font(15))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showFacts {
                    factField("Serving size", text: $draft.servingSize, decimal: false)
                    factField("Calories", text: $draft.calories, decimal: true)
                    factField("Total fat", text: $draft.totalFat, decimal: true)
                    factField("Saturated fat", text: $draft.saturatedFat, decimal: true)
                    factField("Cholesterol", text: $draft.cholesterol, decimal: true)
                    factField("Sodium", text: $draft.sodium, decimal: true)
                    factField("Carbohydrates", text: $draft.carbohydrates, decimal: true)
                    factField("Fiber", text: $draft.fiber, decimal: true)
                    factField("Sugar", text: $draft.sugar, decimal: true)
                    factField("Protein", text: $draft.protein, decimal: true)
                }
            }
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "How much did you have?")
                TextField("1 serving", text: $amountHadText)
                    .textFieldStyle(.plain)
                    .underlineField()
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                Task { @MainActor in
                    showCamera = false
                    if let image {
                        await scan(image)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    private func photoLabel(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(15))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
    }

    private func weightRow(_ name: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(name)
                .font(Theme.font(16))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Weight", text: weightBinding(name))
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .font(Theme.font(17))
                .foregroundStyle(Theme.ink)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
                .frame(width: 88)
            Chip(title: "g", selected: (drafts[name]?.unit ?? "g") == "g") {
                setUnit(name, "g")
            }
            Chip(title: "oz", selected: drafts[name]?.unit == "oz") {
                setUnit(name, "oz")
            }
        }
        .padding(.top, 8)
    }

    private func factField(_ title: String, text: Binding<String>, decimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: title)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .underlineField()
                .keyboardType(decimal ? .decimalPad : .default)
        }
        .padding(.top, 4)
    }

    private func toggleFood(_ name: String) {
        if let index = selected.firstIndex(of: name) {
            selected.remove(at: index)
            drafts[name] = nil
        } else {
            selected.append(name)
            if drafts[name] == nil {
                drafts[name] = PortionDraft()
            }
        }
    }

    private func weightBinding(_ name: String) -> Binding<String> {
        Binding(
            get: { drafts[name]?.weight ?? "" },
            set: { newValue in
                var portion = drafts[name] ?? PortionDraft()
                portion.weight = newValue
                drafts[name] = portion
            }
        )
    }

    private func setUnit(_ name: String, _ unit: String) {
        var portion = drafts[name] ?? PortionDraft()
        portion.unit = unit
        drafts[name] = portion
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        scanning = true
        defer {
            scanning = false
            photoItem = nil
        }
        do {
            guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else {
                failScan()
                return
            }
            await scan(picked.image)
        } catch {
            failScan()
        }
    }

    private func scan(_ image: UIImage) async {
        scanning = true
        defer { scanning = false }
        do {
            draft = try await NutritionScanner.read(normalized(image))
            showFacts = true
        } catch {
            failScan()
        }
    }

    private func failScan() {
        var failed = NutritionDraft()
        failed.message = "No nutrition facts were read. Nothing was filled in. The photo was not saved."
        draft = failed
        showFacts = true
    }

    private func normalized(_ image: UIImage) -> UIImage {
        let maxSide: CGFloat = 1600
        let largest = max(image.size.width, image.size.height)
        let scale = largest > maxSide && largest > 0 ? maxSide / largest : 1
        let size = CGSize(width: max(image.size.width * scale, 1), height: max(image.size.height * scale, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func save() {
        error = ""
        var portions: [(name: String, weight: Double, unit: String)] = []
        for name in selected {
            guard let portion = drafts[name] else {
                error = "Enter a weight."
                return
            }
            guard let weight = FormValues.decimal(portion.weight), weight > 0 else {
                error = "Enter a weight."
                return
            }
            let unit = portion.unit == "oz" ? "oz" : "g"
            portions.append((name, weight, unit))
        }
        let facts: NutritionNumbers
        do {
            facts = try nutritionNumbers()
        } catch {
            self.error = "Check the nutrition numbers."
            return
        }
        let amountHad = FormValues.clean(amountHadText, limit: 80)
        if portions.isEmpty && !facts.filled {
            error = "Choose a food."
            return
        }
        if facts.filled && amountHad.isEmpty {
            error = "Enter how much you had."
            return
        }
        let entry = JournalEntry(type: .meal, occurredAt: when)
        if portions.isEmpty {
            entry.descriptionText = nil
            entry.foodsJSON = nil
        } else {
            entry.descriptionText = portions
                .map { "\($0.name) · \(FormValues.display($0.weight)) \($0.unit)" }
                .joined(separator: ", ")
            let objects: [[String: Any]] = portions.map { ["name": $0.name, "unit": $0.unit, "weight": $0.weight] }
            if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                entry.foodsJSON = text
            }
        }
        entry.amountHad = amountHad.isEmpty ? nil : amountHad
        if facts.filled {
            entry.servingSize = facts.servingSize
            entry.calories = facts.calories
            entry.totalFat = facts.totalFat
            entry.saturatedFat = facts.saturatedFat
            entry.cholesterol = facts.cholesterol
            entry.sodium = facts.sodium
            entry.carbohydrates = facts.carbohydrates
            entry.fiber = facts.fiber
            entry.sugar = facts.sugar
            entry.protein = facts.protein
        }
        do {
            try JournalSave.commit(entry, in: context)
            dismiss()
        } catch {
            self.error = "The entry could not be saved."
        }
    }

    private func nutritionNumbers() throws -> NutritionNumbers {
        var numbers = NutritionNumbers()
        let serving = FormValues.clean(draft.servingSize, limit: 80)
        numbers.servingSize = serving.isEmpty ? nil : serving
        try read(draft.calories, into: &numbers.calories)
        try read(draft.totalFat, into: &numbers.totalFat)
        try read(draft.saturatedFat, into: &numbers.saturatedFat)
        try read(draft.cholesterol, into: &numbers.cholesterol)
        try read(draft.sodium, into: &numbers.sodium)
        try read(draft.carbohydrates, into: &numbers.carbohydrates)
        try read(draft.fiber, into: &numbers.fiber)
        try read(draft.sugar, into: &numbers.sugar)
        try read(draft.protein, into: &numbers.protein)
        return numbers
    }

    private func read(_ text: String, into value: inout Double?) throws {
        switch FormValues.readDecimal(text) {
        case .empty:
            value = nil
        case .value(let number):
            value = number
        case .invalid:
            throw MealFormError.invalidNumber
        }
    }
}

private struct PortionDraft {
    var weight = ""
    var unit = "g"
}

private struct NutritionNumbers {
    var servingSize: String?
    var calories: Double?
    var totalFat: Double?
    var saturatedFat: Double?
    var cholesterol: Double?
    var sodium: Double?
    var carbohydrates: Double?
    var fiber: Double?
    var sugar: Double?
    var protein: Double?

    var filled: Bool {
        if let servingSize, !servingSize.isEmpty { return true }
        return [calories, totalFat, saturatedFat, cholesterol, sodium, carbohydrates, fiber, sugar, protein].contains { $0 != nil }
    }
}

private enum MealFormError: Error {
    case invalidNumber
}
