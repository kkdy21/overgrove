import Foundation
import XCTest

@testable import Overgrove

/// `AppState` WIP detail flows (#66): the model for the selected worktree and the file selection.
@MainActor
final class AppStateWipTests: XCTestCase {
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

    private func loadedState(_ loader: any RepositoryLoading = StubRepositoryLoader()) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
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

    func testDetailFollowsTheSelectedWorktree() async {
        let state = await loadedState()
        XCTAssertEqual(state.wipDetailModel?.title, "main")
        XCTAssertEqual(state.wipDetailModel?.content, .clean)

        state.selectWorktree(feature)
        XCTAssertEqual(state.wipDetailModel?.title, "feat/42-rate-limit")
        XCTAssertEqual(state.wipDetailModel?.groups.map(\.group), [.staged, .unstaged, .untracked])
    }

    func testSelectingAFile() async {
        let state = await loadedState()
        state.selectWorktree(feature)
        let file = FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift"))
        state.selectFile(file)
        XCTAssertEqual(state.selectedFile, file)

        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("not-listed.swift")))
        XCTAssertEqual(state.selectedFile, file, "a file that is not listed is ignored")

        state.clearSelectedFile()
        XCTAssertNil(state.selectedFile)
    }

    func testMovingTheFocusClearsTheFile() async {
        let state = await loadedState()
        state.selectWorktree(feature)
        state.selectFile(FileSelection(worktree: feature, group: .unstaged, path: GitPath("unstaged0.swift")))
        state.selectWorktree(feature)
        XCTAssertNotNil(state.selectedFile, "selecting the same worktree keeps it")
        state.selectWorktree(GitPath("/tmp/dev/api"))
        XCTAssertNil(state.selectedFile)
    }

    func testReloadKeepsAFileThatIsStillListed() async {
        let state = await loadedState()
        state.selectWorktree(feature)
        let file = FileSelection(worktree: feature, group: .untracked, path: GitPath("new0.swift"))
        state.selectFile(file)
        state.reload()
        await state.loadTask?.value
        XCTAssertEqual(state.selectedFile, file)
    }

    func testReloadDropsAFileThatIsGone() async {
        let loader = GatedRepositoryLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await loader.waitForLoads(1)
        loader.release(0, with: .success(.mockup))
        await state.loadTask?.value
        state.selectWorktree(feature)
        state.selectFile(FileSelection(worktree: feature, group: .staged, path: GitPath("staged0.swift")))

        let cleaned = WorktreeListing(
            entries: WorktreeListing.mockup.entries.map { entry in
                entry.worktree.path == feature
                    ? WorktreeListing.Entry(
                        worktree: entry.worktree, state: .loaded(WorktreeListing.state(branch: "feat/42-rate-limit")))
                    : entry
            },
            isPartial: false)
        state.reload()
        await loader.waitForLoads(2)
        loader.release(1, with: .success(cleaned))
        await state.loadTask?.value
        XCTAssertNil(state.selectedFile)
        XCTAssertEqual(state.wipDetailModel?.content, .clean)
    }

    func testUnrepresentablePathCannotBeSelected() async {
        let path = GitPath(raw: Data([0x61, 0xFF]))
        let listing = WorktreeListing(
            entries: [
                WorktreeListing.Entry(
                    worktree: WorktreeListing.mockup.entries[0].worktree,
                    state: .loaded(
                        WorkingState(
                            headCommit: nil, head: .branch("main"), upstream: .none, stashCount: 0, staged: [],
                            unstaged: [], untracked: [FileChange(path: path, status: .untracked)], conflicted: [],
                            isPartial: false, skippedRecords: 0)))
            ],
            isPartial: false)
        let state = await loadedState(StubRepositoryLoader(result: .success(listing)))
        state.selectFile(FileSelection(worktree: GitPath("/tmp/dev/api"), group: .untracked, path: path))
        XCTAssertNil(state.selectedFile)
    }

    func testNoDetailWithoutAWorktreeSelection() {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader())
        XCTAssertNil(state.wipDetailModel)
    }
}
