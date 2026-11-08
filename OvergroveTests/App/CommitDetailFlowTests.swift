import Foundation
import XCTest

@testable import Overgrove

/// Answers commit loads with fixed results and records them.
final class StubCommitLoader: CommitLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var details: [ObjectID] = []
    private var patches: [GitPath] = []
    private var originalPaths: [GitPath?] = []
    private var patchPairs: [(commit: ObjectID, parent: ObjectID?)] = []
    private var ranges: [(base: ObjectID, target: ObjectID)] = []
    var failure: GitError?
    /// What `files(from:to:)` answers (S-12, #388).
    var comparedFiles: [FileStat] = [CommitDetailModelTests.stat("a.go", .modified, 2, 1)]

    var detailRequests: [ObjectID] { lock.withLock { details } }
    var patchRequests: [GitPath] { lock.withLock { patches } }
    var originalPathRequests: [GitPath?] { lock.withLock { originalPaths } }
    var patchPairRequests: [(commit: ObjectID, parent: ObjectID?)] { lock.withLock { patchPairs } }
    var rangeRequests: [(base: ObjectID, target: ObjectID)] { lock.withLock { ranges } }

    func files(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<NumstatParser.Files, GitError>
    {
        lock.withLock { ranges.append((base, target)) }
        if let failure { return .failure(failure) }
        return .success(NumstatParser.Files(files: comparedFiles, isPartial: false))
    }

    func detail(_ repository: Repository, of commit: ObjectID) async -> Result<CommitDetail, GitError> {
        lock.withLock { details.append(commit) }
        if let failure { return .failure(failure) }
        return .success(
            CommitDetail(
                oid: commit, parents: [], authorName: "Alice Example", authorEmail: "alice@example.com",
                authorDate: Date(timeIntervalSince1970: 0), committerName: "Alice Example",
                committerEmail: "alice@example.com", committerDate: Date(timeIntervalSince1970: 0),
                message: "subject\n\nbody\n", files: [CommitDetailModelTests.stat("a.go", .modified, 2, 1)],
                isPartial: false))
    }

    func patch(
        _ repository: Repository, of commit: ObjectID, parent: ObjectID?, path: GitPath, originalPath: GitPath?
    ) async -> Result<PatchParser.Listing, GitError> {
        lock.withLock {
            patches.append(path)
            originalPaths.append(originalPath)
            patchPairs.append((commit, parent))
        }
        return .success(
            TestFixtures.patch("diff --git a/a.go b/a.go\n--- a/a.go\n+++ b/a.go\n@@ -1 +1 @@\n-x\n+y\n")
        )
    }
}

/// `CommitDetailStore` and the AppState flow: graph row → S-03, file → S-10, back to the graph (#69).
@MainActor
final class CommitDetailFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let repository = Repository(
        rootURL: URL(fileURLWithPath: "/tmp/dev/api"), commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"),
        isBare: false)

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStoreLoadsOnceAndDropsAnOlderSelection() async {
        let loader = StubCommitLoader()
        let store = CommitDetailStore(loader: loader)
        let first = SampleGraphLoader.commits[0]
        let second = SampleGraphLoader.commits[1]

        store.show(first, in: repository)
        XCTAssertEqual(store.detail, .loading, "the header shows at once; files load")
        store.show(second, in: repository)
        await store.task?.value
        XCTAssertEqual(store.commit?.oid, second.oid)
        guard case .loaded(let detail) = store.detail else { return XCTFail("\(String(describing: store.detail))") }
        XCTAssertEqual(detail.oid, second.oid, "the first selection's result never lands")

        store.show(second, in: repository)
        XCTAssertEqual(loader.detailRequests.filter { $0 == second.oid }.count, 1, "the same commit is not reloaded")
    }

    func testStoreShowsAFailureAndAFileDiff() async {
        let loader = StubCommitLoader()
        loader.failure = .timeout(seconds: 15)
        let store = CommitDetailStore(loader: loader)
        store.show(SampleGraphLoader.commits[3], in: repository)
        await store.task?.value
        XCTAssertEqual(store.detail, .failed(GitError.timeout(seconds: 15).message))

        store.selectFile(CommitDetailModelTests.stat("a.go", .modified, 2, 1))
        await store.fileTask?.value
        guard case .loaded(let document) = store.fileDiff else {
            return XCTFail("\(String(describing: store.fileDiff))")
        }
        XCTAssertEqual(document.title, "a.go")
        XCTAssertEqual(document.source.label, "4444444 · vs first parent", "a merge diffs against its first parent")
        store.clearFile()
        XCTAssertNil(store.fileDiff)
    }

    /// #309: a renamed file's patch is asked for with its old name, so git pairs them instead of showing an add.
    func testRenamedFilePassesItsOldName() async {
        let loader = StubCommitLoader()
        let store = CommitDetailStore(loader: loader)
        store.show(SampleGraphLoader.commits[1], in: repository)
        await store.task?.value
        store.selectFile(
            FileStat(
                path: GitPath("new.go"), originalPath: GitPath("old.go"), status: .renamed(score: 90), added: 1,
                deleted: 0))
        await store.fileTask?.value
        XCTAssertEqual(loader.patchRequests, [GitPath("new.go")])
        XCTAssertEqual(loader.originalPathRequests, [GitPath("old.go")])
    }

    private func loadedState(_ loader: StubCommitLoader) async throws -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)), graphLoader: SampleGraphLoader(),
            commitLoader: loader)
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return state
    }

    func testGraphRowFileAndBack() async throws {
        let loader = StubCommitLoader()
        let state = try await loadedState(loader)
        let commit = SampleGraphLoader.commits[1]

        state.selectCommit(commit.oid)
        XCTAssertEqual(state.selection, .commit(commit.oid))
        XCTAssertEqual(state.graph.selected, commit.oid)
        XCTAssertEqual(state.commitDetailModel?.title, PathValidator.displayable(commit.subject))
        await state.commitDetail.task?.value
        guard case .loaded(let rows, _) = state.commitDetailModel?.files else { return XCTFail("files") }

        state.selectCommitFile(rows[0].stat)
        await state.commitDetail.fileTask?.value
        XCTAssertEqual(state.diffViewer?.source, "3333333 · M")
        XCTAssertEqual(loader.patchRequests, [GitPath("a.go")])

        state.clearSelectedFile()  // ⎋ back to the graph
        XCTAssertNil(state.diffViewer)
        XCTAssertEqual(state.selection, .commit(commit.oid), "the commit stays selected")

        state.selectCommit(SampleGraphLoader.oid("9"))
        XCTAssertEqual(state.selection, .commit(commit.oid), "a commit the graph has not loaded is ignored")
    }
}
