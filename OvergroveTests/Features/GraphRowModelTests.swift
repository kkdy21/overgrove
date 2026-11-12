import XCTest

@testable import Overgrove

/// Ref pills, the WIP row, and row text for the commit graph (#68, art-direction.md §5.5, screens.md S-01).
final class GraphRowModelTests: XCTestCase {
    private let a = ObjectID(String(repeating: "a", count: 40))!
    private let b = ObjectID(String(repeating: "b", count: 40))!
    private let c = ObjectID(String(repeating: "c", count: 40))!

    private func branch(_ name: String, _ target: ObjectID, symbolic: String? = nil) -> Branch {
        let kind: Branch.Kind = name.hasPrefix("refs/remotes/") ? .remote(remote: "origin") : .local
        return Branch(
            fullName: name, kind: kind, target: target, upstreamStatus: .none, isHead: false, committerDate: nil,
            symbolicTarget: symbolic)
    }

    private func worktree(_ path: String, branch: String?, head: ObjectID?) -> Worktree {
        Worktree(
            path: GitPath(path), head: head, branch: branch, isMain: false, isDetached: branch == nil, isBare: false,
            lock: .unlocked, isPrunable: false, prunableReason: nil)
    }

    private func listing(branches: [Branch], tags: [Tag] = []) -> RefParser.Listing {
        RefParser.Listing(branches: branches, tags: tags, isPartial: false, skippedRecords: 0)
    }

    func testPillsAreOrderedAndMergedLikeTheSpec() {
        let refs = listing(
            branches: [
                branch("refs/heads/main", a), branch("refs/heads/feature", a), branch("refs/heads/zeta", a),
                branch("refs/remotes/origin/main", a), branch("refs/remotes/origin/feature", b),
                branch("refs/remotes/origin/HEAD", a, symbolic: "refs/remotes/origin/main"),
                branch("refs/remotes/origin/only", a),
            ],
            tags: [Tag(fullName: "refs/tags/v1", target: c, peeledTarget: a, date: nil)])
        let worktrees = [
            worktree("/tmp/dev/repo", branch: "refs/heads/main", head: a),
            worktree("/tmp/dev/wt-feature", branch: "refs/heads/feature", head: a),
            worktree("/tmp/dev/wt-detached", branch: nil, head: a),
        ]

        let pills = GraphRefDecorations.make(refs: refs, worktrees: worktrees, focused: GitPath("/tmp/dev/repo"))

        XCTAssertEqual(
            pills[a]?.map(\.kind),
            [.focusedBranch, .worktreeBranch, .localBranch, .detachedWorktree, .remoteBranch, .tag])
        XCTAssertEqual(pills[a]?.map(\.title), ["main", "feature", "zeta", "wt-detached", "origin/only", "v1"])
        XCTAssertEqual(pills[a]?.first?.hasMatchingRemote, true, "main and origin/main share a commit: one pill")
        XCTAssertEqual(pills[a]?.first?.tooltip, "refs/heads/main\nrefs/remotes/origin/main")
        XCTAssertEqual(pills[a]?[1].hasMatchingRemote, false, "origin/feature is on another commit")
        XCTAssertEqual(pills[b]?.map(\.title), ["origin/feature"])
        XCTAssertNil(pills[c], "an annotated tag decorates the commit it points to")
        XCTAssertFalse(pills.values.joined().contains { $0.title == "origin/HEAD" }, "symbolic refs are not drawn")
    }

    /// #432: a tag of a tree or blob has no row, so it draws no pill, not even on a commit with the same OID.
    func testTagsOfATreeOrBlobDrawNoPill() {
        let refs = listing(
            branches: [],
            tags: [
                Tag(fullName: "refs/tags/tree", target: a, peeledTarget: nil, date: nil, objectType: .tree),
                Tag(fullName: "refs/tags/blob", target: c, peeledTarget: b, date: nil, objectType: .blob),
                Tag(fullName: "refs/tags/v1", target: a, peeledTarget: nil, date: nil),
            ])
        let pills = GraphRefDecorations.make(refs: refs, worktrees: [], focused: nil)
        XCTAssertEqual(pills[a]?.map(\.title), ["v1"])
        XCTAssertNil(pills[b])
    }

    func testFocusedDetachedWorktreeComesFirstAndHostileNamesAreEscaped() {
        let refs = listing(branches: [branch("refs/heads/main", a)])
        let worktrees = [worktree("/tmp/dev/wt\u{202E}evil", branch: nil, head: a)]

        let pills = GraphRefDecorations.make(
            refs: refs, worktrees: worktrees, focused: GitPath("/tmp/dev/wt\u{202E}evil"))

        XCTAssertEqual(pills[a]?.map(\.kind), [.focusedDetached, .localBranch])
        XCTAssertEqual(pills[a]?.first?.title, "wt\\u{202E}evil", "bidi overrides are made visible (T14)")
    }

    private func state(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0) -> WorkingState {
        func changes(_ count: Int, _ prefix: String) -> [FileChange] {
            (0..<count).map { FileChange(path: GitPath("\(prefix)\($0)"), status: .modified) }
        }
        return WorkingState(
            headCommit: b, head: .branch("main"), upstream: .none, stashCount: 0, staged: changes(staged, "s"),
            unstaged: changes(unstaged, "u"), untracked: changes(untracked, "n"), conflicted: changes(conflicted, "c"),
            isPartial: false, skippedRecords: 0)
    }

    func testWipRowSummaryAndVisibility() throws {
        let tree = worktree("/tmp/dev/api-wt/42-rate-limit", branch: "refs/heads/feat", head: a)
        XCTAssertNil(GraphWipRow.make(worktree: tree, state: state()), "no changes: no WIP row")

        let row = try XCTUnwrap(GraphWipRow.make(worktree: tree, state: state(staged: 3, unstaged: 2, untracked: 1)))
        XCTAssertEqual(row.summary, "WIP 3 staged · 2 unstaged · 1 untracked")
        XCTAssertEqual(row.folderName, "42-rate-limit")
        XCTAssertEqual(row.head, b, "status's HEAD wins over the worktree list's")

        let conflicted = try XCTUnwrap(GraphWipRow.make(worktree: tree, state: state(unstaged: 1, conflicted: 2)))
        XCTAssertEqual(conflicted.summary, "⚠ 2 conflicted · WIP 1 unstaged")
    }

    func testCommitTextAndCompactDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let commit = CommitNode(
            oid: a, parents: [b], authorName: "Alice Example", authorEmail: "alice@example.com",
            authorDate: now.addingTimeInterval(-7_200), subject: "feat: add\u{2028}thing",
            coAuthors: ["Claude <noreply@anthropic.com>"])

        let text = GraphCommitText(commit, now: now)

        XCTAssertEqual(text.subject, "feat: add\\u{2028}thing")
        XCTAssertTrue(text.isAIAssisted)
        XCTAssertEqual(text.initials, "AE")
        XCTAssertEqual(text.date, "2h")
        XCTAssertEqual(text.shortSHA, "aaaaaaa")
        XCTAssertEqual(
            [0, 59, 60, 3_599, 3_600, 86_400, 7 * 86_400, 30 * 86_400, 365 * 86_400].map {
                GraphCommitText.compact(now.addingTimeInterval(-Double($0)), now: now)
            },
            ["now", "now", "1m", "59m", "1h", "1d", "1w", "1mo", "1y"])
    }
}
