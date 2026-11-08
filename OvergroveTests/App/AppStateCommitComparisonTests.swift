import Foundation
import XCTest

@testable import Overgrove

/// S-12 in `AppState` (#388, screens.md S-12): opening from a graph row, loading, swapping, closing, and the file patch.
@MainActor
final class AppStateCommitComparisonTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let base = SampleGraphLoader.oid("4")
    private let target = SampleGraphLoader.oid("1")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ loader: StubCommitLoader = StubCommitLoader()) async throws -> AppState {
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)), graphLoader: SampleGraphLoader(),
            commitLoader: loader)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return state
    }

    /// The menu item is on only against another commit that is the main selection.
    func testTheMenuItemNeedsAnotherSelectedCommit() async throws {
        let state = try await loadedState()
        XCTAssertFalse(state.canCompareCommit(with: target), "the WIP is selected, not a commit")
        state.selectCommit(base)
        XCTAssertTrue(state.canCompareCommit(with: target))
        XCTAssertFalse(state.canCompareCommit(with: base), "not with itself")
        XCTAssertFalse(state.canCompareCommit(with: ObjectID(String(repeating: "9", count: 40))!), "not loaded")
        XCTAssertTrue(state.rowMenuActions.canCompareCommit(target))
    }

    func testOpeningLoadsTheFilesFromBaseToTarget() async throws {
        let loader = StubCommitLoader()
        let state = try await loadedState(loader)
        state.selectCommit(base)
        let historyBefore = state.selectionHistory
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value

        let model = try XCTUnwrap(state.commitComparisonModel)
        XCTAssertEqual(model.title, "\(base.short) → \(target.short)")
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.rows.map(\.stat.path), [GitPath("a.go")])
        XCTAssertEqual(loader.rangeRequests.map(\.base), [base])
        XCTAssertEqual(loader.rangeRequests.map(\.target), [target])
        XCTAssertEqual(state.selection, .commit(base), "the main selection stays the base")
        XCTAssertEqual(state.selectionHistory, historyBefore, "S-12 is not a history entry")

        // A file's patch is the target against the base.
        state.selectCommitComparisonFile(CommitDetailModelTests.stat("a.go", .modified, 2, 1))
        await state.commitComparisonPatchTask?.value
        XCTAssertEqual(loader.patchPairRequests.last?.commit, target)
        XCTAssertEqual(loader.patchPairRequests.last?.parent, base)
        guard case .loaded(let document) = state.commitComparison?.patch else { return XCTFail("no patch") }
        XCTAssertEqual(document.source.label, "\(base.short) → \(target.short)")
    }

    func testSwapAndNoChanges() async throws {
        let loader = StubCommitLoader()
        loader.comparedFiles = []
        let state = try await loadedState(loader)
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value
        XCTAssertEqual(
            state.commitComparisonModel?.state, .noChanges("No changes between \(base.short) and \(target.short)"))
        state.swapCommitComparison()
        await state.commitComparisonTask?.value
        XCTAssertEqual(state.commitComparison?.base, target)
        XCTAssertEqual(state.commitComparison?.target, base)
        XCTAssertEqual(loader.rangeRequests.last?.base, target)
    }

    /// `‹ Graph`, choosing something else, a BASE/TARGET row, and S-11 all close it.
    func testItClosesWhenSomethingElseIsChosen() async throws {
        let state = try await loadedState()
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        state.closeCommitComparison()
        XCTAssertNil(state.commitComparison)

        state.showCommitComparison(with: target)
        state.selectCommit(SampleGraphLoader.oid("6"))
        XCTAssertNil(state.commitComparison, "choosing a graph row closes it")

        state.selectCommit(base)
        state.showCommitComparison(with: target)
        state.showCommitFromComparison(target)
        XCTAssertNil(state.commitComparison)
        XCTAssertEqual(state.selection, .commit(target), "the row opens that commit's S-03")

        state.showCommitComparison(with: base)
        state.showComparison()
        XCTAssertNil(state.commitComparison, "S-11 and S-12 are never open together")
    }

    /// #405: a security stop on the worktree list closes S-12 even without S-11, cancelling its loads and patch; any
    /// other list failure leaves it as it is (two commits do not go out of date).
    func testASecurityStopClosesItAlone() async throws {
        let state = try await loadedState()
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value
        XCTAssertNil(state.comparison, "S-12 alone, without S-11")

        let before = state.commitComparison
        state.comparisonListFailed(.git(.timeout(seconds: 15)))
        XCTAssertEqual(state.commitComparison, before, "a transient failure leaves S-12 as it is")

        state.selectCommitComparisonFile(CommitDetailModelTests.stat("a.go", .modified, 2, 1))
        XCTAssertNotNil(state.commitComparisonPatchTask)
        state.comparisonListFailed(.blocked(reason: "filter driver name not allowed"))
        XCTAssertNil(state.commitComparison, "a security stop closes S-12")
        XCTAssertNil(state.commitComparisonModel)
        XCTAssertNil(state.commitComparisonTask)
        XCTAssertNil(state.commitComparisonPatchTask, "the patch in flight is cancelled")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(state.commitComparison, "nothing in flight brings it back")
    }

    /// #405: a security stop while S-12 is still loading cancels the file list and commits.
    func testASecurityStopCancelsLoads() async throws {
        let state = try await loadedState()
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        XCTAssertNotNil(state.commitComparisonTask)
        state.comparisonListFailed(.blocked(reason: "hook found"))
        XCTAssertNil(state.commitComparisonTask)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(state.commitComparison)

    /// COMMITS (#389): read with the files for the same pair, again after `⇄`; a row opens that commit's S-03.
    func testCommitsBetweenAreListed() async throws {
        let loader = StubCommitLoader()
        let middle = CommitNode(
            oid: SampleGraphLoader.oid("2"), parents: [], authorName: "Bob", authorEmail: "b@example.com",
            authorDate: Date(timeIntervalSince1970: 0), subject: "middle", coAuthors: [])
        loader.commitsBetween = LogParser.GraphPage(commits: [middle], isPartial: true)
        let state = try await loadedState(loader)
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value

        let model = try XCTUnwrap(state.commitComparisonModel)
        XCTAssertEqual(model.commits.map(\.oid), [middle.oid])
        XCTAssertTrue(model.hasMoreCommits)
        XCTAssertNil(model.commitsNotice)
        XCTAssertEqual(loader.commitRangeRequests.map(\.base), [base])
        XCTAssertEqual(loader.commitRangeRequests.map(\.target), [target])

        state.swapCommitComparison()
        await state.commitComparisonTask?.value
        XCTAssertEqual(loader.commitRangeRequests.last?.base, target)
        XCTAssertEqual(loader.commitRangeRequests.last?.target, base)

        state.showCommitFromComparison(middle.oid)
        XCTAssertNil(state.commitComparison)
        XCTAssertEqual(state.selection, .commit(middle.oid))
    }

    /// The commits failing does not hide the file list, and the other way round.
    func testCommitsFailureIsShownOnItsOwn() async throws {
        let loader = StubCommitLoader()
        loader.commitsFailure = .timeout(seconds: 15)
        let state = try await loadedState(loader)
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value
        let model = try XCTUnwrap(state.commitComparisonModel)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.commits.isEmpty)
        XCTAssertNotNil(model.commitsNotice)
        XCTAssertNotEqual(model.commitsNotice, "Reading commits…")
    }

    func testAFailureIsShown() async throws {
        let loader = StubCommitLoader()
        loader.failure = .timeout(seconds: 15)
        let state = try await loadedState(loader)
        // The failure stub also fails S-03's detail; the comparison shows its own failure.
        state.selectCommit(base)
        state.showCommitComparison(with: target)
        await state.commitComparisonTask?.value
        guard case .failed = state.commitComparisonModel?.state else { return XCTFail("not failed") }
    }
}

/// `CommitComparisonModel` (#388): texts and limits, without views.
final class CommitComparisonModelTests: XCTestCase {
    private func oid(_ character: Character) -> ObjectID { ObjectID(String(repeating: character, count: 40))! }

    func testRowsAreCappedAndTextsEscaped() {
        let node = CommitNode(
            oid: oid("b"), parents: [], authorName: "Eve\u{202E}", authorEmail: "e@example.com",
            authorDate: Date(timeIntervalSince1970: 0), subject: "fix\u{7}",
            coAuthors: ["Claude <noreply@anthropic.com>"])
        var session = CommitComparisonSession(base: oid("a"), target: oid("b"))
        let files = (0...CommitDetailModel.fileLimit).map {
            CommitDetailModelTests.stat("f\($0).go", .modified, 1, 0)
        }
        session.files = .loaded(NumstatParser.Files(files: files, isPartial: false))
        let model = CommitComparisonModel(session: session) { $0 == node.oid ? node : nil }
        XCTAssertEqual(model.rows.count, CommitDetailModel.fileLimit)
        XCTAssertEqual(model.hidden, 1)
        XCTAssertEqual(model.summary, "1,001 files · +1001 −0")
        XCTAssertFalse(model.target.subject.unicodeScalars.contains("\u{7}"))
        XCTAssertFalse(model.target.author.unicodeScalars.contains("\u{202E}"))
        XCTAssertTrue(model.target.isAIAssisted)
        XCTAssertEqual(model.base.subject, "", "a commit the graph does not have shows its SHA only")

        session.showsAllFiles = true
        XCTAssertEqual(CommitComparisonModel(session: session) { _ in nil }.rows.count, files.count)
    }

    func testLoadingText() {
        let model = CommitComparisonModel(session: CommitComparisonSession(base: oid("a"), target: oid("b"))) { _ in nil
        }
        XCTAssertEqual(model.state, .loading("Comparing \(oid("a").short) with \(oid("b").short)…"))
        XCTAssertEqual(model.commitsNotice, "Reading commits…")
    }

    /// COMMITS rows come from the log, escaped, with the AI badge; none says which way to look.
    func testCommitRows() {
        let node = CommitNode(
            oid: oid("c"), parents: [], authorName: "Eve\u{202E}", authorEmail: "e@example.com",
            authorDate: Date(timeIntervalSince1970: 0), subject: "fix\u{7}",
            coAuthors: ["Claude <noreply@anthropic.com>"])
        var session = CommitComparisonSession(base: oid("a"), target: oid("b"))
        session.commits = .loaded(LogParser.GraphPage(commits: [node], isPartial: false))
        // The graph does not have it: the row still shows the log's subject.
        let model = CommitComparisonModel(session: session) { _ in nil }
        XCTAssertEqual(model.commits.map(\.oid), [node.oid])
        XCTAssertFalse(model.commits[0].subject.unicodeScalars.contains("\u{7}"))
        XCTAssertFalse(model.commits[0].author.unicodeScalars.contains("\u{202E}"))
        XCTAssertTrue(model.commits[0].isAIAssisted)
        XCTAssertFalse(model.hasMoreCommits)

        session.commits = .loaded(LogParser.GraphPage(commits: [], isPartial: false))
        XCTAssertEqual(
            CommitComparisonModel(session: session) { _ in nil }.commitsNotice,
            "\(oid("b").short) has no commits that \(oid("a").short) does not have")
        session.commits = .failed("fatal\u{202E}")
        XCTAssertFalse(
            CommitComparisonModel(session: session) { _ in nil }.commitsNotice?.unicodeScalars.contains("\u{202E}")
                ?? true)
    }
}
