import Foundation
import XCTest

@testable import Overgrove

/// Holds every line count query until the test releases it, and records what was asked.
final class GatedLineCountLoader: LineCountLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(GitPath, CheckedContinuation<Result<WorkingLineCounts?, RepositoryLoadError>, Never>)] = []

    var requestedPaths: [GitPath] { lock.withLock { waiting.map(\.0) } }

    func lineCounts(_ repository: Repository, worktree: GitPath) async throws(RepositoryLoadError) -> WorkingLineCounts?
    {
        let result = await withCheckedContinuation { continuation in
            lock.withLock { waiting.append((worktree, continuation)) }
        }
        return try result.get()
    }

    func release(_ index: Int, with result: Result<WorkingLineCounts?, RepositoryLoadError>) {
        let continuation = lock.withLock { waiting[index].1 }
        continuation.resume(returning: result)
    }

    func waitForRequests(_ count: Int) async {
        while requestedPaths.count < count { await Task.yield() }
    }
}

/// `AppState` and the WIP line counts (#230): queried lazily for the selected worktree only, kept while its status
/// is unchanged, and a late answer for another worktree or status is dropped.
@MainActor
final class AppStateLineCountTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let login = GitPath("/tmp/dev/api-wt/login")

    /// The mockup's feature worktree: `staged0…2`, `unstaged0…1`.
    private let featureCounts = WorkingLineCounts(
        staged: (0..<3).map { FileStat(path: GitPath("staged\($0).swift"), added: 10, deleted: 2) },
        unstaged: (0..<2).map { FileStat(path: GitPath("unstaged\($0).swift"), added: 1, deleted: 0) },
        isPartial: false)

    private func loadedState(
        _ loader: any RepositoryLoading = StubRepositoryLoader(), lineCounts: GatedLineCountLoader
    ) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, lineCountLoader: lineCounts)
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

    func testCleanWorktreeIsNotQueried() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        XCTAssertEqual(state.wipDetailModel?.content, .clean)
        XCTAssertEqual(loader.requestedPaths, [], "the main worktree is clean: nothing to count")
    }

    func testSelectedWorktreeIsQueriedAndShowsCounts() async throws {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        XCTAssertEqual(loader.requestedPaths, [feature])
        XCTAssertNil(state.wipDetailModel?.lineTotals, "pending until the answer arrives")

        loader.release(0, with: .success(featureCounts))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 32, deleted: 6))
        let staged = try XCTUnwrap(state.wipDetailModel?.groups.first { $0.group == .staged })
        XCTAssertEqual(staged.rows.first?.lineCount, .lines(added: 10, deleted: 2))
    }

    func testReselectingTheWorktreeDoesNotQueryAgain() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        loader.release(0, with: .success(featureCounts))
        await state.lineCountTask?.value

        state.selectWorktree(feature)
        XCTAssertEqual(loader.requestedPaths, [feature], "same status, no new load: counts kept")
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 32, deleted: 6))
    }

    /// Security review of #230: an edit inside an already modified file leaves the status the same, so after a reload
    /// the counts are asked for again (the service answers from memory if it did not re-query the status). The old
    /// counts stay shown until the answer arrives.
    func testReloadAsksAgainEvenWhenTheStatusReadsTheSame() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        loader.release(0, with: .success(featureCounts))
        await state.lineCountTask?.value

        state.reload()  // the stub returns the same statuses
        await state.loadTask?.value
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.requestedPaths, [feature, feature])
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 32, deleted: 6), "kept meanwhile")

        let edited = WorkingLineCounts(
            staged: featureCounts.staged.values.map { $0 },
            unstaged: (0..<2).map { FileStat(path: GitPath("unstaged\($0).swift"), added: 4, deleted: 0) },
            isPartial: false)
        loader.release(1, with: .success(edited))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 38, deleted: 6))
    }

    func testChangedStatusIsQueriedAgain() async {
        let repositoryLoader = GatedRepositoryLoader()
        let loader = GatedLineCountLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: repositoryLoader, lineCountLoader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await repositoryLoader.waitForLoads(1)
        repositoryLoader.release(0, with: .success(.mockup))
        await state.loadTask?.value
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        loader.release(0, with: .success(featureCounts))
        await state.lineCountTask?.value

        let changed = WorktreeListing(
            entries: WorktreeListing.mockup.entries.map { entry in
                entry.worktree.path == feature
                    ? WorktreeListing.Entry(
                        worktree: entry.worktree,
                        state: .loaded(WorktreeListing.state(branch: "feat/42-rate-limit", staged: 1)))
                    : entry
            },
            isPartial: false)
        state.reload()
        await repositoryLoader.waitForLoads(2)
        repositoryLoader.release(1, with: .success(changed))
        await state.loadTask?.value
        await loader.waitForRequests(2)
        XCTAssertNil(state.wipDetailModel?.lineTotals, "the old counts do not go with the new status")
        let fresh = WorkingLineCounts(
            staged: [FileStat(path: GitPath("staged0.swift"), added: 5, deleted: 0)], unstaged: [], isPartial: false)
        loader.release(1, with: .success(fresh))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 5, deleted: 0))
    }

    /// The `Worktree` segment (S-05) needs no counts; switching back to `Changes` asks for them.
    func testCountsAreAskedForWhenTheChangesSegmentIsShown() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(login)
        state.showWorktreeDetail()
        state.selectWorktree(feature)  // stays on the Worktree segment
        await loader.waitForRequests(1)
        XCTAssertEqual(loader.requestedPaths, [login], "only the worktree selected on Changes")

        state.showChanges()
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.requestedPaths, [login, feature])
        loader.release(1, with: .success(featureCounts))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 32, deleted: 6))
    }

    func testLateAnswerForAnotherWorktreeIsDropped() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        let first = state.lineCountTask
        state.selectWorktree(login)
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.requestedPaths, [feature, login])

        loader.release(0, with: .success(featureCounts))
        await first?.value
        XCTAssertEqual(state.wipDetailModel?.title, "fix/login")
        XCTAssertNil(state.wipDetailModel?.lineTotals, "feature's counts are not shown for login")

        loader.release(
            1,
            with: .success(
                WorkingLineCounts(
                    staged: [], unstaged: [FileStat(path: GitPath("unstaged0.swift"), added: 0, deleted: 3)],
                    isPartial: false)))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineTotals, WipLineTotals(added: 0, deleted: 3))
    }

    func testFailureShowsANoteAndNotQueriedShowsNothing() async {
        let loader = GatedLineCountLoader()
        let state = await loadedState(lineCounts: loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(1)
        loader.release(0, with: .failure(.git(.timeout(seconds: 15))))
        await state.lineCountTask?.value
        XCTAssertEqual(state.wipDetailModel?.lineCountNote, "Line counts unavailable")

        state.selectWorktree(login)
        await loader.waitForRequests(2)
        loader.release(1, with: .success(nil))
        await state.lineCountTask?.value
        XCTAssertNil(state.wipDetailModel?.lineCountNote, "no loaded status in the service: no error shown")
        XCTAssertNil(state.wipDetailModel?.lineTotals)
    }

    /// Without a line count loader (a stub repository loader), the detail simply has no counts.
    func testNoLoaderMeansNoCounts() async {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader())
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        state.selectWorktree(feature)
        XCTAssertNil(state.lineCountTask)
        XCTAssertNil(state.wipDetailModel?.lineCountNote)
    }
}
