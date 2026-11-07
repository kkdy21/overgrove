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
                GraphPageSnapshot(commits: commits, isPartial: false, refSet: refSet, refs: refs, worktrees: []))
        }
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
}
