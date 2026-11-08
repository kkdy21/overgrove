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
        return .patch(TestFixtures.patch("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"))
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

/// Answers loads in order; a `nil` slot fails the load with the next of `failures` (the last one repeats).
final class FailingRepositoryLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [WorktreeListing?]
    private var failures: [RepositoryLoadError]

    init(_ answers: [WorktreeListing?], failures: [RepositoryLoadError] = [.git(.timeout(seconds: 15))]) {
        self.answers = answers
        self.failures = failures
    }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        let (answer, failure) = lock.withLock {
            let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
            let failure = failures.count > 1 && answer == nil ? failures.removeFirst() : failures[0]
            return (answer, failure)
        }
        guard let answer else { throw failure }
        return answer
    }
}

/// #374: the worktree list failing to load leaves an open S-11 shown but stale (interaction.md §4.1): dimmed with a
/// notice, and nothing in it runs git again until a load succeeds. `‹ Graph` still closes it.
@MainActor
final class AppStateComparisonStaleTests: XCTestCase {
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

    private func comparedState(
        _ loader: StubComparisonLoader, answers: [WorktreeListing?], diff: StubDiffLoader = StubDiffLoader(),
        failures: [RepositoryLoadError] = [.git(.timeout(seconds: 15))]
    ) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: FailingRepositoryLoader(answers, failures: failures), inspector: RecordingInspector(),
            diffLoader: diff,
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
        state.showComparison()
        await state.comparisonTask?.value
        return state
    }

    func testFailedListLoadKeepsTheComparisonStale() async {
        let loader = StubComparisonLoader()
        let diff = StubDiffLoader()
        let state = await comparedState(loader, answers: [.mockup, nil, nil, .mockup], diff: diff)
        XCTAssertNil(state.comparisonModel?.staleNotice)
        let before = state.comparisonModel

        state.reload()
        await state.loadTask?.value
        guard case .failed = state.worktreeList else { return XCTFail("the list load should fail") }
        XCTAssertEqual(state.comparison?.worktree, feature, "S-11 stays open")
        XCTAssertEqual(state.comparisonModel?.staleNotice, ComparisonModel.listFailedNotice)
        XCTAssertEqual(state.comparisonModel?.files, before?.files, "the last result stays shown, WIP pills too")

        let requests = loader.compareRequests.count
        let base = state.comparison?.base
        state.setIncludeUncommitted(false)
        state.chooseComparisonBase(FullRefName("refs/remotes/origin/develop")!)
        state.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
        state.selectComparisonFile(ComparisonFile(path: GitPath("new0.swift"), isUntracked: true))
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.count, requests, "no new comparison on a stale basis")
        XCTAssertEqual(loader.patchRequests, [])
        XCTAssertEqual(diff.requests.count, 0, "no untracked preview either")
        XCTAssertEqual(state.comparison?.includeUncommitted, true)
        XCTAssertEqual(state.comparison?.base, base, "the base stays")

        // A retry after the failure shows `.loading` until it ends: still stale, still nothing runs.
        state.reload()
        guard case .loading = state.worktreeList else { return XCTFail("a retry shows the list as loading") }
        XCTAssertEqual(state.comparisonModel?.staleNotice, ComparisonModel.listFailedNotice)
        XCTAssertEqual(state.comparisonModel?.files, before?.files)
        state.setIncludeUncommitted(false)
        XCTAssertEqual(loader.compareRequests.count, requests)
        await state.loadTask?.value
        XCTAssertNotNil(state.comparisonModel?.staleNotice, "the retry failed too")

        state.reload()
        await state.loadTask?.value
        XCTAssertNil(state.comparisonModel?.staleNotice, "a successful load clears it")
        state.setIncludeUncommitted(false)
        await state.comparisonTask?.value
        XCTAssertEqual(loader.compareRequests.count, requests + 1)
    }

    /// A patch asked before the list failed is dropped, not shown as new under the stale notice.
    func testListFailureDropsAPatchInFlight() async {
        let state = await comparedState(StubComparisonLoader(), answers: [.mockup])
        state.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
        XCTAssertEqual(state.comparison?.patch, .loading)
        state.comparisonListFailed(.git(.timeout(seconds: 15)))
        XCTAssertNil(state.comparisonPatchTask)
        XCTAssertNil(state.comparison?.patch)
        XCTAssertNil(state.comparison?.selectedFile)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(state.comparison?.patch, "the dropped patch never lands")
        XCTAssertNotNil(state.comparison, "S-11 stays open")
    }

    /// #401: a security stop (`.blocked`) is not "could not be read": S-11 closes, and a patch in flight is
    /// cancelled, so the security state shows instead. A transient failure keeps the stale view (above).
    func testBlockedListLoadClosesTheComparison() async {
        let loader = StubComparisonLoader()
        let state = await comparedState(
            loader, answers: [.mockup, nil], failures: [.blocked(reason: "filter driver name not allowed")])
        state.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
        XCTAssertNotNil(state.comparisonPatchTask)

        state.reload()
        await state.loadTask?.value
        guard case .failed = state.worktreeList else { return XCTFail("the list load should fail") }
        XCTAssertNil(state.comparison, "a security stop closes S-11")
        XCTAssertNil(state.comparisonModel)
        XCTAssertNil(state.comparisonTask)
        XCTAssertNil(state.comparisonPatchTask, "the patch in flight is cancelled")
        let requests = loader.compareRequests.count
        state.setIncludeUncommitted(false)
        XCTAssertEqual(loader.compareRequests.count, requests)
    }

    /// #401: a transient failure while S-11 is already stale, followed by a security stop on the retry, closes it.
    func testBlockedRetryAfterATransientFailureCloses() async {
        let state = await comparedState(
            StubComparisonLoader(), answers: [.mockup, nil, nil],
            failures: [.git(.timeout(seconds: 15)), .blocked(reason: "hook found")])
        state.reload()
        await state.loadTask?.value
        XCTAssertNotNil(state.comparisonModel?.staleNotice, "a transient failure keeps it, stale")
        state.reload()
        await state.loadTask?.value
        XCTAssertNil(state.comparison, "the security stop on the retry closes it")
    }

    /// The mockup listing with the compared worktree in `state` (still listed).
    private func listing(feature state: WorktreeListing.State) -> WorktreeListing {
        WorktreeListing(
            entries: WorktreeListing.mockup.entries.map { entry in
                entry.worktree.path == feature ? WorktreeListing.Entry(worktree: entry.worktree, state: state) : entry
            },
            isPartial: false)
    }

    /// #413: the compared worktree still listed but with its folder gone (`prunable`), or not queried for safety
    /// (its own configuration blocks, another repository's), closes S-11 like a removed worktree (#311).
    func testUnqueryableWorktreeClosesTheComparison() async {
        for state: WorktreeListing.State in [
            .missing, .notQueried(.inspectionBlocked("hook found")), .notQueried(.foreignRepository),
            .notQueried(.duplicate),
        ] {
            let comparisons = await comparedState(StubComparisonLoader(), answers: [.mockup, listing(feature: state)])
            comparisons.reload()
            await comparisons.loadTask?.value
            XCTAssertNil(comparisons.comparison, "\(state) closes S-11")
        }
    }

    /// #413: the compared worktree listed but its status unread (past the query limit, or failed) keeps S-11 open,
    /// stale under its own notice, with the last rows and nothing run, until its status loads again.
    func testUnreadWorktreeKeepsTheComparisonStale() async {
        for state: WorktreeListing.State in [.notQueried(.limit), .failed(.timeout(seconds: 15))] {
            let loader = StubComparisonLoader()
            let diff = StubDiffLoader()
            let comparisons = await comparedState(
                loader, answers: [.mockup, listing(feature: state), .mockup], diff: diff)
            let before = comparisons.comparisonModel
            // A patch asked before the load that leaves the status unread is dropped with it.
            comparisons.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
            comparisons.reload()
            await comparisons.loadTask?.value
            XCTAssertEqual(comparisons.comparison?.worktree, feature, "\(state) keeps S-11")
            XCTAssertEqual(comparisons.comparisonModel?.staleNotice, ComparisonModel.worktreeUnreadNotice)
            XCTAssertEqual(comparisons.comparisonModel?.files, before?.files, "the last rows, WIP pills too")
            XCTAssertNil(comparisons.comparisonPatchTask)
            XCTAssertNotEqual(comparisons.comparison?.patch, .loading)

            let requests = loader.compareRequests.count
            let patches = loader.patchRequests.count
            comparisons.setIncludeUncommitted(false)
            comparisons.selectComparisonFile(ComparisonFile(path: GitPath("staged0.swift"), isUntracked: false))
            comparisons.selectComparisonFile(ComparisonFile(path: GitPath("new0.swift"), isUntracked: true))
            await comparisons.comparisonTask?.value
            await comparisons.comparisonPatchTask?.value
            XCTAssertNil(comparisons.comparisonTask)
            XCTAssertNil(comparisons.comparisonPatchTask)
            XCTAssertEqual(comparisons.comparison?.includeUncommitted, true)
            XCTAssertEqual(loader.compareRequests.count, requests)
            XCTAssertEqual(loader.patchRequests.count, patches)
            XCTAssertEqual(diff.requests.count, 0)

            comparisons.reload()
            await comparisons.loadTask?.value
            XCTAssertNil(comparisons.comparisonModel?.staleNotice, "its status loaded again")
        }
    }

    func testStaleComparisonStillCloses() async {
        let state = await comparedState(StubComparisonLoader(), answers: [.mockup, nil])
        state.reload()
        await state.loadTask?.value
        state.closeComparison()
        XCTAssertNil(state.comparison)
    }
}
