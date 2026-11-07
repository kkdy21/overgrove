import Foundation
import XCTest

@testable import Overgrove

/// `WorktreeListModel` (#65): information-architecture.md §4.2–§4.4 from a load, without views.
final class WorktreeListModelTests: XCTestCase {
    private typealias Listing = WorktreeListing

    private func model(_ listing: WorktreeListing = .mockup, focused: GitPath? = nil) -> WorktreeListModel {
        WorktreeListModel(listing: listing, focused: focused, home: "/tmp/dev")
    }

    private func row(_ title: String, in model: WorktreeListModel) throws -> WorktreeRow {
        try XCTUnwrap(model.rows.first { $0.title == title }, title)
    }

    /// §4.2: main first; branches and detached folders by name; prunable last.
    func testOrder() {
        XCTAssertEqual(
            model().rows.map(\.title),
            ["main", "feat/42-rate-limit", "fix/login", "hotfix", "detached @ c46c37d", "spike/cache"])
    }

    /// §4.4: names and second lines.
    func testNames() throws {
        let model = model()
        let main = try row("main", in: model)
        XCTAssertTrue(main.isMain)
        XCTAssertEqual(main.subtitle, "~/api", "the main worktree shows its path, home as ~")

        XCTAssertEqual(try row("feat/42-rate-limit", in: model).subtitle, "42-rate-limit", "folder name differs")
        XCTAssertEqual(try row("hotfix", in: model).subtitle, nil, "folder name equals the branch")

        let detached = try row("detached @ c46c37d", in: model)
        XCTAssertEqual(detached.subtitle, "review")
        XCTAssertTrue(detached.hasNeutralTile)

        let prunable = try row("spike/cache", in: model)
        XCTAssertEqual(prunable.subtitle, "path missing")
        XCTAssertTrue(prunable.isSubtitleWarning)
        XCTAssertTrue(prunable.isDimmed)
        XCTAssertTrue(prunable.hasNeutralTile)
    }

    /// art-direction.md §6 (#255): a branch's tile takes its tip's lane colour from the graph; detached and missing
    /// worktrees, and tips not loaded yet, stay neutral.
    func testTilesTakeTheLaneColourOfTheBranchTip() throws {
        XCTAssertTrue(model().rows.allSatisfy { $0.laneIndex == nil }, "no graph yet")

        let tip = try XCTUnwrap(ObjectID("a91f3c2000000000000000000000000000000000"))
        let model = WorktreeListModel(
            listing: .mockup, focused: nil, home: "/tmp/dev", laneIndex: { $0 == tip ? 3 : nil })
        XCTAssertEqual(try row("main", in: model).laneIndex, 3)
        XCTAssertEqual(try row("feat/42-rate-limit", in: model).laneIndex, 3)
        XCTAssertNil(try row("detached @ c46c37d", in: model).laneIndex, "detached: neutral")
        XCTAssertNil(try row("spike/cache", in: model).laneIndex, "missing: neutral")

        let unloaded = WorktreeListModel(listing: .mockup, focused: nil, home: "/tmp/dev", laneIndex: { _ in nil })
        XCTAssertTrue(unloaded.rows.allSatisfy { $0.laneIndex == nil }, "tip not in a loaded page")
    }

    /// §4.3: badges in priority order, zero hidden.
    func testBadges() throws {
        let model = model()
        XCTAssertEqual(try row("main", in: model).badges, [])
        XCTAssertEqual(try row("feat/42-rate-limit", in: model).badges, [.changed(6), .ahead(2)])
        XCTAssertEqual(try row("fix/login", in: model).badges, [.conflicts(1), .changed(1), .behind(3)])
        XCTAssertEqual(try row("hotfix", in: model).badges, [.locked])
        XCTAssertEqual(try row("spike/cache", in: model).badges, [.prunable])
    }

    func testChangedCountsDistinctPathsAndCapsAt999() {
        let shared = FileChange(path: GitPath("a.swift"), status: .modified)
        let state = WorkingState(
            headCommit: nil, head: .branch("main"), upstream: .none, stashCount: 0, staged: [shared],
            unstaged: [shared], untracked: [], conflicted: [], isPartial: false, skippedRecords: 0)
        XCTAssertEqual(WorktreeListModel.changedCount(state), 1, "MM counts once")
        XCTAssertEqual(WorktreeListModel.badgeText(999), "999")
        XCTAssertEqual(WorktreeListModel.badgeText(1000), "999+")
    }

    /// Detached comes from `worktree list` (no `branch` attribute), not from the status header.
    func testDetachedFollowsTheWorktreeList() throws {
        let listing = Listing(
            entries: [
                Listing.entry(
                    "/tmp/dev/x", branch: nil, head: "c46c37d0000000000000000000000000000000aa", isMain: true,
                    state: .loaded(Listing.state(branch: "main")))
            ],
            isPartial: false)
        XCTAssertEqual(model(listing).rows.map(\.title), ["detached @ c46c37d"])
        XCTAssertNil(WorktreeListModel.snapshot(listing: listing, focused: nil).focusedWorktree?.branch)
    }

    /// Lock reasons, paths, and branch names are escaped: no control or bidi characters reach the screen.
    func testTextFromTheRepositoryIsEscaped() throws {
        let listing = Listing(
            entries: [
                Listing.entry(
                    "/tmp/dev/evil\u{202E}gpj.app", branch: "feat/x\u{2028}y", isMain: true,
                    lock: .locked(reason: "line\none\u{202E}"), state: .loaded(Listing.state(branch: "feat/x")))
            ],
            isPartial: false)
        let row = try XCTUnwrap(model(listing).rows.first)
        XCTAssertEqual(row.title, "feat/x\\u{2028}y")
        XCTAssertEqual(row.subtitle, "~/evil\\u{202E}gpj.app")
        XCTAssertTrue(row.help.contains("Locked: line\\u{A}one\\u{202E}"), row.help)
        for text in [
            row.title, row.subtitle ?? "", row.help.replacingOccurrences(of: "\n", with: ""),
            row.accessibilityLabel,
        ] {
            XCTAssertFalse(
                text.unicodeScalars.contains {
                    [.format, .control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                }, text)
        }
    }

    /// Parser warnings do not block the list (parsing-spec.md §1.5, §1.6).
    func testWarningForPartialOrSkippedOutput() {
        XCTAssertNil(model().warning)
        let partialList = Listing(entries: WorktreeListing.mockup.entries, isPartial: true)
        XCTAssertEqual(
            model(partialList).warning, "Some worktrees could not be listed because git's output was too large.")

        for state in [Listing.state(branch: "main", isPartial: true), Listing.state(branch: "main", skippedRecords: 2)]
        {
            let listing = Listing(
                entries: [Listing.entry("/tmp/dev/x", branch: "main", isMain: true, state: .loaded(state))],
                isPartial: false)
            XCTAssertEqual(model(listing).warning, "Some changes could not be read, so counts may be incomplete.")
            XCTAssertEqual(model(listing).rows.count, 1, "the list still shows")
        }
    }

    /// #243: a list that hit the per-load query limit (#226) says so above the rows, with the partial-list note.
    func testWarningForQueryLimitedList() {
        let limited = Listing(
            entries: WorktreeListing.mockup.entries + [
                Listing.entry("/tmp/dev/api-wt/extra", branch: "extra", state: .notQueried(.limit))
            ],
            isPartial: true)
        XCTAssertTrue(limited.isQueryLimited)
        XCTAssertFalse(WorktreeListing.mockup.isQueryLimited)
        let limit = RepositoryService.defaultMaximumQueriedWorktrees
        XCTAssertEqual(
            model(limited).warning,
            "Some worktrees could not be listed because git's output was too large. This repository lists more than "
                + "\(limit) worktrees. Overgrove loads the changes of the first \(limit).")
        XCTAssertEqual(model(limited).rows.count, 7, "the warning does not hide rows")
    }

    func testRowsForWorktreesWithoutStatus() throws {
        let listing = Listing(
            entries: [
                Listing.entry("/tmp/dev/main", branch: "main", isMain: true, state: .missing),
                Listing.entry("/tmp/dev/a", branch: "a", state: .failed(.timeout(seconds: 10))),
                Listing.entry("/tmp/dev/b", branch: "b", state: .notQueried(.foreignRepository)),
                Listing.entry("/tmp/dev/c", branch: "c", state: .notQueried(.inspectionBlocked("core.fsmonitor"))),
                Listing.entry("/tmp/dev/d", branch: "d", state: .notQueried(.duplicate)),
                Listing.entry("/tmp/dev/e", branch: "e", state: .notQueried(.limit)),
            ],
            isPartial: false)
        let rows = model(listing).rows
        XCTAssertEqual(rows.map(\.title), ["main", "a", "b", "c", "d", "e"], "the main worktree stays first")
        XCTAssertEqual(
            rows.map(\.subtitle),
            [
                "path missing", "Status unavailable", "Not part of this repository", "Blocked for safety",
                "Same folder as another entry", "Not loaded",
            ])
        XCTAssertTrue(rows.allSatisfy(\.isSubtitleWarning))
        XCTAssertTrue(rows[1].help.contains("git did not respond within 10 seconds"), rows[1].help)
        XCTAssertTrue(rows[3].help.contains("core.fsmonitor"))
        XCTAssertTrue(rows.allSatisfy { $0.badges.isEmpty })
    }

    /// `RepositoryOverview` (#87) → `WorktreeListing`: prunable and a folder that vanished before `status` are both
    /// "missing", not "Status unavailable".
    func testOverviewMapping() {
        let worktrees = WorktreeListing.mockup.entries.map(\.worktree)
        let statuses: [RepositoryOverview.Status] = [
            .loaded(Listing.state(branch: "main")), .failed(.worktreeMissing(path: "/tmp/dev/x")),
            .failed(.timeout(seconds: 15)), .notQueried(.foreignRepository),
            .notQueried(.inspectionBlocked("reason")), .notQueried(.prunable),
        ]
        let overview = RepositoryOverview(
            entries: zip(worktrees, statuses).map { RepositoryOverview.Entry(worktree: $0, status: $1) },
            isWorktreeListPartial: true,
            refs: RefParser.Listing(branches: [], tags: [], isPartial: false, skippedRecords: 0),
            stashes: StashParser.Listing(stashes: [], isPartial: false),
            inspection: RepoConfigInspector.inspect(ConfigParser.Listing(entries: [], isPartial: false)))
        XCTAssertEqual(
            WorktreeListing(overview: overview).entries.map(\.state),
            [
                .loaded(Listing.state(branch: "main")), .missing, .failed(.timeout(seconds: 15)),
                .notQueried(.foreignRepository), .notQueried(.inspectionBlocked("reason")), .missing,
            ])
        XCTAssertEqual(WorktreeListing(overview: overview).entries.map(\.worktree), worktrees)
        XCTAssertTrue(WorktreeListing(overview: overview).isPartial, "a truncated worktree list is reported (#88)")
    }

    func testBareEntriesAreHidden() {
        let listing = Listing(
            entries: [
                WorktreeListing.Entry(
                    worktree: Worktree(
                        path: GitPath("/tmp/dev/repo.git"), head: nil, branch: nil, isMain: true, isDetached: false,
                        isBare: true, lock: .unlocked, isPrunable: false, prunableReason: nil),
                    state: .notQueried(.bare)),
                Listing.entry("/tmp/dev/wt", branch: "main", state: .loaded(Listing.state(branch: "main"))),
            ],
            isPartial: false)
        XCTAssertEqual(model(listing).rows.map(\.title), ["main"])
        XCTAssertEqual(WorktreeListModel.snapshot(listing: listing, focused: nil).worktreeCount, 1)
    }

    func testFocusDefaultsToTheMainWorktree() throws {
        XCTAssertEqual(model().rows.filter(\.isFocused).map(\.title), ["main"])
        let focused = model(focused: GitPath("/tmp/dev/api-wt/login"))
        XCTAssertEqual(focused.rows.filter(\.isFocused).map(\.title), ["fix/login"])
        XCTAssertEqual(
            model(focused: GitPath("/tmp/dev/gone")).rows.filter(\.isFocused).map(\.title), ["main"],
            "an unknown path falls back to main")
    }

    func testSnapshotForTheToolbarAndStatusBar() {
        let snapshot = WorktreeListModel.snapshot(
            listing: .mockup, focused: GitPath("/tmp/dev/api-wt/42-rate-limit"))
        XCTAssertEqual(snapshot.worktreeCount, 6)
        XCTAssertEqual(snapshot.prunableCount, 1)
        XCTAssertEqual(snapshot.focusedWorktree?.title, "feat/42-rate-limit")
        XCTAssertEqual(snapshot.focusedWorktree?.aheadBadge, "↑2")
    }

    func testTooltipAndVoiceOverCarryEveryBadge() throws {
        let model = model(focused: GitPath("/tmp/dev/api-wt/login"))
        let login = try row("fix/login", in: model)
        XCTAssertEqual(
            login.accessibilityLabel, "fix/login, worktree, focused, 1 conflicted, 1 changed, 3 behind")
        XCTAssertEqual(
            login.help,
            "~/api-wt/login\n1 conflicted · 0 staged · 1 unstaged · 0 untracked\n↑0 ↓3 vs origin/fix/login")
        let hotfix = try row("hotfix", in: model)
        XCTAssertEqual(hotfix.accessibilityLabel, "hotfix, worktree, locked, release in progress")
        XCTAssertTrue(hotfix.help.hasSuffix("Locked: release in progress"))
        XCTAssertEqual(
            try row("spike/cache", in: model).accessibilityLabel, "spike/cache, worktree, prunable, path missing")
    }
}
