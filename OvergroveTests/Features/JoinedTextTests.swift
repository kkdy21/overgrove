import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Values joined with `·` (or a name and its counts) fold between items, never inside one (#612).
@MainActor
final class JoinedTextTests: XCTestCase {
    /// Fewest lines first, keeping order; the one-item-per-line grouping is the view's fallback.
    func testGroupingsFromFewestLines() {
        XCTAssertEqual(JoinedText.groupings(count: 1), [[0..<1]])
        XCTAssertEqual(JoinedText.groupings(count: 2), [[0..<2]])
        XCTAssertEqual(JoinedText.groupings(count: 3), [[0..<3], [0..<2, 2..<3], [0..<1, 1..<3]])
        XCTAssertEqual(JoinedText.groupings(count: 4).first, [0..<4])
        XCTAssertFalse(JoinedText.groupings(count: 4).contains { $0.count == 4 }, "left to the fallback")
        XCTAssertTrue(JoinedText.groupings(count: 4).allSatisfy { $0.flatMap { Array($0) } == [0, 1, 2, 3] })
    }

    func testItemsDoNotBreakInside() {
        XCTAssertEqual(JoinedText.unbreakable("3 changed"), "3\u{00A0}changed")
        XCTAssertEqual(JoinedText.unbreakable("↑1 ↓0"), "↑1\u{00A0}↓0")
        XCTAssertEqual(JoinedText.joined(["a b", "c"]), "a b · c", "the plain text for VoiceOver and copying")
        XCTAssertEqual(JoinedText.joined(["origin/main", "↑1 ↓0"], separator: nil), "origin/main  ↑1 ↓0")
    }

    /// The models hand their items to the view; the joined value stays what it was.
    func testModelsGiveTheirItems() {
        let state = WorktreeListing.state(
            branch: "fix/57-token-refresh", staged: 1, unstaged: 2,
            upstream: .tracking(upstream: "origin/fix/57-token-refresh", ahead: 1, behind: 0))
        XCTAssertEqual(WorktreeDetailModel.stateItems(state).count, 3)
        XCTAssertEqual(
            WorktreeDetailModel.stateSummary(state), JoinedText.joined(WorktreeDetailModel.stateItems(state)))
    }

    /// Every width shows whole lines: the view never cuts a line in half, from one line down to one item per line.
    func testWholeLinesAtEveryWidth() throws {
        let view = JoinedText(items: ["3 changed", "0 untracked", "0 conflicts"]).font(Tokens.Font.callout)
        let oneLine = NSHostingView(rootView: view.fixedSize()).fittingSize.height
        XCTAssertGreaterThan(oneLine, 0)
        var heights: Set<Int> = []
        for width in stride(from: 100.0, through: 320.0, by: 20.0) {
            let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
            let lines = host.fittingSize.height / oneLine
            XCTAssertEqual(lines, lines.rounded(), accuracy: 0.05, "width \(width)")
            heights.insert(Int(lines.rounded()))
        }
        XCTAssertEqual(heights, [1, 2, 3], "folds to two lines, then one item per line")
    }

    /// The drawn command folds after `.` and `/`, never after `-`, and is the command once the marks are removed.
    func testCommandTextOnlyAddsInvisibleBreakMarks() {
        let command = "$ gh auth login --hostname git.internal.example.com"
        let drawn = CommandText.display(command)
        XCTAssertEqual(
            drawn.replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{2060}", with: ""), command
        )
        XCTAssertTrue(drawn.contains("-\u{2060}-\u{2060}hostname"), "no break inside --hostname")
        XCTAssertTrue(drawn.contains("git.\u{200B}internal.\u{200B}example.\u{200B}com"))
    }
}
