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
    func testMapAndSavePolicyUseTheSameGridBoundaries() {
        let entry = JournalEntry(type: .location, occurredAt: start)
        entry.latitude = -0.0001
        entry.longitude = 41.0001
        let gridCell = LocationGridCell(latitude: entry.latitude!, longitude: entry.longitude!)
        let mapCell = HeatCell.make(from: [entry]).first
        XCTAssertEqual(mapCell?.south, gridCell.south)
        XCTAssertEqual(mapCell?.west, gridCell.west)
    }
}
