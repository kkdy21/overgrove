import Foundation
import XCTest

@testable import Overgrove

/// Answers stash loads with fixed results and records them.
final class StubStashLoader: StashLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var fileCalls: [ObjectID] = []
    private var patchCalls: [GitPath] = []

    var fileRequests: [ObjectID] { lock.withLock { fileCalls } }
    var patchRequests: [GitPath] { lock.withLock { patchCalls } }

    func files(of stash: Stash, in repository: Repository, worktree: Worktree?) async -> StashFilesResult {
        lock.withLock { fileCalls.append(stash.oid) }
        return .files(
            StashDetail(
                stash: stash, files: [StashDetailModelTests.file("a.swift", 1, 0)], isPartial: false))
    }

    func patch(of stash: Stash, file: FileStat, in repository: Repository, worktree: Worktree?) async
        -> DiffLoadResult
    {
        lock.withLock { patchCalls.append(file.path) }
        return .patch(TestFixtures.patch("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"))
    }
}

/// `AppState` stash flows (#71).
@MainActor
final class AppStateStashTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let first = StashDetailModelTests.stash(0)
    private let second = StashDetailModelTests.stash(1, subject: "On main: fix", message: "fix")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ loader: StubStashLoader, stashes: [Stash]) async -> AppState {
        var listing = WorktreeListing.mockup
        listing.stashes = stashes
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), stashLoader: loader)
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

    func testSelectingAStashLoadsItsFiles() async {
        let loader = StubStashLoader()
        let state = await loadedState(loader, stashes: [first, second])
        XCTAssertEqual(state.stashes.map(\.refName), ["stash@{0}", "stash@{1}"])
        let focus = state.focusedWorktreePath

        state.selectStash(second.oid)
        XCTAssertEqual(state.selection, .stash(second.oid))
        XCTAssertEqual(state.focusedWorktreePath, focus, "the focused worktree stays")
        XCTAssertNil(state.wipDetailModel)
        await state.stashTask?.value
        XCTAssertEqual(loader.fileRequests, [second.oid])
        XCTAssertEqual(state.stashDetailModel?.refName, "stash@{1}")
        XCTAssertEqual(state.stashDetailModel?.files?.map(\.fileName), ["a.swift"])
    }

    func testPickingAStashFileShowsItsPatch() async {
        let loader = StubStashLoader()
        let state = await loadedState(loader, stashes: [first])
        state.selectStash(first.oid)
        await state.stashTask?.value
        state.selectStashFile(StashDetailModelTests.file("a.swift", 1, 0))
        XCTAssertEqual(state.diffViewer?.state, .loading)
        await state.stashFileTask?.value
        XCTAssertEqual(loader.patchRequests, [GitPath("a.swift")])
        XCTAssertEqual(state.diffViewer?.source, "stash@{0}")
        state.clearSelectedFile()
        XCTAssertNil(state.diffViewer)

        state.selectStashFile(StashDetailModelTests.file("not-listed.swift", 1, 0))
        XCTAssertNil(state.selectedStashFile, "only listed files")
    }

    func testSelectingAWorktreeLeavesTheStash() async {
        let loader = StubStashLoader()
        let state = await loadedState(loader, stashes: [first])
        state.selectStash(first.oid)
        state.selectWorktree(GitPath("/tmp/dev/api"))
        XCTAssertEqual(state.selection, .wip(GitPath("/tmp/dev/api")))
        XCTAssertNil(state.stashDetailModel)
    }

    /// A stash that is gone after a reload (dropped or applied elsewhere) falls back to the focused worktree.
    func testDroppedStashFallsBackOnReload() async {
        let loader = GatedRepositoryLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, stashLoader: StubStashLoader())
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        var withStash = WorktreeListing.mockup
        withStash.stashes = [first]
        state.reload()
        await loader.waitForLoads(1)
        loader.release(0, with: .success(withStash))
        await state.loadTask?.value
        state.selectStash(first.oid)
        XCTAssertEqual(state.selection, .stash(first.oid))
        state.selectStash(ObjectID(String(repeating: "9", count: 40))!)
        XCTAssertEqual(state.selection, .stash(first.oid), "an unknown stash is ignored")

        state.reload()
        await loader.waitForLoads(2)
        loader.release(1, with: .success(.mockup))
        await state.loadTask?.value
        XCTAssertEqual(state.selection, .wip(GitPath("/tmp/dev/api")))
        XCTAssertNil(state.stashDetailModel)
    }
}
