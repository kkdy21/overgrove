import Foundation
import XCTest

@testable import Overgrove

/// `AppState` search flows (#74): the toolbar search over the loaded graph and ⌘G / ⌘⇧G.
@MainActor
final class AppStateSearchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(count: Int = 12) async throws -> (AppState, [CommitNode]) {
        let commits = FakeGraphLoader.linear(count)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(.mockup)),
            graphLoader: FakeGraphLoader(count: count), commitLoader: StubCommitLoader())
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        // The graph loads in its own task; wait for its first page (as AppStateNavigationTests does).
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return (state, commits)
    }

    func testSearchMatchesLoadedCommitsAndSteps() async throws {
        let (state, commits) = try await loadedState()
        XCTAssertNil(state.graphSearch, "no query, nothing dimmed")
        XCTAssertFalse(state.canFindMatch)

        // `commit 1`, `commit 10`, `commit 11`.
        state.searchText = "COMMIT 1"
        let result = try XCTUnwrap(state.graphSearch)
        XCTAssertEqual(result.matches, [commits[1].oid, commits[10].oid, commits[11].oid])
        XCTAssertEqual(result.summary, "3 matches in all 12 commits")
        XCTAssertTrue(state.canFindMatch)

        state.findNext()
        XCTAssertEqual(state.selection, .commit(commits[1].oid))
        XCTAssertEqual(state.graph.scrollTarget?.oid, commits[1].oid)
        state.findNext()
        state.findNext()
        XCTAssertEqual(state.selection, .commit(commits[11].oid))
        state.findNext()
        XCTAssertEqual(state.selection, .commit(commits[1].oid), "wraps")
        state.findPrevious()
        XCTAssertEqual(state.selection, .commit(commits[11].oid))

        // ⎋ clears the query first (interaction.md §3.1 ②).
        state.escape()
        XCTAssertEqual(state.searchText, "")
        XCTAssertNil(state.graphSearch)
    }

    func testSearchIsCachedUntilTheQueryChanges() async throws {
        let (state, _) = try await loadedState()
        state.searchText = "commit 3"
        let first = try XCTUnwrap(state.graphSearch)
        XCTAssertEqual(state.searchCache?.result, first)
        state.searchText = "commit"
        XCTAssertEqual(state.graphSearch?.matches.count, 12)
        XCTAssertNotEqual(state.searchCache?.result, first)
    }

    /// SEC-T15-16: a new page adds only its own commits to the search; new refs or focus rebuild it.
    func testNewPagesExtendTheSearch() async throws {
        let (state, _) = try await loadedState(count: GraphStore.pageSize + 100)
        state.searchText = "commit"
        XCTAssertEqual(state.graphSearch?.scannedCount, GraphStore.pageSize)
        state.graph.rowAppeared(GraphStore.pageSize - 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.commits.count < GraphStore.pageSize + 100, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let extended = try XCTUnwrap(state.graphSearch)
        XCTAssertEqual(extended.scannedCount, 100, "only the new page")
        XCTAssertEqual(extended.matches.count, GraphStore.pageSize + 100)
        XCTAssertEqual(
            extended.summary,
            "\((GraphStore.pageSize + 100).formatted()) matches in all \((GraphStore.pageSize + 100).formatted()) commits"
        )

        state.graph.setFocus(nil)
        XCTAssertEqual(state.graphSearch?.scannedCount, GraphStore.pageSize + 100, "new ref pills: searched again")
    }

    func testSidebarFilterRequestAndReset() async throws {
        let (state, _) = try await loadedState()
        state.focusSidebarFilter()
        XCTAssertEqual(state.sidebarFilterFocusRequest, 1)
        state.sidebarFilter = "feat"
        state.searchText = "x"
        let root = URL(fileURLWithPath: "/tmp/dev/web", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        XCTAssertEqual(state.sidebarFilter, "")
        XCTAssertEqual(state.searchText, "")
    }
}
