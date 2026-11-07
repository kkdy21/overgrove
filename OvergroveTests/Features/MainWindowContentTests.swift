import Foundation
import XCTest

@testable import Overgrove

/// Text shown in the main window's status bar and focused-worktree chip (#64, art-direction.md §3.4–§3.5,
/// interaction.md §4.2).
final class MainWindowContentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func items(
        snapshot: RepositorySnapshot? = nil,
        fetch: FetchStatus = .never,
        gh: GHAuthStatus? = nil
    ) -> [StatusBarItem] {
        StatusBarItem.items(snapshot: snapshot, fetchStatus: fetch, ghStatus: gh, now: now)
    }

    private func text(_ items: [StatusBarItem], _ kind: StatusBarItem.Kind) -> String? {
        items.first { $0.kind == kind }?.text
    }

    // MARK: Status bar

    func testReadOnlyIsAlwaysFirst() {
        let bar = items()
        XCTAssertEqual(bar.first?.kind, .readOnly)
        XCTAssertEqual(bar.first?.text, "Read-only")
        XCTAssertEqual(bar.first?.tone, .ok)
    }

    func testOrderMatchesTheDesign() {
        let snapshot = RepositorySnapshot(
            focusedWorktree: FocusedWorktree(
                branch: "feat/42", headShortSHA: "a91f3c2", ahead: 2, behind: 0, hasUpstream: true),
            worktreeCount: 6, prunableCount: 1)
        let bar = items(
            snapshot: snapshot, fetch: .idle(lastFetched: now.addingTimeInterval(-120)),
            gh: .loggedIn(login: "mina-dev"))
        XCTAssertEqual(bar.map(\.kind), [.readOnly, .fetch, .aheadBehind, .worktrees, .prunable, .gh])
        XCTAssertEqual(
            bar.map(\.text), ["Read-only", "Fetched 2 min ago", "↑2 ↓0", "6 worktrees", "1 prunable", "gh: @mina-dev"])
        XCTAssertEqual(bar.last?.isTrailing, true)
    }

    func testFetchStates() {
        XCTAssertEqual(text(items(fetch: .never), .fetch), "Never fetched")
        XCTAssertEqual(text(items(fetch: .idle(lastFetched: now.addingTimeInterval(-20))), .fetch), "Fetched just now")
        XCTAssertEqual(
            text(items(fetch: .idle(lastFetched: now.addingTimeInterval(-3 * 3600))), .fetch), "Fetched 3 h ago")
        XCTAssertEqual(
            text(items(fetch: .idle(lastFetched: now.addingTimeInterval(-2 * 86400))), .fetch), "Fetched 2 d ago")
        XCTAssertEqual(
            text(
                items(fetch: .fetching(remotes: ["origin"], since: now.addingTimeInterval(-12), lastFetched: nil)),
                .fetch),
            "Fetching origin… 12 s")
        XCTAssertEqual(
            text(
                items(
                    fetch: .fetching(
                        remotes: ["origin", "upstream"], since: now.addingTimeInterval(-3), lastFetched: nil)), .fetch),
            "Fetching 2 remotes… 3 s")
        let failed = items(fetch: .failed(lastFetched: now.addingTimeInterval(-7200)))
        XCTAssertEqual(text(failed, .fetch), "Last fetched 2 h ago · last attempt failed")
        XCTAssertEqual(failed.first { $0.kind == .fetch }?.tone, .warning)
        XCTAssertEqual(text(items(fetch: .failed(lastFetched: nil)), .fetch), "Fetch failed")
    }

    /// #77: the estimate from `FETCH_HEAD`, a stop, the moment before the remotes are known, the Details link, and
    /// `Refreshing…` (interaction.md §4, §4.2).
    func testFetchStatesAddedForFetchAndRefresh() {
        XCTAssertEqual(
            text(items(fetch: .estimated(lastFetched: now.addingTimeInterval(-3 * 3600))), .fetch),
            "Fetched 3 h ago (estimated)")
        XCTAssertEqual(text(items(fetch: .cancelled(lastFetched: nil)), .fetch), "Fetch cancelled")
        XCTAssertEqual(
            text(items(fetch: .fetching(remotes: [], since: now, lastFetched: nil)), .fetch), "Fetching… 0 s")
        let failed = StatusBarItem.items(
            snapshot: nil, fetchStatus: .failed(lastFetched: nil), ghStatus: nil, now: now, hasFetchDetails: true)
        XCTAssertEqual(text(failed, .fetch), "Fetch failed — Details")

        let refreshing = StatusBarItem.items(
            snapshot: nil, fetchStatus: .never, ghStatus: nil, now: now, isRefreshing: true)
        XCTAssertEqual(refreshing.map(\.kind), [.readOnly, .fetch, .refreshing])
        XCTAssertEqual(text(refreshing, .refreshing), "Refreshing…")
        XCTAssertNil(text(items(fetch: .never), .refreshing))
    }

    func testAheadBehindOnlyWithAnUpstream() {
        let noUpstream = RepositorySnapshot(
            focusedWorktree: FocusedWorktree(
                branch: "spike", headShortSHA: nil, ahead: 0, behind: 0, hasUpstream: false),
            worktreeCount: 1, prunableCount: 0)
        XCTAssertNil(text(items(snapshot: noUpstream), .aheadBehind))
        XCTAssertEqual(text(items(snapshot: noUpstream), .worktrees), "1 worktree")
        XCTAssertNil(text(items(snapshot: noUpstream), .prunable), "only when there are prunable worktrees")
    }

    func testNoDataHidesTheRepositoryFields() {
        XCTAssertEqual(items().map(\.kind), [.readOnly, .fetch])
    }

    func testGHStates() {
        XCTAssertEqual(text(items(gh: .loggedIn(login: "octocat")), .gh), "gh: @octocat")
        XCTAssertEqual(items(gh: .loggedIn(login: "octocat")).last?.tone, .ok)
        XCTAssertEqual(text(items(gh: .notLoggedIn), .gh), "gh: not logged in")
        XCTAssertEqual(text(items(gh: .notInstalled), .gh), "gh: not installed")
        XCTAssertNil(text(items(gh: nil), .gh), "unknown until the gh check runs")
    }

    // MARK: Focused worktree chip

    func testChipForABranchWithCommitsAhead() {
        let chip = FocusedWorktree(
            branch: "feat/42-rate-limit", headShortSHA: "a91f3c2", ahead: 2, behind: 0, hasUpstream: true)
        XCTAssertEqual(chip.title, "feat/42-rate-limit")
        XCTAssertEqual(chip.aheadBadge, "↑2")
        XCTAssertEqual(chip.accessibilityLabel, "Focused worktree feat/42-rate-limit, 2 ahead")
    }

    func testChipForADetachedHead() {
        let chip = FocusedWorktree(branch: nil, headShortSHA: "b2e8a44", ahead: 0, behind: 0, hasUpstream: false)
        XCTAssertEqual(chip.title, "detached @ b2e8a44")
        XCTAssertNil(chip.aheadBadge)
        XCTAssertEqual(chip.accessibilityLabel, "Focused worktree detached @ b2e8a44")
    }
}
