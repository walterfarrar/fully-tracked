import Foundation
import XCTest
@testable import FullyTracked

final class LocationCheckInPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let cell = LocationGridCell(latitude: 41.0001, longitude: -87.0001)

    func testSameCellWaitsOneHourFromLastSave() {
        XCTAssertFalse(LocationCheckInPolicy.shouldSave(
            cell: cell, previousCell: cell, lastSavedAt: start, now: start.addingTimeInterval(3599)
        ))
        XCTAssertTrue(LocationCheckInPolicy.shouldSave(
            cell: cell, previousCell: cell, lastSavedAt: start, now: start.addingTimeInterval(3600)
        ))
    }

    func testFirstCheckAndCellChangesSaveBeforeAnHour() {
        XCTAssertTrue(LocationCheckInPolicy.shouldSave(cell: cell, previousCell: nil, lastSavedAt: nil, now: start))
        let other = LocationGridCell(latitude: 41.002, longitude: -87.0001)
        XCTAssertTrue(LocationCheckInPolicy.shouldSave(
            cell: other, previousCell: cell, lastSavedAt: start, now: start.addingTimeInterval(600)
        ))
    }

    func testSmallMovementsWithinCellAreSkippedAndNegativeCoordinatesUseFloor() {
        let nearby = LocationGridCell(latitude: 41.0002, longitude: -87.0002)
        XCTAssertEqual(cell, nearby)
        let eitherSideOfZero = LocationGridCell(latitude: -0.0001, longitude: 0.0001)
        XCTAssertEqual(eitherSideOfZero.south, -LocationGridCell.degrees)
        XCTAssertEqual(eitherSideOfZero.west, 0)
    }

    func testSkippedCheckAdvancesCadenceWithoutPostponingHourlySave() {
        let skippedAt = start.addingTimeInterval(1800)
        XCTAssertFalse(LocationCheckInPolicy.isCheckDue(
            now: skippedAt.addingTimeInterval(1), intervalMinutes: 30,
            lastCheckedAt: skippedAt, lastSavedAt: start
        ))
        let next = start.addingTimeInterval(3600)
        XCTAssertTrue(LocationCheckInPolicy.isCheckDue(
            now: next, intervalMinutes: 30, lastCheckedAt: skippedAt, lastSavedAt: start
        ))
        XCTAssertTrue(LocationCheckInPolicy.shouldSave(cell: cell, previousCell: cell, lastSavedAt: start, now: next))
    }

    func testLongerIntervalsAndRecentManualSavesKeepTheirMinimumGap() {
        XCTAssertFalse(LocationCheckInPolicy.isCheckDue(
            now: start.addingTimeInterval(3600), intervalMinutes: 90,
            lastCheckedAt: start, lastSavedAt: start
        ))
        XCTAssertFalse(LocationCheckInPolicy.isCheckDue(
            now: start.addingTimeInterval(1800), intervalMinutes: 30,
            lastCheckedAt: start, lastSavedAt: start.addingTimeInterval(1700)
        ))
    }

    @MainActor
    func testMapDrawsOccupiedQuartersOfEachSaveCell() {
        XCTAssertEqual(HeatCell.degrees * 2, LocationGridCell.degrees, accuracy: 1e-12)
        let northwest = JournalEntry(type: .location, occurredAt: start)
        northwest.latitude = -0.0001
        northwest.longitude = 41.0001
        let sameQuarter = JournalEntry(type: .location, occurredAt: start)
        sameQuarter.latitude = -0.0002
        sameQuarter.longitude = 41.0002
        let southeast = JournalEntry(type: .location, occurredAt: start)
        southeast.latitude = -0.001
        southeast.longitude = 41.001

        let saveCell = LocationGridCell(latitude: northwest.latitude!, longitude: northwest.longitude!)
        XCTAssertEqual(saveCell, LocationGridCell(latitude: southeast.latitude!, longitude: southeast.longitude!))
        XCTAssertEqual(HeatCell.make(from: [northwest]).count, 1)

        let cells = HeatCell.make(from: [northwest, sameQuarter, southeast])
        XCTAssertEqual(cells.count, 2)
        XCTAssertEqual(Set(cells.map(\.count)), Set([1, 2]))
        for cell in cells {
            XCTAssertGreaterThanOrEqual(cell.south, saveCell.south - 1e-9)
            XCTAssertLessThanOrEqual(cell.north, saveCell.south + LocationGridCell.degrees + 1e-9)
            XCTAssertGreaterThanOrEqual(cell.west, saveCell.west - 1e-9)
            XCTAssertLessThanOrEqual(cell.east, saveCell.west + LocationGridCell.degrees + 1e-9)
            XCTAssertEqual(cell.north - cell.south, HeatCell.degrees, accuracy: 1e-9)
            XCTAssertEqual(cell.east - cell.west, HeatCell.degrees, accuracy: 1e-9)
        }
        XCTAssertNotEqual(cells[0].id, cells[1].id)
    }
}
