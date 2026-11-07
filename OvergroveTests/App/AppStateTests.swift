import Foundation
import XCTest

@testable import Overgrove

/// `AppState` (#64): the open repository and its per-repository panel layout.
@MainActor
final class AppStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func context(_ name: String) -> RepositoryContext {
        let root = URL(fileURLWithPath: "/tmp/dev/\(name)", isDirectory: true)
        return RepositoryContext(
            repository: Repository(
                rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
            owner: "acme")
    }

    func testStartsWithNoRepositoryAndTheDefaultLayout() {
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults))
        XCTAssertNil(state.repository)
        XCTAssertEqual(state.panelLayout, .default)
        XCTAssertEqual(state.fetchStatus, .never)
        XCTAssertNil(state.snapshot)
    }

    func testPanelLayoutIsSavedAndRestoredPerRepository() {
        let store = PanelLayoutStore(defaults: defaults)
        let state = AppState(layoutStore: store)
        state.open(context("api"))
        let apiLayout = PanelLayout(sidebarWidth: 300, detailWidth: 400, isDetailCollapsed: true)
        state.commitPanelLayout(apiLayout)

        state.open(context("web"))
        XCTAssertEqual(state.panelLayout, .default, "another repository starts from its own (default) layout")
        state.commitPanelLayout(PanelLayout(sidebarWidth: 240, detailWidth: 344))

        state.open(context("api"))
        XCTAssertEqual(state.panelLayout, apiLayout)
        // A new AppState over the same defaults, as after relaunch.
        let relaunched = AppState(layoutStore: store)
        relaunched.open(context("web"))
        XCTAssertEqual(relaunched.panelLayout.sidebarWidth, 240)
    }

    func testCommitWithoutARepositoryKeepsTheLayoutInMemoryOnly() {
        let store = PanelLayoutStore(defaults: defaults)
        let state = AppState(layoutStore: store)
        let layout = PanelLayout.default.toggling(.sidebar)
        state.commitPanelLayout(layout)
        XCTAssertEqual(state.panelLayout, layout)
        XCTAssertTrue(
            defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(PanelLayoutStore.keyPrefix) },
            "nothing is saved without a repository")
    }

    func testOpeningARepositoryClearsTheOldRepositoryData() {
        let state = AppState(layoutStore: PanelLayoutStore(defaults: defaults))
        state.open(context("api"))
        state.snapshot = RepositorySnapshot(focusedWorktree: nil, worktreeCount: 6, prunableCount: 1)
        state.fetchStatus = .idle(lastFetched: Date())
        state.searchText = "fix"

        state.open(context("web"))
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.fetchStatus, .never)
        XCTAssertEqual(state.searchText, "")
        XCTAssertEqual(state.repository?.name, "web")
    }

    func testTogglePanelSavesForTheOpenRepository() {
        let store = PanelLayoutStore(defaults: defaults)
        let state = AppState(layoutStore: store)
        state.open(context("api"))
        state.togglePanel(.sidebar)
        XCTAssertTrue(state.panelLayout.isSidebarCollapsed)
        XCTAssertTrue(store.layout(for: context("api").repository.id).isSidebarCollapsed)
    }

    func testRepositoryContextNamesComeFromTheFolder() {
        XCTAssertEqual(context("api").name, "api")
        XCTAssertEqual(context("api").owner, "acme")
    }
}
