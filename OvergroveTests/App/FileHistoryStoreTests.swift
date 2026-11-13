import Foundation
import XCTest

@testable import Overgrove

/// Answers history pages from a script and records each request.
final class StubFileHistoryLoader: FileHistoryLoading, @unchecked Sendable {
    struct Request: Equatable {
        let key: FileHistoryTarget.Key
        let skip: Int
    }

    private let lock = NSLock()
    private var results: [FileHistoryLoadResult]
    private var calls: [Request] = []

    init(_ results: [FileHistoryLoadResult]) {
        self.results = results
    }

    var requests: [Request] { lock.withLock { calls } }

    func page(_ target: FileHistoryTarget, skip: Int, limit: Int) async -> FileHistoryLoadResult {
        lock.withLock {
            calls.append(Request(key: target.key, skip: skip))
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// S-09's store (#70): pages, paging, the worktree + path + HEAD cache, and Follow renames.
@MainActor
final class FileHistoryStoreTests: XCTestCase {
    nonisolated static let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
    nonisolated static let repository = Repository(
        rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
    nonisolated static let worktree = Worktree(
        path: GitPath("/tmp/dev/api"), head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
        isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)

    nonisolated static func target(head: String = "a", path: String = "Status.swift") -> FileHistoryTarget {
        FileHistoryTarget(
            repository: repository, worktree: worktree, head: ObjectID(String(repeating: head, count: 40)),
            path: GitPath(path))
    }

    nonisolated static func entry(_ index: Int, path: String = "Status.swift", from original: String? = nil)
        -> FileHistoryEntry
    {
        FileHistoryEntry(
            commit: CommitNode(
                oid: ObjectID(String(format: "%040x", index + 1))!, parents: [], authorName: "Ko",
                authorEmail: "ko@example.com", authorDate: Date(timeIntervalSince1970: 1_793_853_652),
                subject: "commit \(index)"),
            path: GitPath(path), originalPath: original.map(GitPath.init), added: 1, deleted: 0, hasStat: true)
    }

    nonisolated static func page(_ range: Range<Int>, partial: Bool = false) -> FileHistoryLoadResult {
        .page(LogParser.FileHistoryPage(entries: range.map { entry($0) }, isPartial: partial))
    }

    func testOpensTheFirstPageAndEndsWhenShort() async {
        let loader = StubFileHistoryLoader([Self.page(0..<3)])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        XCTAssertEqual(store.status, .loading)
        await store.task?.value
        XCTAssertEqual(store.status, .loaded)
        XCTAssertEqual(store.entries.count, 3)
        XCTAssertTrue(store.isComplete)
        XCTAssertEqual(loader.requests.map(\.skip), [0])
    }

    /// The next page loads near the end, once.
    func testLoadsMoreNearTheEnd() async {
        var first = (0..<FileHistoryStore.pageSize).map { Self.entry($0) }
        first[first.count - 1] = Self.entry(first.count - 1, path: "Status.swift", from: "Parser.swift")
        let loader = StubFileHistoryLoader([
            .page(LogParser.FileHistoryPage(entries: first, isPartial: false)), Self.page(1_000..<1_002),
        ])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        await store.task?.value
        XCTAssertFalse(store.isComplete)
        store.rowAppeared(10)
        XCTAssertFalse(store.isLoadingMore, "far from the end")
        store.rowAppeared(FileHistoryStore.pageSize - FileHistoryStore.prefetchDistance)
        XCTAssertTrue(store.isLoadingMore)
        store.rowAppeared(FileHistoryStore.pageSize - 1)
        await store.task?.value
        XCTAssertEqual(loader.requests.map(\.skip), [0, FileHistoryStore.pageSize], "one request per page")
        XCTAssertEqual(store.entries.count, FileHistoryStore.pageSize + 2)
        XCTAssertTrue(store.isComplete)
    }

    /// Cached per worktree + path + HEAD: reopening runs no git; a moved HEAD or Follow off asks again.
    func testCacheKeyedByWorktreePathAndHead() async {
        let loader = StubFileHistoryLoader([Self.page(0..<2)])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        await store.task?.value
        store.close()
        store.open(Self.target())
        XCTAssertEqual(store.status, .loaded)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(loader.requests.count, 1)

        store.open(Self.target(head: "b"))
        await store.task?.value
        XCTAssertEqual(loader.requests.count, 2, "HEAD moved")
        store.setFollow(false)
        await store.task?.value
        XCTAssertEqual(loader.requests.count, 3)
        XCTAssertEqual(loader.requests.last?.key.follow, false)
        XCTAssertEqual(store.target?.follow, false)

        store.reset()
        store.open(Self.target())
        await store.task?.value
        XCTAssertEqual(loader.requests.count, 4, "another repository's cache is gone")
    }

    /// SEC-T15-15: a history cut by the output limit ends as cut, not as the beginning of the history.
    func testCutAtTheLimitIsNotTheBeginning() async {
        let loader = StubFileHistoryLoader([Self.page(0..<9, partial: true), Self.page(0..<0, partial: true)])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        await store.task?.value
        XCTAssertFalse(store.isComplete)
        store.rowAppeared(8)
        await store.task?.value
        XCTAssertTrue(store.isCutAtLimit)
        XCTAssertEqual(
            FileHistoryText.beginning(store.entries, isComplete: store.isComplete, isCutAtLimit: store.isCutAtLimit),
            FileHistoryText.cutAtLimit)
        store.rowAppeared(8)
        XCTAssertEqual(loader.requests.count, 2, "no further request once cut")
    }

    /// A failed further page waits for Retry instead of running git again on every scroll; HEAD moving between pages
    /// does not list a commit twice.
    func testLoadMoreFailureAndDuplicates() async {
        let first = (0..<FileHistoryStore.pageSize).map { Self.entry($0) }
        let loader = StubFileHistoryLoader([
            .page(LogParser.FileHistoryPage(entries: first, isPartial: false)), .unavailable("git timed out"),
            .page(LogParser.FileHistoryPage(entries: [first[499], Self.entry(900)], isPartial: false)),
        ])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        await store.task?.value
        store.rowAppeared(FileHistoryStore.pageSize - 1)
        await store.task?.value
        XCTAssertEqual(store.loadMoreError, "git timed out")
        XCTAssertEqual(store.status, .loaded, "the rows stay")
        store.rowAppeared(FileHistoryStore.pageSize - 1)
        XCTAssertEqual(loader.requests.count, 2, "no automatic retry")
        store.retryLoadMore()
        await store.task?.value
        XCTAssertNil(store.loadMoreError)
        XCTAssertEqual(store.entries.count, FileHistoryStore.pageSize + 1)
        XCTAssertEqual(Set(store.entries.map(\.id)).count, store.entries.count)
    }

    func testFailuresAndCutPages() async {
        let failing = FileHistoryStore(
            loader: StubFileHistoryLoader([.unavailable("The worktree folder could not be found.")]))
        failing.open(Self.target())
        await failing.task?.value
        XCTAssertEqual(failing.status, .failed("The worktree folder could not be found."))

        // A cut page is not the end; a cut page that kept nothing cannot advance, so it ends the list.
        let cut = FileHistoryStore(loader: StubFileHistoryLoader([Self.page(0..<3, partial: true)]))
        cut.open(Self.target())
        await cut.task?.value
        XCTAssertFalse(cut.isComplete)
        let empty = FileHistoryStore(loader: StubFileHistoryLoader([Self.page(0..<0, partial: true)]))
        empty.open(Self.target())
        await empty.task?.value
        XCTAssertTrue(empty.isComplete)

        // A result for a history that was closed meanwhile is dropped.
        let loader = StubFileHistoryLoader([Self.page(0..<3)])
        let store = FileHistoryStore(loader: loader)
        store.open(Self.target())
        store.close()
        await store.task?.value
        XCTAssertFalse(store.isOpen)
        XCTAssertTrue(store.entries.isEmpty)
    }
}

/// S-09 rows and texts (#70).
final class FileHistoryModelTests: XCTestCase {
    func testRowsShowStatsRenameAndEscape() {
        let now = Date(timeIntervalSince1970: 1_793_853_652 + 7_200)
        var entry = FileHistoryStoreTests.entry(0, path: "Status.swift", from: "Parser\u{202E}.swift")
        let row = FileHistoryRow(entry, now: now)
        XCTAssertEqual(row.stat, "+1 −0")
        XCTAssertEqual(row.text.date, "2h")
        XCTAssertFalse(row.renamedFrom?.unicodeScalars.contains("\u{202E}") ?? true)
        XCTAssertTrue(row.accessibilityLabel.contains("renamed from"))
        entry.added = nil
        entry.deleted = nil
        XCTAssertEqual(FileHistoryRow(entry, now: now).stat, "binary")
        entry.hasStat = false
        XCTAssertEqual(FileHistoryRow(entry, now: now).stat, "")
    }

    /// #614: the words around the path never shorten, wherever the language puts them, and the path splits at its last
    /// `/` so only the directory gives way.
    func testTitlePartsKeepTheWordsAndTheFileName() {
        let path = GitPath("internal/http/middleware.go")
        XCTAssertEqual(
            FileHistoryText.titleParts(path),
            .init(prefix: "History of ", directory: "internal/http/", name: "middleware.go", suffix: ""))
        XCTAssertEqual(
            FileHistoryText.titleParts(path, format: "\(FileHistoryText.pathMarker)의 이력"),
            .init(prefix: "", directory: "internal/http/", name: "middleware.go", suffix: "의 이력"), "Korean")
        XCTAssertEqual(FileHistoryText.titleParts(GitPath("README.md")).directory, "")
        XCTAssertEqual(
            FileHistoryText.titleParts(GitPath("a/\u{2028}b.swift")).name, "\\u{2028}b.swift", "escaped like the title")
    }

    func testTitleAndBeginningOfHistory() {
        XCTAssertEqual(FileHistoryText.title(GitPath("a/\u{2028}b.swift")), "History of a/\\u{2028}b.swift")
        let entries = [FileHistoryStoreTests.entry(0), FileHistoryStoreTests.entry(1, path: "Parser.swift")]
        XCTAssertNil(FileHistoryText.beginning(entries, isComplete: false))
        XCTAssertEqual(
            FileHistoryText.beginning(entries, isComplete: true),
            "Beginning of history · created in \(entries[1].commit.oid.short) as Parser.swift")
    }
}
