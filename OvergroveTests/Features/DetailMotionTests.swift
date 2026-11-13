import SwiftUI
import XCTest

@testable import Overgrove

/// The keys new content fades in on in the detail panel and the center area (#576): a change of kind fades, a new commit or file
/// of the same kind updates in place.
@MainActor
final class DetailMotionTests: XCTestCase {
    func testCenterScreenIsTheScreenOverTheGraph() {
        XCTAssertEqual(GraphPanel(hasRepository: true).screen, .graph)
        var panel = GraphPanel(hasRepository: true)
        panel.diff = (title: "a.swift", source: "Working tree", state: .loading)
        XCTAssertEqual(panel.screen, .diff)
        panel.diff?.state = .unavailable("gone")
        XCTAssertEqual(panel.screen, .diff, "a diff's own state does not change the screen")
    }

    func testDetailContentKind() {
        XCTAssertEqual(DetailPanel(focusedWorktree: nil).content, .empty)
    }

    func testLoadPhases() {
        XCTAssertEqual(DiffLoadState.loading.phase, .loading)
        XCTAssertEqual(DiffLoadState.unavailable("binary").phase, .failed)
        XCTAssertEqual(ComparisonModel.State.loading("Comparing…").phase, .loading)
        XCTAssertEqual(ComparisonModel.State.noChanges("Same").phase, .empty)
        XCTAssertEqual(ComparisonModel.State.failed(message: "x", canChooseBase: true).phase, .failed)
        XCTAssertEqual(ComparisonModel.State.loaded.phase, .loaded)
        XCTAssertEqual(CommitComparisonModel.State.noChanges("Same").phase, .empty)
        XCTAssertEqual(CommitComparisonModel.State.failed("x").phase, .failed)
        XCTAssertEqual(CommitDetailModel.Files.loading.phase, .loading)
        XCTAssertEqual(CommitDetailModel.Files.failed("x").phase, .failed)
        XCTAssertEqual(CommitDetailModel.Files.loaded(rows: [], hidden: 0).phase, .loaded)
        XCTAssertEqual(
            ComparisonModel.State.loading("a").phase, ComparisonModel.State.loading("b").phase,
            "new progress text under the same phase does not fade")
    }
}
