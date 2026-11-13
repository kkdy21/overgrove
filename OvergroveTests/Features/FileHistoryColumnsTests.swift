import XCTest

@testable import Overgrove

/// S-09's fixed columns give way to Message in a narrow centre (#579).
final class FileHistoryColumnsTests: XCTestCase {
    func testEveryColumnShowsWhenMessageHasRoom() {
        let columns = FileHistoryColumns(width: 820)
        XCTAssertEqual(columns.visible, Set(FileHistoryColumns.Column.allCases))
        XCTAssertGreaterThanOrEqual(columns.messageWidth(in: 820), GraphColumnLayout.messageMinimum)
    }

    /// At the centre's minimum (480 pt) the four fixed columns left Message about 100 pt, so the subject read "com…".
    func testAuthorGivesWayFirstAtTheMinimumWidth() {
        let columns = FileHistoryColumns(width: 480)
        XCTAssertEqual(columns.visible, [.date, .stat])
        XCTAssertGreaterThanOrEqual(columns.messageWidth(in: 480), GraphColumnLayout.messageMinimum)
    }

    func testColumnsGiveWayInOrderAsTheWidthShrinks() {
        XCTAssertEqual(FileHistoryColumns(width: 400).visible, [.date])
        XCTAssertEqual(FileHistoryColumns(width: 300).visible, [])
        XCTAssertEqual(FileHistoryColumns(width: 0).visible, [], "nothing left to hide; Message takes what remains")
    }

    /// Each step hides only what it must: one point wider than a threshold keeps the column.
    func testThresholdsAreExact() {
        let all =
            FileHistoryColumns.commitWidth + GraphColumnLayout.messageMinimum
            + FileHistoryColumns.Column.allCases.reduce(0) { $0 + $1.width }
        XCTAssertEqual(FileHistoryColumns(width: all).visible.count, 3)
        XCTAssertFalse(FileHistoryColumns(width: all - 1).shows(.author))
        XCTAssertTrue(FileHistoryColumns(width: all - 1).shows(.stat))
    }
}
