import Foundation
import XCTest

@testable import Overgrove

/// `AppState` and auto refresh (#119): watching follows verified loads, requests never replace another load, and a
/// superseded auto refresh is sent again.
@MainActor
final class AppStateAutoRefreshTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent("overgrove-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A listing whose main worktree is a real folder, so the classifier can resolve it.
    private var listing: WorktreeListing {
        WorktreeListing(
            entries: [
                WorktreeListing.entry(
                    root.path, branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
            ],
            isPartial: false)
    }

    private func loadedState(_ loader: TriggerRecordingLoader, watcher: FakeFileWatcher) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, fileWatcher: watcher)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await loader.waitForRequests(1)
        loader.release(0, with: listing)
        await state.loadTask?.value
        return state
    }

    func testWatchingFollowsVerifiedLoadsAndVisibility() async {
        let loader = TriggerRecordingLoader()
        let watcher = FakeFileWatcher()
        let state = await loadedState(loader, watcher: watcher)
        XCTAssertFalse(state.autoRefresh.isWatching, "not visible yet")
        state.autoRefresh.setVisible(true)
        XCTAssertTrue(state.autoRefresh.isWatching)
        XCTAssertEqual(watcher.watchedPaths.last, [root.path, root.appendingPathComponent(".git").path].sorted())

        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        XCTAssertFalse(state.autoRefresh.isWatching, "opening clears the repository's watch until it loads again")
    }

    func testAutoRefreshRequestsNeverReplaceAnotherLoad() async {
        let loader = TriggerRecordingLoader()
        let state = await loadedState(loader, watcher: FakeFileWatcher())
        let change = FileChangeSet(worktrees: [GitPath(root.path)])

        state.reload()  // ⌘R running
        await loader.waitForRequests(2)
        XCTAssertFalse(state.requestAutoRefresh(change), "refused while a load runs")
        XCTAssertEqual(loader.triggers.count, 2)
        loader.release(1, with: listing)
        await state.loadTask?.value

        XCTAssertTrue(state.requestAutoRefresh(change))
        await loader.waitForRequests(3)
        XCTAssertEqual(
            loader.triggers.last, .filesChanged(worktrees: [GitPath(root.path)], refs: false, worktreeList: false))

        // A selection replaces it: the controller gets the change back.
        state.autoRefresh.setVisible(true)
        state.refresh(.worktreeSelected(GitPath(root.path)))
        await loader.waitForRequests(4)
        loader.release(2, with: listing)
        loader.release(3, with: listing)
        await state.loadTask?.value
    }
}
