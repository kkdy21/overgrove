import Foundation
import XCTest

@testable import Overgrove

/// `AppState` with Back and Forward (#378, interaction.md §1.4): what is recorded, what a move restores, what clears.
@MainActor
final class AppStateSelectionHistoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let main = GitPath("/tmp/dev/api")
    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let stash = StashDetailModelTests.stash(0)

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func repository(_ path: String = "/tmp/dev/api") -> Repository {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return Repository(rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
    }

    private func loadedState() async throws -> AppState {
        var listing = WorktreeListing.mockup
        listing.stashes = [stash]
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), stashLoader: StubStashLoader(),
            graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader())
        state.open(RepositoryContext(repository: repository(), owner: nil))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return state
    }

    func testBackAndForwardRestoreTheSelectionAndItsFocus() async throws {
        let state = try await loadedState()
        let start = try XCTUnwrap(state.selection)
        let commit = SampleGraphLoader.oid("4")
        state.selectCommit(commit)
        state.selectWorktree(feature)
        state.selectStash(stash.oid)
        XCTAssertTrue(state.canGoBackInSelection)

        XCTAssertTrue(state.goBackInSelection())
        XCTAssertEqual(state.selection, .wip(feature))
        XCTAssertEqual(state.focusedWorktreePath, feature)

        XCTAssertTrue(state.goBackInSelection())
        XCTAssertEqual(state.selection, .commit(commit))
        XCTAssertNotEqual(state.focusedWorktreePath, feature, "the focus it was chosen with comes back")
        XCTAssertEqual(state.graph.selected, commit)

        XCTAssertTrue(state.goBackInSelection())
        XCTAssertEqual(state.selection, start)
        XCTAssertFalse(state.canGoBackInSelection)
        XCTAssertFalse(state.goBackInSelection())

        XCTAssertTrue(state.goForwardInSelection())
        XCTAssertEqual(state.selection, .commit(commit))
        XCTAssertTrue(state.goForwardInSelection())
        XCTAssertTrue(state.goForwardInSelection())
        XCTAssertEqual(state.selection, .stash(stash.oid))
        XCTAssertFalse(state.canGoForwardInSelection, "moves are not recorded as new entries")
    }

    /// `⌘I` and refreshes are not entries (§1.4).
    func testSegmentSwitchesAndRefreshesAreNotRecorded() async throws {
        let state = try await loadedState()
        state.selectWorktree(feature)
        state.showWorktreeDetail()
        state.showChanges()
        state.showWorktreeDetail()
        state.reload()
        await state.loadTask?.value
        XCTAssertTrue(state.goBackInSelection())
        XCTAssertEqual(state.selection?.worktreePath, main, "one step back is the worktree before")
        XCTAssertFalse(state.canGoBackInSelection)
    }

    /// A stash that is gone is skipped and the move lands on the entry before it.
    func testAMissingTargetIsSkipped() async throws {
        let state = try await loadedState()
        let commit = SampleGraphLoader.oid("4")
        state.selectCommit(commit)
        state.selectStash(stash.oid)
        state.selectWorktree(feature)
        // The stash is dropped (in Terminal): the listing no longer has it.
        guard case .loaded(var listing) = state.worktreeList else { return XCTFail("not loaded") }
        listing.stashes = []
        state.worktreeList = .loaded(listing)
        XCTAssertTrue(state.goBackInSelection())
        XCTAssertEqual(state.selection, .commit(commit))
    }

    /// Entries point at one repository's objects, so opening another empties the history.
    func testOpeningAnotherRepositoryClearsTheHistory() async throws {
        let state = try await loadedState()
        state.selectCommit(SampleGraphLoader.oid("4"))
        XCTAssertTrue(state.canGoBackInSelection)
        state.open(RepositoryContext(repository: repository("/tmp/dev/other"), owner: nil))
        XCTAssertFalse(state.canGoBackInSelection)
        XCTAssertFalse(state.canGoForwardInSelection)
    }
}
