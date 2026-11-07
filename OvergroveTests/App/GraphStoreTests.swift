import Foundation
import XCTest

@testable import Overgrove

/// Serves pages of a fixed linear history; the test can move the ref set or fail the next call.
final class FakeGraphLoader: GraphLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var history: [CommitNode]
    private var tip = "a"
    private var failure: GitError?
    private var calls: [Int] = []
    private var refSetComplete = true

    init(count: Int) {
        history = FakeGraphLoader.linear(count)
    }

    static func oid(_ index: Int) -> ObjectID { ObjectID(String(format: "%040x", index + 1))! }

    /// Newest first; each commit's parent is the next one.
    static func linear(_ count: Int) -> [CommitNode] {
        (0..<count).map { index in
            CommitNode(
                oid: oid(index), parents: index + 1 < count ? [oid(index + 1)] : [], authorName: "Alice Example",
                authorEmail: "alice@example.com", authorDate: Date(timeIntervalSince1970: Double(1_000_000 - index)),
                subject: "commit \(index)")
        }
    }

    var skips: [Int] { lock.withLock { calls } }
    func moveRefs() { lock.withLock { tip += "b" } }
    func failNext(_ error: GitError) { lock.withLock { failure = error } }
    /// The ref set misses refs (`GraphRefSet.isComplete`, #333): it cannot show a move.
    func missRefs() { lock.withLock { refSetComplete = false } }

    /// New commits on top that only a ref outside the ref set reaches: the history moves, the ref set does not.
    func addCommitsOnHiddenRef(_ count: Int) {
        lock.withLock {
            let base = history.first?.oid
            let added = (0..<count).map { index in
                CommitNode(
                    oid: Self.oid(100_000 + index),
                    parents: index + 1 < count
                        ? [Self.oid(100_000 + index + 1)]
                        : [base]
                            .compactMap { $0 }, authorName: "Mallory Example", authorEmail: "mallory@example.com",
                    authorDate: Date(timeIntervalSince1970: Double(2_000_000 - index)), subject: "hidden \(index)")
            }
            history = added + history
        }
    }

    var commits: [CommitNode] { lock.withLock { history } }

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        lock.withLock {
            calls.append(skip)
            if let failure {
                self.failure = nil
                return .failure(failure)
            }
            let branch = Branch(
                fullName: "refs/heads/main", kind: .local, target: Self.oid(0), upstreamStatus: .none, isHead: true,
                committerDate: nil, symbolicTarget: nil)
            let refs = RefParser.Listing(branches: [branch], tags: [], isPartial: false, skippedRecords: 0)
            let refSet = GraphRefSet(
                refs: RefParser.Listing(
                    branches: [
                        Branch(
                            fullName: "refs/heads/\(tip)", kind: .local, target: Self.oid(0), upstreamStatus: .none,
                            isHead: false, committerDate: nil, symbolicTarget: nil)
                    ], tags: [], isPartial: false, skippedRecords: 0),
                worktrees: [])
            let end = min(history.count, skip + limit)
            let commits = skip < end ? Array(history[skip..<end]) : []
            return .success(
                GraphPageSnapshot(
                    commits: commits, isPartial: false, refSet: refSet, refs: refs, worktrees: [],
                    isRefSetComplete: refSetComplete))
        }
    }
}

/// `FakeGraphLoader` whose answers wait until the test releases them, so tests choose which page lands first (#306).
final class GatedGraphLoader: GraphLoading, @unchecked Sendable {
    let pages: FakeGraphLoader
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isGated = false

    init(count: Int) { pages = FakeGraphLoader(count: count) }

    var pendingCount: Int { lock.withLock { waiting.count } }
    func gate() { lock.withLock { isGated = true } }

    /// Lets the oldest waiting call answer.
    func releaseOldest() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume()
    }

    /// Lets the newest waiting call answer.
    func releaseNewest() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock { waiting.popLast() }
        next?.resume()
    }

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        if lock.withLock({ isGated }) {
            await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
        }
        return await pages.page(repository, skip: skip, limit: limit)
    }
}

@MainActor
final class GraphStoreTests: XCTestCase {
    private let repository = Repository(
        rootURL: URL(fileURLWithPath: "/tmp/dev/repo"),
        commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/repo/.git"),
        isBare: false)

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFirstPageThenTheNextOneWhenTheEndComesIntoView() async throws {
        let loader = FakeGraphLoader(count: 1_200)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        XCTAssertEqual(store.rows.count, 500)
        XCTAssertFalse(store.isComplete)

        store.rowAppeared(100)
        XCTAssertEqual(loader.skips, [0], "far from the end: nothing more")
        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 }
        store.rowAppeared(950)
        try await waitUntil { store.rows.count == 1_200 }

        XCTAssertTrue(store.isComplete, "a short page ends the history")
        store.rowAppeared(1_199)
        XCTAssertEqual(loader.skips, [0, 500, 1_000])
        XCTAssertEqual(store.rows, GraphEngine.layout(FakeGraphLoader.linear(1_200)).rows, "paging = one layout")
        XCTAssertEqual(store.index(of: FakeGraphLoader.oid(700)), 700)
    }

    func testAMovedRefSetStartsOver() async throws {
        let loader = FakeGraphLoader(count: 1_200)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        loader.moveRefs()

        store.rowAppeared(499)
        try await waitUntil { loader.skips.count == 3 && store.status == .loaded }

        XCTAssertEqual(loader.skips, [0, 500, 0], "the second page saw other refs: back to the first")
        XCTAssertEqual(store.rows.count, 500)
    }

    func testFirstPageFailureIsShownAndALaterOneKeepsTheRows() async throws {
        let loader = FakeGraphLoader(count: 1_200)
        let store = GraphStore(loader: loader)
        loader.failNext(.timeout(seconds: 15))
        store.load(repository, focus: nil)
        try await waitUntil { if case .failed = store.status { true } else { false } }
        XCTAssertEqual(store.status, .failed(GitError.timeout(seconds: 15).message))

        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        loader.failNext(.timeout(seconds: 15))
        store.rowAppeared(499)
        try await waitUntil { loader.skips.count == 3 && !store.isLoadingMore }
        XCTAssertEqual(store.rows.count, 500)
        XCTAssertEqual(store.status, .loaded)
    }

    func testFocusChangesDecorationsWithoutReloading() async throws {
        let loader = FakeGraphLoader(count: 10)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        XCTAssertNil(store.wip)

        let worktree = Worktree(
            path: GitPath("/tmp/dev/repo"), head: FakeGraphLoader.oid(0), branch: "refs/heads/main", isMain: true,
            isDetached: false, isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)
        let state = WorkingState(
            headCommit: FakeGraphLoader.oid(0), head: .branch("main"), upstream: .none, stashCount: 0,
            staged: [FileChange(path: GitPath("a"), status: .modified)], unstaged: [], untracked: [], conflicted: [],
            isPartial: false, skippedRecords: 0)
        store.setFocus(WorktreeListing.Entry(worktree: worktree, state: .loaded(state)))

        XCTAssertEqual(store.wip?.summary, "WIP 1 staged")
        XCTAssertEqual(store.head, FakeGraphLoader.oid(0))
        XCTAssertEqual(store.pills[FakeGraphLoader.oid(0)]?.first?.kind, .focusedBranch)
        XCTAssertEqual(loader.skips, [0])
    }

    func testAnOlderLoadNeverOverwritesANewerOne() async throws {
        let loader = FakeGraphLoader(count: 10)
        let store = GraphStore(loader: loader)
        let other = Repository(
            rootURL: URL(fileURLWithPath: "/tmp/dev/other"),
            commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/other/.git"), isBare: false)
        store.load(repository, focus: nil)
        store.load(other, focus: nil)
        store.clear()
        XCTAssertEqual(store.status, .idle)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.status, .idle, "results of cleared loads are dropped")
        XCTAssertEqual(store.rows, [])
    }

    /// #306: a next-page load does not start while a refresh checks the first page; otherwise the two answers share
    /// one generation and `receive` cannot tell them apart (commits went missing, or the graph started at row 1000).
    func testNoNextPageWhileARefreshChecksTheFirstOne() async throws {
        let loader = GatedGraphLoader(count: 1_500)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 }

        loader.gate()
        loader.pages.moveRefs()
        store.refresh(focus: nil)
        try await waitUntil { loader.pendingCount == 1 }
        store.rowAppeared(950)  // near the end while the check is out
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(loader.pendingCount, 1, "no second request during the check")

        loader.releaseOldest()
        try await waitUntil { store.rows.count == 500 && !store.isLoadingMore }
        XCTAssertEqual(loader.pages.skips, [0, 500, 0], "the moved history started over from the first page")
        XCTAssertEqual(store.rows, GraphEngine.layout(FakeGraphLoader.linear(500)).rows, "no gap, no wrong start")
    }

    /// #306: the other order. A scroll page that would land before the check is not requested at all, so the check's
    /// answer is always the first page.
    func testTheCheckIsNeverAnsweredByAScrollPage() async throws {
        let loader = GatedGraphLoader(count: 1_500)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 }

        loader.gate()
        loader.pages.moveRefs()
        store.refresh(focus: nil)
        try await waitUntil { loader.pendingCount == 1 }
        store.rowAppeared(950)
        try await Task.sleep(for: .milliseconds(50))
        loader.releaseNewest()
        loader.releaseOldest()
        try await waitUntil { store.rows.count == 500 && !store.isLoadingMore }
        XCTAssertEqual(store.index(of: FakeGraphLoader.oid(0)), 0, "the graph starts at the newest commit")
        XCTAssertEqual(store.rows, GraphEngine.layout(FakeGraphLoader.linear(500)).rows)
    }

    /// #306: the end coming into view during a check that finds nothing moved still loads the next page afterwards,
    /// since the rows already on screen will not appear again.
    func testANextPageAskedForDuringAnUnchangedCheckLoadsAfterIt() async throws {
        let loader = GatedGraphLoader(count: 1_500)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }

        loader.gate()
        store.refresh(focus: nil)
        try await waitUntil { loader.pendingCount == 1 }
        store.rowAppeared(450)
        loader.releaseOldest()
        try await waitUntil { loader.pendingCount == 1 }  // the deferred next page
        loader.releaseOldest()
        try await waitUntil { store.rows.count == 1_000 && !store.isLoadingMore }
        XCTAssertEqual(loader.pages.skips, [0, 0, 500])
        XCTAssertEqual(store.rows, GraphEngine.layout(FakeGraphLoader.linear(1_000)).rows)
    }

    /// #306: a check answered with `.cancelled` ends the check, so the next page is appended rather than taken for
    /// the check's answer and dropped.
    func testACancelledCheckDoesNotSwallowTheNextPage() async throws {
        let loader = FakeGraphLoader(count: 1_500)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }

        loader.failNext(.cancelled)
        store.refresh(focus: nil)
        try await waitUntil { loader.skips.count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        store.rowAppeared(450)
        try await waitUntil { loader.skips.count == 3 && !store.isLoadingMore }
        try await waitUntil { store.rows.count == 1_000 }
        XCTAssertEqual(store.rows, GraphEngine.layout(FakeGraphLoader.linear(1_000)).rows)
    }

    /// #333: a ref set that misses refs cannot show a move, so every refresh starts over from the first page. The rows
    /// then match one fresh read: no stale rows, and later pages are not stitched onto the old ones.
    func testARefreshWithAnIncompleteRefSetStartsOver() async throws {
        let loader = FakeGraphLoader(count: 1_500)
        loader.missRefs()
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 }

        loader.addCommitsOnHiddenRef(3)
        store.refresh(focus: nil)
        try await waitUntil { store.rows.count == 500 && store.index(of: FakeGraphLoader.oid(100_000)) == 0 }
        XCTAssertEqual(loader.skips, [0, 500, 0])
        XCTAssertEqual(store.rows, GraphEngine.layout(Array(loader.commits.prefix(500))).rows, "one fresh read")

        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 && !store.isLoadingMore }
        XCTAssertEqual(loader.skips, [0, 500, 0, 500], "a next page is appended, not a restart")
        XCTAssertEqual(
            store.rows, GraphEngine.layout(Array(loader.commits.prefix(1_000))).rows, "no stitching at --skip")
    }

    /// A complete ref set keeps today's behaviour: a refresh that finds nothing moved keeps the rows and selection.
    func testARefreshWithACompleteUnchangedRefSetKeepsTheRows() async throws {
        let loader = FakeGraphLoader(count: 1_500)
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 }
        store.select(FakeGraphLoader.oid(700))

        store.refresh(focus: nil)
        try await waitUntil { loader.skips.count == 3 }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(loader.skips, [0, 500, 0])
        XCTAssertEqual(store.rows.count, 1_000, "nothing moved: the loaded pages stay")
        XCTAssertEqual(store.selected, FakeGraphLoader.oid(700))
    }

    /// #333: the restart keeps the selected commit when it is still in the reloaded rows, and drops it otherwise.
    func testSelectionSurvivesAnIncompleteRefSetRestartWhenStillLoaded() async throws {
        let loader = FakeGraphLoader(count: 1_500)
        loader.missRefs()
        let store = GraphStore(loader: loader)
        store.load(repository, focus: nil)
        try await waitUntil { store.status == .loaded }
        store.select(FakeGraphLoader.oid(10))

        loader.addCommitsOnHiddenRef(3)
        store.refresh(focus: nil)
        try await waitUntil { store.index(of: FakeGraphLoader.oid(100_000)) == 0 }
        XCTAssertEqual(store.selected, FakeGraphLoader.oid(10), "still in the first page")
        XCTAssertEqual(store.index(of: FakeGraphLoader.oid(10)), 13)

        store.rowAppeared(450)
        try await waitUntil { store.rows.count == 1_000 && !store.isLoadingMore }
        store.select(FakeGraphLoader.oid(900))
        store.refresh(focus: nil)
        try await waitUntil { store.rows.count == 500 && !store.isLoadingMore }
        XCTAssertNil(store.selected, "past the reloaded rows")
    }
}
