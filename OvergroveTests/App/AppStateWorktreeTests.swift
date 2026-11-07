import Foundation
import XCTest

@testable import Overgrove

/// Returns a fixed result without git.
struct StubRepositoryLoader: RepositoryLoading {
    var result: Result<WorktreeListing, RepositoryLoadError> = .success(.mockup)

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        try result.get()
    }
}

/// Holds every load until the test releases it, so results can arrive in any order.
final class GatedRepositoryLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(Repository, CheckedContinuation<Result<WorktreeListing, RepositoryLoadError>, Never>)] = []

    var pendingCount: Int { lock.withLock { waiting.count } }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        let result = await withCheckedContinuation { continuation in
            lock.withLock { waiting.append((repository, continuation)) }
        }
        return try result.get()
    }

    /// Resumes the load at `index` (in call order) with `result`.
    func release(_ index: Int, with result: Result<WorktreeListing, RepositoryLoadError>) {
        let continuation = lock.withLock { waiting[index].1 }
        continuation.resume(returning: result)
    }

    func waitForLoads(_ count: Int) async {
        while pendingCount < count { await Task.yield() }
    }
}

/// `AppState` worktree flows (#65): load on open, focus and selection, stale results, failures.
@MainActor
final class AppStateWorktreeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeState(loader: any RepositoryLoading) -> AppState {
        AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
    }

    private func context(_ name: String) -> RepositoryContext {
        let root = URL(fileURLWithPath: "/tmp/dev/\(name)", isDirectory: true)
        return RepositoryContext(
            repository: Repository(
                rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
            owner: nil)
    }

    private func listing(_ branch: String) -> WorktreeListing {
        WorktreeListing(
            entries: [
                WorktreeListing.entry(
                    "/tmp/dev/\(branch)", branch: branch, isMain: true,
                    state: .loaded(WorktreeListing.state(branch: branch)))
            ],
            isPartial: false)
    }

    func testOpeningLoadsTheListAndFocusesTheMainWorktree() async {
        let state = makeState(loader: StubRepositoryLoader())
        state.open(context("api"))
        XCTAssertEqual(state.worktreeList, .idle)
        state.reload()
        XCTAssertEqual(state.worktreeList, .loading)
        await state.loadTask?.value

        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
        XCTAssertEqual(state.focusedWorktreePath, GitPath("/tmp/dev/api"))
        XCTAssertEqual(state.selection, .wip(GitPath("/tmp/dev/api")))
        XCTAssertEqual(state.snapshot?.worktreeCount, 6)
        XCTAssertEqual(state.snapshot?.prunableCount, 1)
        XCTAssertEqual(state.snapshot?.focusedWorktree?.title, "main")
        XCTAssertEqual(state.worktreeListModel?.rows.count, 6)
    }

    /// interaction.md §1.3: selecting a worktree row focuses it and selects its WIP.
    func testSelectingAWorktreeFocusesItAndSelectsItsChanges() async {
        let state = makeState(loader: StubRepositoryLoader())
        state.open(context("api"))
        state.reload()
        await state.loadTask?.value

        let path = GitPath("/tmp/dev/api-wt/42-rate-limit")
        state.selectWorktree(path)
        XCTAssertEqual(state.focusedWorktreePath, path)
        XCTAssertEqual(state.selection, .wip(path))
        XCTAssertEqual(state.snapshot?.focusedWorktree?.aheadBadge, "↑2")
        XCTAssertEqual(state.worktreeListModel?.rows.filter(\.isFocused).map(\.title), ["feat/42-rate-limit"])

        state.selectWorktree(GitPath("/tmp/dev/not-listed"))
        XCTAssertEqual(state.focusedWorktreePath, path, "an unknown path is ignored")
    }

    /// A refresh keeps the focused worktree when it is still listed.
    func testReloadKeepsTheFocusedWorktree() async {
        let state = makeState(loader: StubRepositoryLoader())
        state.open(context("api"))
        state.reload()
        await state.loadTask?.value
        state.selectWorktree(GitPath("/tmp/dev/api-wt/login"))

        state.reload()
        XCTAssertEqual(state.worktreeList, .loaded(.mockup), "a refresh keeps showing the old list meanwhile")
        await state.loadTask?.value
        XCTAssertEqual(state.focusedWorktreePath, GitPath("/tmp/dev/api-wt/login"))
    }

    /// A load that finishes after the user opened another repository is dropped.
    func testAStaleResultIsDropped() async {
        let loader = GatedRepositoryLoader()
        let state = makeState(loader: loader)
        state.open(context("api"))
        state.reload()
        await loader.waitForLoads(1)
        state.open(context("web"))
        state.reload()
        await loader.waitForLoads(2)

        loader.release(1, with: .success(listing("web")))
        loader.release(0, with: .success(listing("api")))
        await state.loadTask?.value
        // Let the cancelled first task finish too.
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(state.worktreeList, .loaded(listing("web")))
        XCTAssertEqual(state.snapshot?.focusedWorktree?.title, "web")
    }

    func testFailureShowsAMessage() async {
        let state = makeState(
            loader: StubRepositoryLoader(result: .failure(.blocked(reason: "core.fsmonitor is set locally."))))
        state.open(context("api"))
        state.reload()
        await state.loadTask?.value
        XCTAssertEqual(
            state.worktreeList,
            .failed(message: "Overgrove stopped querying this repository for safety. core.fsmonitor is set locally."))
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.worktreeListModel)
    }

    func testCancelledLoadLeavesNoError() async {
        let state = makeState(loader: StubRepositoryLoader(result: .failure(.git(.cancelled))))
        state.open(context("api"))
        state.reload()
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loading)
    }

    func testOpeningAnotherRepositoryClearsTheList() async {
        let state = makeState(loader: StubRepositoryLoader())
        state.open(context("api"))
        state.reload()
        await state.loadTask?.value
        state.open(context("web"))
        XCTAssertEqual(state.worktreeList, .idle)
        XCTAssertNil(state.focusedWorktreePath)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.snapshot)
    }

    func testReloadWithoutARepositoryDoesNothing() {
        let state = makeState(loader: StubRepositoryLoader())
        state.reload()
        XCTAssertNil(state.loadTask)
        XCTAssertEqual(state.worktreeList, .idle)
    }
}
