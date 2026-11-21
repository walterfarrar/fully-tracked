import Foundation

/// Save-policy cell. The map draws four quarters of this cell and skips empty ones.
struct LocationGridCell: Equatable, Sendable {
    static let degrees = 0.00125

    let south: Double
    let west: Double

    init(latitude: Double, longitude: Double) {
        south = (latitude / Self.degrees).rounded(.down) * Self.degrees
        west = (longitude / Self.degrees).rounded(.down) * Self.degrees
    }
}

enum LocationCheckInPolicy {
    static let sameCellSaveInterval: TimeInterval = 60 * 60

    static func isCheckDue(
        now: Date,
        intervalMinutes: Int,
        lastCheckedAt: Date?,
        lastSavedAt: Date?
    ) -> Bool {
        let anchor = [lastCheckedAt, lastSavedAt].compactMap { $0 }.max()
        guard let anchor else { return true }
        return now.timeIntervalSince(anchor) >= TimeInterval(intervalMinutes * 60)
    }

    static func shouldSave(
        cell: LocationGridCell,
        previousCell: LocationGridCell?,
        lastSavedAt: Date?,
        now: Date
    ) -> Bool {
        guard let previousCell, let lastSavedAt else { return true }
        return cell != previousCell || now.timeIntervalSince(lastSavedAt) >= sameCellSaveInterval
    }
}
