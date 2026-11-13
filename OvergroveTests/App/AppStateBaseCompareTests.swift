import Foundation
import XCTest

@testable import Overgrove

/// The base compare card under S-02 and S-05 (#581): what it runs, when, and that git work does not pile up.
@MainActor
final class AppStateBaseCompareTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let main = FullRefName("refs/heads/main")!
    private let develop = FullRefName("refs/remotes/origin/develop")!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// - Parameters:
    ///   - card: The card's loader; `nil` keeps the app's default (no card comparisons).
    ///   - s11: S-11's loader.
    private func loadedState(card: StubComparisonLoader?, s11: StubComparisonLoader = StubComparisonLoader()) async
        -> AppState
    {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), inspector: RecordingInspector(), comparisonLoader: s11,
            baseSummaryLoader: card)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        return state
    }

    /// Waits until the card's work (and any load that restarts it) has finished.
    private func settle(_ state: AppState) async {
        for _ in 0..<20 {
            let load = state.loadTask
            await load?.value
            guard let task = state.baseSummaryTask else { return }
            await task.value
            // Done when neither a new load nor a new card request started meanwhile.
            if state.baseSummaryTask == task, state.loadTask == load { return }
        }
    }

    func testSelectingAWorktreeComparesItWithItsBase() async {
        let card = StubComparisonLoader()
        let state = await loadedState(card: card)
        state.selectWorktree(feature)
        await settle(state)
        XCTAssertEqual(card.compareRequests.last?.0, feature)
        XCTAssertEqual(card.compareRequests.last?.1, main, "the base S-11 would pick")
        XCTAssertEqual(card.compareRequests.last?.2, true, "uncommitted changes included, as S-11 by default")
        guard case .loaded(let summary, _, _, _) = state.baseCompareCardModel?.state else {
            return XCTFail("\(String(describing: state.baseCompareCardModel?.state))")
        }
        XCTAssertTrue(summary.hasPrefix("2 commits ahead · 0 behind"), summary)
        XCTAssertEqual(state.baseCompareCardModel?.bases.count, 2)
    }

    /// Stepping through worktrees faster than the debounce runs nothing until the selection settles, then one
    /// comparison for the worktree it settled on.
    func testRapidSelectionRunsOneComparison() async {
        let card = StubComparisonLoader()
        let state = await loadedState(card: card)
        await settle(state)
        let before = card.compareRequests.count
        guard case .loaded(let listing) = state.worktreeList else { return XCTFail("list not loaded") }
        let paths = listing.entries.filter { state.canCompare($0.worktree.path) }.map(\.worktree.path)
        XCTAssertGreaterThan(paths.count, 1)
        for path in paths + paths { state.selectWorktree(path) }
        state.selectWorktree(feature)
        await settle(state)
        let requests = card.compareRequests.dropFirst(before)
        XCTAssertEqual(requests.map(\.0), [feature], "one comparison, for the last worktree")
    }

    /// A base picked on the card is remembered for the worktree, so S-11 opens on it.
    func testChosenBaseIsSharedWithS11() async {
        let card = StubComparisonLoader()
        let s11 = StubComparisonLoader()
        let state = await loadedState(card: card, s11: s11)
        state.selectWorktree(feature)
        await settle(state)
        state.chooseBaseSummaryBase(develop)
        await settle(state)
        XCTAssertEqual(card.compareRequests.last?.1, develop)
        XCTAssertEqual(state.baseCompareCardModel?.baseName, "origin/develop")
        state.showComparison()
        await state.comparisonTask?.value
        XCTAssertEqual(s11.compareRequests.last?.1, develop)
    }

    /// While S-11 is open the card runs nothing (S-11 covers it and runs the same comparison).
    func testS11PausesTheCard() async {
        let card = StubComparisonLoader()
        let state = await loadedState(card: card)
        state.selectWorktree(feature)
        await settle(state)
        let before = card.compareRequests.count
        state.showComparison()
        await state.comparisonTask?.value
        state.reload()
        await state.loadTask?.value
        await state.baseSummaryTask?.value
        XCTAssertEqual(card.compareRequests.count, before, "a load under S-11 does not run the card")
        state.closeComparison()
        await settle(state)
        XCTAssertEqual(card.compareRequests.count, before + 1, "closing S-11 brings the card back up to date")
    }

    func testNoBaseBranch() async {
        let card = StubComparisonLoader()
        card.bases = ComparisonBases(all: [], preferred: nil)
        let state = await loadedState(card: card)
        state.selectWorktree(feature)
        await settle(state)
        XCTAssertEqual(state.baseCompareCardModel?.state, .noBase("No base branch to compare with."))
        XCTAssertTrue(state.baseCompareCardModel?.canCompare == true, "the button stays")
    }

    /// Auto refresh drives the card at most every max(5 s, 10 × the last comparison), PERF-10b.
    func testThrottleGapFollowsTheLastComparison() async {
        let state = await loadedState(card: StubComparisonLoader())
        XCTAssertEqual(state.baseSummaryThrottleGap, .seconds(5))
        state.baseSummaryLastDuration = .milliseconds(200)
        XCTAssertEqual(state.baseSummaryThrottleGap, .seconds(5))
        state.baseSummaryLastDuration = .milliseconds(800)
        XCTAssertEqual(state.baseSummaryThrottleGap, .seconds(8))
    }

    /// Right after a comparison, an auto-refresh request waits out the gap; a user request does not, and it takes the
    /// waiting one's place.
    func testAutoRefreshWaitsButTheUserDoesNot() async throws {
        let card = StubComparisonLoader()
        let state = await loadedState(card: card)
        state.selectWorktree(feature)
        await settle(state)
        let before = card.compareRequests.count

        state.refreshBaseSummary(throttled: true)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(card.compareRequests.count, before, "auto refresh waits for the gap, not just the debounce")
        XCTAssertNotNil(state.baseSummaryTask)

        state.refreshBaseSummary()
        await state.baseSummaryTask?.value
        XCTAssertEqual(card.compareRequests.count, before + 1, "the user's request runs after the debounce")

        state.refreshBaseSummary()
        state.refreshBaseSummary(throttled: true)
        await state.baseSummaryTask?.value
        XCTAssertEqual(card.compareRequests.count, before + 2, "auto refresh does not slow a waiting user request")
    }

    /// Without a card loader (the default) nothing runs, so tests that count S-11's requests stay exact.
    func testNoLoaderRunsNothing() async {
        let s11 = StubComparisonLoader()
        let state = await loadedState(card: nil, s11: s11)
        state.selectWorktree(feature)
        await settle(state)
        XCTAssertNil(state.baseSummaryTask)
        XCTAssertTrue(s11.compareRequests.isEmpty)
    }
}
