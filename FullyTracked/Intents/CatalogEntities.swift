import AppIntents
import SwiftData

struct DrinkEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Drink", numericFormat: nil)
    static var defaultQuery = DrinkEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: nil, image: nil)
    }
}

struct DrinkEntityQuery: EntityStringQuery {
    func entities(for identifiers: [DrinkEntity.ID]) async throws -> [DrinkEntity] {
        let wanted = Set(identifiers)
        let catalog = await MainActor.run { Self.catalog() }
        return catalog.filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DrinkEntity] {
        await MainActor.run { Self.catalog() }
    }

    func entities(matching string: String) async throws -> [DrinkEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = await MainActor.run { Self.catalog() }
        guard !needle.isEmpty else { return catalog }
        return catalog
            .filter { $0.name.localizedCaseInsensitiveContains(needle) }
            .sorted { lhs, rhs in
                let leftExact = lhs.name.caseInsensitiveCompare(needle) == .orderedSame
                let rightExact = rhs.name.caseInsensitiveCompare(needle) == .orderedSame
                if leftExact != rightExact { return leftExact }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    @MainActor
    private static func catalog() -> [DrinkEntity] {
        let drinks = (try? SharedContainer.context.fetch(FetchDescriptor<Drink>())) ?? []
        let ordered = drinks.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        var seen = Set<String>()
        var entities: [DrinkEntity] = []
        for drink in ordered {
            let name = drink.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard seen.insert(name.lowercased()).inserted else { continue }
            entities.append(DrinkEntity(id: name, name: name))
        }
        return entities
    }
}

struct SubstanceEntity: AppEntity, Sendable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Substance", numericFormat: nil)
    static var defaultQuery = SubstanceEntityQuery()

    var id: String
    var name: String
    var dose: Double
    var unit: String

    var displayRepresentation: DisplayRepresentation {
        let amount = FormValues.display(dose)
        let detail = unit.isEmpty ? amount : "\(amount) \(unit)"
        return DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: nil)
    }
}

struct SubstanceEntityQuery: EntityStringQuery {
    func entities(for identifiers: [SubstanceEntity.ID]) async throws -> [SubstanceEntity] {
        let wanted = Set(identifiers)
        let catalog = await MainActor.run { Self.catalog() }
        return catalog.filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SubstanceEntity] {
        await MainActor.run { Self.catalog() }
    }

    func entities(matching string: String) async throws -> [SubstanceEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalog = await MainActor.run { Self.catalog() }
        guard !needle.isEmpty else { return catalog }
        return catalog.filter { entity in
            entity.name.localizedCaseInsensitiveContains(needle)
                || entity.unit.localizedCaseInsensitiveContains(needle)
        }
    }

    @MainActor
    private static func catalog() -> [SubstanceEntity] {
        let substances = (try? SharedContainer.context.fetch(FetchDescriptor<Substance>())) ?? []
        let ordered = substances.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }
        return ordered.map { item in
            SubstanceEntity(
                id: item.uuid.uuidString,
                name: item.name,
                dose: item.dose,
                unit: item.unit
            )
        }
    }
}
