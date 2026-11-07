import Foundation
import XCTest

@testable import Overgrove

/// `AppState` and the graph polish of #255: the author filter with the search, remembered columns, and lane colours.
@MainActor
final class AppStateGraphPolishTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func context(_ path: String) -> RepositoryContext {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return RepositoryContext(
            repository: Repository(
                rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
            owner: nil)
    }

    /// Six commits by Alice (3, one AI-assisted), Bo (2), and Chris (1): `SampleGraphLoader`.
    private func loadedState() async throws -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(.mockup)),
            graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader())
        state.open(context("/tmp/dev/api"))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return state
    }

    private func oids(_ names: String) -> Set<ObjectID> {
        Set(names.map(SampleGraphLoader.oid))
    }

    func testAuthorChipsCountTheLoadedCommits() async throws {
        let state = try await loadedState()
        let summary = try XCTUnwrap(state.graphAuthorSummary)
        XCTAssertEqual(summary.chips.map(\.name), ["Alice Example", "Bo Kim", "Chris Lee"])
        XCTAssertEqual(summary.chips.map(\.count), [3, 2, 1])
        XCTAssertEqual(summary.aiAssistedCount, 1)
        XCTAssertEqual(state.authorSummaryCache?.summary, summary, "cached until the pages change")
        XCTAssertNil(state.graphAuthorFilter, "All: nothing dimmed")
    }

    func testPickingAChipDimsOtherAuthorsAndTogglesBack() async throws {
        let state = try await loadedState()
        state.selectAuthorFilter(.author("bo@example.com"))
        XCTAssertEqual(state.graphAuthorFilter?.matchSet, oids("34"))

        state.selectAuthorFilter(.aiAssisted)
        XCTAssertEqual(state.graphAuthorFilter?.matchSet, oids("1"))

        state.selectAuthorFilter(.aiAssisted)
        XCTAssertEqual(state.authorFilter, .all, "picking the chosen chip again shows everyone")
        XCTAssertNil(state.graphAuthorFilter)
    }

    func testSearchWithAChipIsAnAnd() async throws {
        let state = try await loadedState()
        // `ratelimit` matches commits 1 and 2, both by Alice; `timeout` matches 4 (Bo) and 6 (Chris).
        state.searchText = "timeout"
        XCTAssertEqual(state.graphSearch?.matchSet, oids("46"))

        state.selectAuthorFilter(.author("chris@example.com"))
        let both = try XCTUnwrap(state.graphSearch)
        XCTAssertEqual(both.matches, [SampleGraphLoader.oid("6")])
        XCTAssertEqual(both.summary, "1 match in all 6 commits")

        state.findNext()
        XCTAssertEqual(state.selection, .commit(SampleGraphLoader.oid("6")))
        state.findNext()
        XCTAssertEqual(state.selection, .commit(SampleGraphLoader.oid("6")), "Bo's match is skipped")

        state.selectAuthorFilter(.author("alice@example.com"))
        XCTAssertEqual(state.graphSearch?.matches, [], "no commit matches both")
        XCTAssertFalse(state.canFindMatch)
    }

    func testOpeningAnotherRepositoryClearsTheChip() async throws {
        let state = try await loadedState()
        state.selectAuthorFilter(.aiAssisted)
        state.open(context("/tmp/dev/web"))
        XCTAssertEqual(state.authorFilter, .all)
    }

    func testColumnsAreRememberedPerRepository() async throws {
        let state = try await loadedState()
        XCTAssertEqual(state.graphColumns, .default)
        let narrow = GraphColumnLayout.default.setting(.author, to: 150).toggling(.sha)
        state.commitGraphColumns(narrow)
        XCTAssertEqual(state.graphColumns, narrow)

        state.open(context("/tmp/dev/web"))
        XCTAssertEqual(state.graphColumns, .default, "another repository has its own columns")

        state.open(context("/tmp/dev/api"))
        XCTAssertEqual(state.graphColumns, narrow, "restored on reopening")
    }

    func testWorktreeTilesUseTheLaneOfTheirBranchTip() async throws {
        let state = try await loadedState()
        let tip = SampleGraphLoader.oid("1")
        let index = try XCTUnwrap(state.graph.index(of: tip))
        XCTAssertEqual(state.graph.laneIndex(of: tip), state.graph.rows[index].colorIndex)
        XCTAssertNil(state.graph.laneIndex(of: FakeGraphLoader.oid(9_999)), "not loaded")
        // The mockup listing's tips are not in this history: every tile stays neutral.
        XCTAssertEqual(state.worktreeListModel?.rows.compactMap(\.laneIndex), [])
    }
}
