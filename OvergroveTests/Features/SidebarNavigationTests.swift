import Foundation
import XCTest

@testable import Overgrove

/// The sidebar as one keyboard focus unit (interaction.md §1.2, #592): order, skipped rows, start position, moves.
final class SidebarNavigationTests: XCTestCase {
    private func oid(_ character: Character) -> ObjectID { ObjectID(String(repeating: character, count: 40))! }
    private let main = GitPath("/tmp/dev/repo")
    private let feature = GitPath("/tmp/dev/repo-wt/feature")

    private func branch(_ name: String, tip: ObjectID, type: GitObjectType = .commit) -> Branch {
        var branch = Branch(
            fullName: name, kind: name.hasPrefix("refs/remotes/") ? .remote(remote: "origin") : .local,
            target: tip, upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil)
        branch.objectType = type
        return branch
    }

    /// LOCAL `main` (tip a), `feat/x` (tip b, in folder `feat/`), `tree` (no tip); REMOTE `origin/main` (tip a);
    /// tags `v1` (commit c) and `tree-tag` (none); one stash; issues 12 and 42.
    private func content(
        expanded: Set<SidebarSection> = Set(SidebarSection.allCases), openFolders: Set<String> = [],
        filtered: Bool = false
    ) -> SidebarNavigation.Content {
        let refs = RefParser.Listing(
            branches: [
                branch("refs/heads/main", tip: oid("a")), branch("refs/heads/feat/x", tip: oid("b")),
                branch("refs/heads/tree", tip: oid("e"), type: .tree),
                branch("refs/remotes/origin/main", tip: oid("a")),
            ],
            tags: [
                Tag(fullName: "refs/tags/v1", target: oid("c"), peeledTarget: nil, date: nil, objectType: .commit),
                Tag(fullName: "refs/tags/tree-tag", target: oid("d"), peeledTarget: nil, date: nil, objectType: .tree),
            ], isPartial: false, skippedRecords: 0)
        // The `tree` branch points to a tree: no tip in the graph (#567).
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: ["origin"])
        return SidebarNavigation.Content(
            worktrees: [main, feature], local: model.local, remote: model.remote, tags: model.tags.rows,
            stashes: [oid("5")], issues: [42, 12], expanded: expanded,
            openFolders: [.local: openFolders, .remote: ["remote:origin"]], isFiltered: filtered)
    }

    func testOrderSkipsFoldersClosedFoldersAndRowsWithoutATip() {
        XCTAssertEqual(
            SidebarNavigation.items(content()),
            [
                .worktree(main), .worktree(feature), .branch(id: "refs/heads/main", tip: oid("a")),
                .branch(id: "refs/remotes/origin/main", tip: oid("a")), .tag(id: "refs/tags/v1", commit: oid("c")),
                .stash(oid("5")), .issue(42), .issue(12),
            ])
        let opened = SidebarNavigation.items(content(openFolders: ["local/feat"]))
        XCTAssertTrue(opened.contains(.branch(id: "refs/heads/feat/x", tip: oid("b"))), "an open folder's rows")
        let filtered = SidebarNavigation.items(content(filtered: true))
        XCTAssertTrue(filtered.contains(.branch(id: "refs/heads/feat/x", tip: oid("b"))), "the filter opens folders")
    }

    func testCollapsedSectionsAreSkipped() {
        let items = SidebarNavigation.items(content(expanded: [.worktrees, .issues]))
        XCTAssertEqual(items, [.worktree(main), .worktree(feature), .issue(42), .issue(12)])
    }

    /// Review of #598: the chosen branch or tag row comes before the stash, the issue, and the focused worktree.
    func testPositionPrefersTheChosenRefThenStashThenIssueThenWorktree() {
        let items = SidebarNavigation.items(content())
        var selection = SidebarNavigation.Selection(
            focusedWorktree: feature, selectedCommit: oid("c"), selectedStash: nil, selectedIssue: 12)
        func position(_ chosen: String?) -> SidebarNavigation.Position {
            SidebarNavigation.position(in: items, cursor: nil, chosenRef: chosen, selection: selection)
        }
        XCTAssertEqual(position("refs/tags/v1"), .at(4), "the tag row, not the worktree")
        XCTAssertEqual(position(nil), .at(7), "no chosen row: the selected issue")
        selection.selectedStash = oid("5")
        XCTAssertEqual(position(nil), .at(5), "the stash before the issue")
        selection = .init(focusedWorktree: feature, selectedCommit: oid("9"), selectedStash: nil, selectedIssue: nil)
        XCTAssertEqual(position("refs/tags/v1"), .at(1), "a graph commit no row names: the focused worktree")
    }

    /// Two branches share tip a: the chosen one is the position, and a stale cursor yields to the selection.
    func testTheChosenRowAmongBranchesWithOneTipAndAStaleCursor() {
        let items = SidebarNavigation.items(content())
        let selection = SidebarNavigation.Selection(focusedWorktree: main, selectedCommit: oid("a"))
        XCTAssertEqual(
            SidebarNavigation.position(
                in: items, cursor: nil, chosenRef: "refs/remotes/origin/main", selection: selection), .at(3))
        XCTAssertEqual(
            SidebarNavigation.position(
                in: items, cursor: .item(.branch(id: "refs/heads/main", tip: oid("a"))), chosenRef: nil,
                selection: selection), .at(2), "the cursor, still selected")
        XCTAssertEqual(
            SidebarNavigation.position(
                in: items, cursor: .item(.stash(oid("5"))), chosenRef: nil, selection: selection),
            .at(0), "the stash is no longer selected: from the selection")
    }

    /// Review of #598: after `⌘4` the next `↓` picks the first issue and `↑` the row before ISSUES, unless an issue is
    /// selected.
    func testCommandFourAnchorsBeforeTheFirstIssue() {
        let items = SidebarNavigation.items(content())
        var selection = SidebarNavigation.Selection(focusedWorktree: main, selectedCommit: nil)
        var position = SidebarNavigation.position(
            in: items, cursor: .issuesStart, chosenRef: nil, selection: selection)
        XCTAssertEqual(position, .before(6))
        XCTAssertEqual(SidebarNavigation.move(in: items, from: position, down: true, toEnd: false), .issue(42))
        XCTAssertEqual(SidebarNavigation.move(in: items, from: position, down: false, toEnd: false), .stash(oid("5")))
        selection.selectedIssue = 12
        position = SidebarNavigation.position(in: items, cursor: .issuesStart, chosenRef: nil, selection: selection)
        XCTAssertEqual(position, .at(7))
    }

    func testMovesAcrossSectionsAndAtTheEnds() {
        let items = SidebarNavigation.items(content())
        XCTAssertEqual(
            SidebarNavigation.move(in: items, from: .at(1), down: true, toEnd: false),
            .branch(id: "refs/heads/main", tip: oid("a")), "WORKTREES → LOCAL")
        XCTAssertEqual(SidebarNavigation.move(in: items, from: .at(5), down: true, toEnd: false), .issue(42))
        XCTAssertNil(SidebarNavigation.move(in: items, from: .at(7), down: true, toEnd: false), "already last")
        XCTAssertNil(SidebarNavigation.move(in: items, from: .at(0), down: false, toEnd: false), "already first")
        XCTAssertEqual(SidebarNavigation.move(in: items, from: .at(3), down: true, toEnd: true), .issue(12))
        XCTAssertEqual(SidebarNavigation.move(in: items, from: .at(3), down: false, toEnd: true), .worktree(main))
        XCTAssertNil(SidebarNavigation.move(in: items, from: .at(7), down: true, toEnd: true), "already at the end")
        XCTAssertEqual(SidebarNavigation.move(in: items, from: .none, down: true, toEnd: false), .worktree(main))
        XCTAssertEqual(SidebarNavigation.move(in: items, from: .none, down: false, toEnd: false), .issue(12))
        XCTAssertNil(SidebarNavigation.move(in: [], from: .none, down: true, toEnd: false))
    }
}
