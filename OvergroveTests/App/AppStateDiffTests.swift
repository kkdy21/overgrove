import Foundation
import XCTest

@testable import Overgrove

/// Answers every load with a fixed patch and records what was asked.
final class StubDiffLoader: DiffLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(FileSelection, Bool)] = []
    var result: DiffLoadResult

    init(result: DiffLoadResult = .patch(PatchParser.Listing(files: [], isPartial: false))) {
        self.result = result
    }

    var requests: [(FileSelection, Bool)] { lock.withLock { calls } }

    func load(_ file: FileSelection, worktree: Worktree, of repository: Repository, isSubmodule: Bool) async
        -> DiffLoadResult
    {
        lock.withLock { calls.append((file, isSubmodule)) }
        return result
    }
}

/// `AppState` diff flows (#232): picking a file loads its diff; moving away cancels it.
@MainActor
final class AppStateDiffTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ diffLoader: StubDiffLoader) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), inspector: RecordingInspector(), diffLoader: diffLoader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        state.selectWorktree(feature)
        return state
    }

    private var patch: PatchParser.Listing {
        TestFixtures.patch("diff --git a/s b/s\n--- a/s\n+++ b/s\n@@ -1 +1 @@\n-a\n+b\n")
    }

    func testPickingAFileLoadsItsDiff() async {
        let loader = StubDiffLoader()
        loader.result = .patch(patch)
        let state = await loadedState(loader)
        XCTAssertNil(state.diffViewer)

        let file = FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift"))
        state.selectFile(file)
        XCTAssertEqual(state.diffState, .loading)
        XCTAssertEqual(state.diffViewer?.source, "Staged · M")
        await state.diffTask?.value
        guard case .loaded(let document) = state.diffState else {
            return XCTFail("\(String(describing: state.diffState))")
        }
        XCTAssertEqual(document.title, "staged0.swift")
        XCTAssertEqual(document.lineCount, 2)
        XCTAssertEqual(loader.requests.map(\.0), [file])
    }

    func testUnavailableIsShownAsSuch() async {
        let loader = StubDiffLoader(result: .unavailable("nope"))
        let state = await loadedState(loader)
        state.selectFile(FileSelection(worktree: feature, group: .untracked, path: GitPath("new0.swift")))
        await state.diffTask?.value
        XCTAssertEqual(state.diffState, .unavailable("nope"))
        XCTAssertEqual(state.diffViewer?.source, "Untracked · ?")
    }

    func testGoingBackOrMovingTheFocusDropsTheDiff() async {
        let loader = StubDiffLoader()
        let state = await loadedState(loader)
        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift")))
        await state.diffTask?.value
        state.clearSelectedFile()
        XCTAssertNil(state.diffState)
        XCTAssertNil(state.diffViewer)

        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift")))
        await state.diffTask?.value
        state.selectWorktree(GitPath("/tmp/dev/api"))
        XCTAssertNil(state.diffState)
    }

    func testReloadLoadsTheSameFileAgain() async {
        let loader = StubDiffLoader()
        let state = await loadedState(loader)
        state.selectFile(FileSelection(worktree: feature, group: .unstaged, path: GitPath("unstaged0.swift")))
        await state.diffTask?.value
        state.reload()
        await state.loadTask?.value
        await state.diffTask?.value
        XCTAssertEqual(loader.requests.count, 2)
    }

    func testNextFileReplacesTheDiff() async {
        let loader = StubDiffLoader()
        let state = await loadedState(loader)
        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift")))
        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("staged1.swift")))
        await state.diffTask?.value
        // Both loads may run; each records itself off the main actor, so the recording order is not defined. What
        // matters is that the second file was asked for and that only its diff is shown.
        XCTAssertTrue(loader.requests.contains { $0.0.path == GitPath("staged1.swift") })
        guard case .loaded(let document) = state.diffState else { return XCTFail("not loaded") }
        XCTAssertEqual(document.title, "staged1.swift")
    }

    /// Refusals happen before any git runs (unit level of `LiveDiffLoader`).
    func testRefusals() {
        let path = GitPath("lib")
        // Submodules are diffed since #239 pinned `--submodule=short` and `--ignore-submodules=dirty`.
        for group in [WorkingChangeGroup.staged, .unstaged] {
            XCTAssertNil(
                LiveDiffLoader.refusal(FileSelection(worktree: feature, group: group, path: path), isSubmodule: true))
        }
        XCTAssertEqual(
            LiveDiffLoader.refusal(
                FileSelection(worktree: feature, group: .conflicted, path: path), isSubmodule: false),
            LiveDiffLoader.conflicted)
        XCTAssertNotNil(
            LiveDiffLoader.refusal(
                FileSelection(worktree: feature, group: .staged, path: GitPath(raw: Data([0x61, 0xFF]))),
                isSubmodule: false))
    }
}
