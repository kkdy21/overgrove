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
    }
}
