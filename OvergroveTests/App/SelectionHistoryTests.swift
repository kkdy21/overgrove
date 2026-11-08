import Foundation
import XCTest

@testable import Overgrove

/// `SelectionHistory` (#378, interaction.md §1.4): back and forward over the main selection.
final class SelectionHistoryTests: XCTestCase {
    private let a = GitPath("/dev/api")
    private let b = GitPath("/dev/api-wt/42")
    private func oid(_ character: Character) -> ObjectID { ObjectID(String(repeating: character, count: 40))! }
    private func entry(_ selection: MainSelection, focus: GitPath? = nil) -> SelectionHistory.Entry {
        SelectionHistory.Entry(selection: selection, focus: focus ?? a)
    }

    func testBackAndForwardLikeABrowser() {
        var history = SelectionHistory()
        XCTAssertFalse(history.canGoBack)
        history.record(entry(.wip(a)))
        history.record(entry(.commit(oid("1"))))
        history.record(entry(.stash(oid("2"))))
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        XCTAssertEqual(history.goBack { _ in true }, entry(.commit(oid("1"))))
        XCTAssertEqual(history.goBack { _ in true }, entry(.wip(a)))
        XCTAssertNil(history.goBack { _ in true })
        XCTAssertEqual(history.goForward { _ in true }, entry(.commit(oid("1"))))

        // A new choice after going back drops the forward entries.
        history.record(entry(.issue(7)))
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack { _ in true }, entry(.commit(oid("1"))))
    }

    /// The same target again, or the other segment of the same worktree, is not a new entry (§1.4).
    func testSameTargetAndSegmentSwitchesAreNotNewEntries() {
        var history = SelectionHistory()
        history.record(entry(.commit(oid("1"))))
        history.record(entry(.wip(a)))
        history.record(entry(.worktreeInfo(a)))
        history.record(entry(.worktreeInfo(a)))
        XCTAssertEqual(history.goBack { _ in true }, entry(.commit(oid("1"))))
        XCTAssertEqual(history.goForward { _ in true }, entry(.worktreeInfo(a)), "the latest segment is kept")
        history.record(entry(.wip(b), focus: b))
        XCTAssertEqual(history.goBack { _ in true }, entry(.worktreeInfo(a)), "another worktree is a new entry")
    }

    /// A selection the app set itself (a refresh's fallback) replaces the current entry instead of adding one.
    func testReplacingTheCurrentEntryAddsNothing() {
        var history = SelectionHistory()
        history.record(entry(.wip(a)))
        history.record(entry(.stash(oid("2"))))
        history.replaceCurrent(entry(.wip(a)))
        XCTAssertEqual(history.goBack { _ in true }, entry(.wip(a)))
        XCTAssertNil(history.goBack { _ in true })
    }

    /// Entries whose target is gone are skipped and dropped; with nothing left, nothing moves.
    func testMissingTargetsAreSkippedAndDropped() {
        var history = SelectionHistory()
        history.record(entry(.wip(a)))
        history.record(entry(.stash(oid("2"))))
        history.record(entry(.commit(oid("3"))))
        let gone: (SelectionHistory.Entry) -> Bool = { $0.selection != .stash(self.oid("2")) }
        XCTAssertEqual(history.goBack(isAvailable: gone), entry(.wip(a)))
        XCTAssertEqual(history.goForward(isAvailable: gone), entry(.commit(oid("3"))), "the stash was dropped")

        var empty = SelectionHistory()
        empty.record(entry(.wip(a)))
        empty.record(entry(.stash(oid("2"))))
        XCTAssertNil(empty.goBack { _ in false })
        XCTAssertEqual(empty.current, entry(.stash(oid("2"))), "stays where it was")
        XCTAssertFalse(empty.canGoBack, "the missing entry was dropped")
    }

    func testAtMostFiftyEntriesOldestDropped() {
        var history = SelectionHistory()
        for index in 0..<(SelectionHistory.maximumEntries + 10) {
            history.record(entry(.issue(index)))
        }
        var steps = 0
        var last: SelectionHistory.Entry?
        while let previous = history.goBack(isAvailable: { _ in true }) {
            steps += 1
            last = previous
        }
        XCTAssertEqual(steps, SelectionHistory.maximumEntries - 1)
        XCTAssertEqual(last, entry(.issue(10)))
    }

    func testClear() {
        var history = SelectionHistory()
        history.record(entry(.wip(a)))
        history.record(entry(.issue(1)))
        history.clear()
        XCTAssertFalse(history.canGoBack)
        XCTAssertNil(history.current)
    }
}
