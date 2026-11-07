import Foundation
import XCTest

@testable import Overgrove

/// Answers comparisons with fixed results and records the requests.
final class StubComparisonLoader: ComparisonLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var compares: [(GitPath, FullRefName?, Bool)] = []
    private var patches: [GitPath] = []
    private var originals: [GitPath?] = []
    var bases = ComparisonBases(
        all: [FullRefName("refs/heads/main")!, FullRefName("refs/remotes/origin/develop")!],
        preferred: FullRefName("refs/heads/main"))
    var result: Result<WorktreeComparison, ComparisonError>?

    var compareRequests: [(GitPath, FullRefName?, Bool)] { lock.withLock { compares } }
    var patchRequests: [GitPath] { lock.withLock { patches } }
    var originalPathRequests: [GitPath?] { lock.withLock { originals } }

    func bases(of repository: Repository) async -> ComparisonBases { bases }

    func compare(_ repository: Repository, worktree: GitPath, base: FullRefName?, includeUncommitted: Bool) async
        -> Result<WorktreeComparison, ComparisonError>
    {
        lock.withLock { compares.append((worktree, base, includeUncommitted)) }
        if let result { return result }
        return .success(
            ComparisonModelTests.comparison(
                base: base ?? FullRefName("refs/heads/main")!,
                files: [ComparisonModelTests.stat("staged0.swift", .modified, 2, 1)], untracked: ["new0.swift"],
                includesWorkingTree: includeUncommitted))
    }

    func patch(
        _ repository: Repository, worktree: GitPath, base: FullRefName, file: GitPath, originalPath: GitPath?,
        includeUncommitted: Bool
    ) async -> DiffLoadResult {
        lock.withLock {
            patches.append(file)
            originals.append(originalPath)
        }
        return .patch(try! PatchParser.parse(Data("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n".utf8)))
    }
}

/// `AppState` S-11 flows (#158).
@MainActor
final class AppStateComparisonTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let develop = FullRefName("refs/remotes/origin/develop")!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ loader: StubComparisonLoader, diff: StubDiffLoader = StubDiffLoader()) async
        -> AppState
    {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), inspector: RecordingInspector(), diffLoader: diff,
            comparisonLoader: loader)
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

    func testOpeningComparesWithThePreferredBase() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        XCTAssertTrue(state.canCompare())
        state.showComparison()
        XCTAssertEqual(state.comparison?.result, .loading)
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.map(\.1), [FullRefName("refs/heads/main")])
        XCTAssertEqual(loader.compareRequests.map(\.2), [true], "uncommitted changes are included by default")
        XCTAssertEqual(state.comparison?.bases.count, 2)
        XCTAssertEqual(state.comparisonModel?.state, .loaded)
        XCTAssertEqual(state.comparisonModel?.files.map(\.fileName), ["staged0.swift"])
    }

    func testChosenBaseIsRememberedPerWorktree() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        state.chooseComparisonBase(develop)
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.last?.1, develop)
        XCTAssertEqual(state.comparisonModel?.baseName, "origin/develop")

        state.closeComparison()
        XCTAssertNil(state.comparison)
        state.showComparison()
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.last?.1, develop, "remembered for this worktree")
    }

    func testIncludeUncommittedToggleRecompares() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        state.setIncludeUncommitted(false)
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.map(\.2), [true, false])
        state.setIncludeUncommitted(false)
        XCTAssertEqual(loader.compareRequests.count, 2, "no change, no request")
    }

    func testPickingFilesLoadsTheirPatches() async {
        let loader = StubComparisonLoader()
        let diff = StubDiffLoader(result: .patch(PatchParser.Listing(files: [], isPartial: false)))
        let state = await loadedState(loader, diff: diff)
        state.showComparison()
        await state.comparisonTask?.value

        state.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
        XCTAssertEqual(state.comparison?.patch, .loading)
        await state.comparisonPatchTask?.value
        XCTAssertEqual(loader.patchRequests, [GitPath("staged0.swift")])
        guard case .loaded(let document) = state.comparison?.patch else { return XCTFail("no patch") }
        // The mockup worktree also has staged changes to this file.
        XCTAssertEqual(document.source, DiffDocument.Source(label: "Committed + uncommitted", kindLetter: "M"))

        state.selectComparisonFile(ComparisonFile(path: GitPath("new0.swift"), isUntracked: true))
        await state.comparisonPatchTask?.value
        XCTAssertEqual(diff.requests.map(\.0.group), [.untracked], "untracked files use the S-02 preview")

        state.selectComparisonFile(ComparisonFile(path: GitPath("not-listed"), isUntracked: false))
        XCTAssertEqual(state.comparison?.selectedFile?.path, GitPath("new0.swift"), "unlisted files are ignored")
    }

    /// #309: a renamed file's patch is asked for with its old name.
    func testRenamedFilePassesItsOldName() async {
        let loader = StubComparisonLoader()
        loader.result = .success(
            ComparisonModelTests.comparison(files: [
                FileStat(
                    path: GitPath("new.swift"), originalPath: GitPath("old.swift"), status: .renamed(score: 95),
                    added: 1, deleted: 0)
            ]))
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        state.selectComparisonFile(ComparisonFile(path: GitPath("new.swift"), isUntracked: false))
        await state.comparisonPatchTask?.value
        XCTAssertEqual(loader.patchRequests, [GitPath("new.swift")])
        XCTAssertEqual(loader.originalPathRequests, [GitPath("old.swift")])
    }

    func testUnlistedBaseIsIgnoredAndSelectionsStayInTheirSection() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        state.chooseComparisonBase(FullRefName("refs/heads/not-listed")!)
        XCTAssertEqual(loader.compareRequests.count, 1, "only listed branches can be chosen")
        // A tracked path cannot be picked as untracked, and the other way round.
        state.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: true))
        state.selectComparisonFile(ComparisonFile(path: GitPath("new0.swift"), isUntracked: false))
        XCTAssertNil(state.comparison?.selectedFile)
    }

    /// A comparison that finishes after the base changed is dropped.
    func testLateResultIsDropped() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        state.showComparison()
        state.chooseComparisonBase(develop)  // ignored until the base list has loaded
        await state.comparisonTask?.value
        state.chooseComparisonBase(develop)
        state.setIncludeUncommitted(false)
        await state.comparisonTask?.value
        XCTAssertEqual(state.comparison?.base, develop)
        guard case .loaded(let comparison) = state.comparison?.result else { return XCTFail("not loaded") }
        XCTAssertFalse(comparison.includesWorkingTree, "the latest request wins")
    }

    func testFailureAndClosing() async {
        let loader = StubComparisonLoader()
        loader.result = .failure(.noBaseBranch)
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        XCTAssertEqual(
            state.comparisonModel?.state, .failed(message: ComparisonError.noBaseBranch.message, canChooseBase: true))

        state.selectWorktree(GitPath("/tmp/dev/api"))
        XCTAssertNil(state.comparison, "S-11 belongs to one worktree")
    }

    func testNoBaseAtAllFailsWithoutAsking() async {
        let loader = StubComparisonLoader()
        loader.bases = ComparisonBases(all: [], preferred: nil)
        let state = await loadedState(loader)
        state.showComparison()
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.count, 0)
        XCTAssertEqual(state.comparison?.result, .failed(.noBaseBranch))
    }

    /// Only worktrees with a loaded status can be compared (#157 needs it).
    func testMissingWorktreeCannotBeCompared() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        let missing = GitPath("/tmp/dev/api-wt/old-spike")
        XCTAssertFalse(state.canCompare(missing))
        state.showComparison(of: missing)
        XCTAssertNil(state.comparison)
    }

    func testComparingAnotherWorktreeFocusesIt() async {
        let loader = StubComparisonLoader()
        let state = await loadedState(loader)
        let login = GitPath("/tmp/dev/api-wt/login")
        state.showComparison(of: login)
        XCTAssertEqual(state.focusedWorktreePath, login)
        XCTAssertEqual(state.comparison?.worktree, login)
    }
}
