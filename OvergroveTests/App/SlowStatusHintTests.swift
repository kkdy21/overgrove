import XCTest

@testable import Overgrove

/// The slow-status hint (#168): shown above 1 s, explains the stale index, and never runs anything.
@MainActor
final class SlowStatusHintTests: XCTestCase {
    func testThresholdAndText() throws {
        XCTAssertNil(SlowStatusHint(duration: nil, isConfigurationClean: true))
        XCTAssertNil(SlowStatusHint(duration: .milliseconds(1_000), isConfigurationClean: true))
        let clean = try XCTUnwrap(SlowStatusHint(duration: .milliseconds(5_220), isConfigurationClean: true))
        XCTAssertEqual(clean.short, "Status 5.2 s")
        XCTAssertTrue(clean.message.hasPrefix("Status took 5.2 s."))
        XCTAssertTrue(clean.message.contains("Overgrove does not write the index"))
        XCTAssertTrue(clean.message.contains("only for a repository you trust"))
        XCTAssertEqual(clean.command, "git status")
    }

    /// Terminal git runs the repository's settings, so a repository with findings gets no command (#200).
    func testNoCommandWhenTheConfigurationHasFindings() throws {
        let hint = try XCTUnwrap(SlowStatusHint(duration: .seconds(3), isConfigurationClean: false))
        XCTAssertNil(hint.command)
        XCTAssertFalse(hint.message.contains("git status"))
    }

    func testRefreshIntervalBacksOff() {
        XCTAssertEqual(SlowStatusHint.minimumRefreshInterval(after: nil), .seconds(2))
        XCTAssertEqual(SlowStatusHint.minimumRefreshInterval(after: .milliseconds(30)), .seconds(2))
        XCTAssertEqual(SlowStatusHint.minimumRefreshInterval(after: .milliseconds(5_220)), .milliseconds(52_200))
    }

    /// S-05 and the status bar show it for a slow worktree; an uninspected entry gets no command.
    func testShownInWorktreeDetailAndStatusBar() throws {
        var listing = WorktreeListing.mockup
        let index = try XCTUnwrap(listing.entries.firstIndex { $0.worktree.branch == "refs/heads/feat/42-rate-limit" })
        let entries = listing.entries.enumerated().map { offset, entry in
            WorktreeListing.Entry(
                worktree: entry.worktree, state: entry.state, inspection: entry.inspection,
                statusDuration: offset == index ? .seconds(4) : .milliseconds(40))
        }
        listing = WorktreeListing(entries: entries, isPartial: false)
        let slow = listing.entries[index]

        let detail = WorktreeDetailModel(entry: slow, inspection: nil, fetchStatus: .never, now: Date())
        XCTAssertEqual(detail.slowStatus?.short, "Status 4.0 s")
        XCTAssertNil(detail.slowStatus?.command, "not inspected: no Terminal suggestion")
        XCTAssertNil(
            WorktreeDetailModel(entry: listing.entries[0], inspection: nil, fetchStatus: .never, now: Date()).slowStatus
        )

        let snapshot = WorktreeListModel.snapshot(listing: listing, focused: slow.worktree.path)
        let items = StatusBarItem.items(snapshot: snapshot, fetchStatus: .never, ghStatus: nil, now: Date())
        let item = try XCTUnwrap(items.first { $0.kind == .slowStatus })
        XCTAssertEqual(item.text, "Status 4.0 s")
        XCTAssertEqual(item.tone, .warning)
        XCTAssertNotNil(item.help)
        let fast = WorktreeListModel.snapshot(listing: listing, focused: listing.entries[0].worktree.path)
        XCTAssertFalse(
            StatusBarItem.items(snapshot: fast, fetchStatus: .never, ghStatus: nil, now: Date())
                .contains { $0.kind == .slowStatus })
    }
}
