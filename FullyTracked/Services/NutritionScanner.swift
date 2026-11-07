import Foundation
import UIKit
import Vision

struct NutritionDraft: Equatable {
    var servingSize = ""
    var calories = ""
    var totalFat = ""
    var saturatedFat = ""
    var cholesterol = ""
    var sodium = ""
    var carbohydrates = ""
    var fiber = ""
    var sugar = ""
    var protein = ""
    var message = ""

    var filledAny: Bool {
        [servingSize, calories, totalFat, saturatedFat, cholesterol, sodium, carbohydrates, fiber, sugar, protein]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum NutritionScanner {
    enum ScanError: Error {
        case unreadable
    }

    /// Reads a nutrition label in memory. The image is not written to the journal or to disk.
    static func read(_ image: UIImage) async throws -> NutritionDraft {
        guard let cgImage = image.cgImage else { throw ScanError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        return parse(lines)
    }

    static func parse(_ lines: [String]) -> NutritionDraft {
        var draft = NutritionDraft()
        var nutrientLines = lines
        if let index = nutrientLines.firstIndex(where: { $0.lowercased().contains("serving size") }) {
            draft.servingSize = servingSize(from: nutrientLines, index: index)
            nutrientLines.remove(at: index)
        }

        let rules: [(String, WritableKeyPath<NutritionDraft, String>)] = [
            ("saturated fat", \.saturatedFat),
            ("cholesterol", \.cholesterol),
            ("sodium", \.sodium),
            ("dietary fiber", \.fiber),
            ("total fiber", \.fiber),
            ("fiber", \.fiber),
            ("total sugars", \.sugar),
            ("sugars", \.sugar),
            ("sugar", \.sugar),
            ("total carbohydrate", \.carbohydrates),
            ("carbohydrate", \.carbohydrates),
            ("protein", \.protein),
            ("total fat", \.totalFat),
            ("calories", \.calories),
        ]

        for line in nutrientLines {
            let lowered = line.lowercased()
            if lowered.contains("calories from fat") { continue }
            for (name, keyPath) in rules where lowered.contains(name) && draft[keyPath: keyPath].isEmpty {
                if let number = firstNumber(in: line) {
                    draft[keyPath: keyPath] = number
                }
                break
            }
        }

        if draft.filledAny {
            draft.message = "This scan is a draft to check. Missing facts were left blank. The photo was not saved."
        } else {
            draft.message = "No nutrition facts were read. Nothing was filled in. The photo was not saved."
        }
        return draft
    }

    private static func servingSize(from lines: [String], index: Int) -> String {
        let line = lines[index]
        let lowered = line.lowercased()
        guard let range = lowered.range(of: "serving size") else { return "" }
        let rest = line[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " :.-"))
        if !rest.isEmpty { return String(rest) }
        let next = index + 1
        guard next < lines.count else { return "" }
        let candidate = lines[next].trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().contains("serving") || candidate.lowercased().contains("amount") {
            return ""
        }
        return candidate
    }

    private static func firstNumber(in line: String) -> String? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)"#
        guard let match = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[match])
    }
}
