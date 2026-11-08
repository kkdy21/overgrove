import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryService.graphPage` with real git (#254): without a commit-graph file the pages come from one streamed
/// `log`, identical to `--skip` pages; with one, each page is its own `--skip` read as before.
final class GraphStreamServiceTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!
    private static let commitCount = 35

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        for index in 0..<Self.commitCount {
            try await repository.git([
                "-c", "core.commitGraph=false", "commit", "-q", "--allow-empty", "-m", "commit \(index)",
                "--date=\(1_700_000_000 + index * 60) +0000",
            ])
        }
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    /// A service whose git logs every subcommand (released at once).
    private func makeService() throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        return RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version)))
    }

    /// Loads the overview (its stash list is also a `log`) and clears the invocation log, so `logCalls` counts only
    /// graph reads.
    private func loadOverviewThenResetCalls(_ service: RepositoryService) async throws {
        let refresh = await service.refresh(model, trigger: .user)
        XCTAssertNotNil(refresh)
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("invocations.log"))
    }

    private func logCalls() -> Int {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0 == "log" }.count
    }

    private func pages(_ service: RepositoryService, size: Int = 10) async throws -> [[ObjectID]] {
        var pages: [[ObjectID]] = []
        var skip = 0
        while true {
            let page = try await service.graphPage(model, skip: skip, limit: size).get()
            pages.append(page.commits.map(\.oid))
            if page.commits.count < size { return pages }
            skip += size
        }
    }

    /// The whole history in one `--skip`-free read, the reference the pages must match.
    private func wholeHistory() async throws -> [ObjectID] {
        let client = GitClient(environment: repository.environment)
        let config = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout)).safetyContext)
        let output = try await client.run(.graphPage(skip: 0, limit: 1_000), in: repository.root, safety: safety)
        return try LogParser.parseGraph(output.stdout).commits.map(\.oid)
    }

    func testWithoutACommitGraphEveryPageComesFromOneStream() async throws {
        XCTAssertFalse(RepositoryService.hasCommitGraph(model), "the test repository has no commit-graph file")
        let service = try makeService()
        try await loadOverviewThenResetCalls(service)

        let pages = try await pages(service)

        XCTAssertEqual(pages.map(\.count), [10, 10, 10, 5])
        let whole = try await wholeHistory()
        XCTAssertEqual(pages.flatMap { $0 }, whole, "same commits, same order as --skip pages")
        XCTAssertEqual(logCalls(), 1, "one log process for every page")
    }

    func testWithACommitGraphEachPageIsItsOwnRead() async throws {
        try await repository.git(["commit-graph", "write", "--reachable"])
        XCTAssertTrue(RepositoryService.hasCommitGraph(model))
        let service = try makeService()
        try await loadOverviewThenResetCalls(service)

        let pages = try await pages(service)

        let whole = try await wholeHistory()
        XCTAssertEqual(pages.flatMap { $0 }, whole)
        XCTAssertEqual(logCalls(), pages.count, "--skip pages, as before #254")
    }

    /// #373: a stream started after the refs moved, before the overview was refreshed, reads the new refs. Its pages
    /// come back with the new ref set, never labelled with the old one.
    func testAStreamStartedAfterTheRefsMovedCarriesTheNewRefSet() async throws {
        let service = try makeService()
        let refreshed = await service.refresh(model, trigger: .user)
        let refresh = try XCTUnwrap(refreshed)
        let overview = try refresh.result.get()
        let stale = GraphRefSet(refs: overview.refs, worktrees: overview.entries.map(\.worktree))

        try await repository.git(["commit", "-q", "--allow-empty", "-m", "moved"])  // no refresh
        let page = try await service.graphPage(model, skip: 0, limit: 10).get()

        XCTAssertNotEqual(page.refSet, stale, "not labelled with the refs the overview had")
        XCTAssertEqual(page.commits.first?.subject, "moved")
        let head = String(decoding: try await repository.git(["rev-parse", "HEAD"]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(page.refs.branches.first { $0.fullName == "refs/heads/main" }?.target.hex, head)
        let next = try await service.graphPage(model, skip: 10, limit: 10).get()
        XCTAssertEqual(next.refSet, page.refSet, "later pages continue under the new ref set")
    }

    func testRefreshStartsANewStream() async throws {
        let service = try makeService()
        try await loadOverviewThenResetCalls(service)
        _ = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertEqual(logCalls(), 1)

        try await loadOverviewThenResetCalls(service)  // ⌘R drops cached pages and the stream
        _ = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertEqual(logCalls(), 1, "a new stream after ⌘R")
    }

    /// Review of #346 (#333): a ref the parser skips (a non-UTF-8 branch name) is walked by `log` but is not in
    /// `GraphRefSet`, so a stream kept for that ref set cannot see it move. Such a ref set never uses the stream:
    /// after an automatic refresh that moved only the skipped ref, the page shows the new commit, not the old one.
    func testMovingOnlyASkippedRefServesNoStaleStreamPage() async throws {
        func output(_ arguments: [String]) async throws -> String {
            String(decoding: try await repository.git(arguments).stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ message: String) async throws -> String {
            try await output([
                "commit-tree", "-p", "HEAD", "-m", message, try await output(["rev-parse", "HEAD^{tree}"]),
            ])
        }
        try repository.write("f.txt", "content\n")  // a tree object for commit-tree (the setUp commits are empty)
        try await repository.git(["add", "f.txt"])
        try await repository.git(["commit", "-q", "-m", "with a tree"])
        try await repository.git(["pack-refs", "--all"])
        let packed = repository.root.appendingPathComponent(".git/packed-refs")
        // The appended line breaks the file's order, so drop the `sorted` trait: otherwise git's binary search can no
        // longer find `refs/heads/main`.
        let original = Data(
            String(decoding: try Data(contentsOf: packed), as: UTF8.self)
                .replacingOccurrences(of: " sorted", with: "").utf8)
        // APFS names must be UTF-8, so the ref lives only in packed-refs.
        func pointSkippedRef(at oid: String) throws {
            try (original + Data("\(oid) refs/heads/bad-".utf8) + Data([0xFF]) + Data("\n".utf8)).write(to: packed)
        }
        try pointSkippedRef(at: try await commit("skipped one"))
        XCTAssertFalse(RepositoryService.hasCommitGraph(model), "the stream path would apply")
        let service = try makeService()
        try await loadOverviewThenResetCalls(service)

        let first = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertGreaterThan(first.refs.skippedRecords, 0, "the non-UTF-8 name is skipped")
        XCTAssertTrue(first.commits.contains { $0.subject == "skipped one" }, "log still walks it")

        try pointSkippedRef(at: try await commit("skipped two"))
        _ = await service.refresh(model, trigger: .automatic)
        let moved = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertEqual(moved.refSet, first.refSet, "the key cannot see the skipped ref")
        XCTAssertTrue(moved.commits.contains { $0.subject == "skipped two" }, "read again, not from the old stream")
        XCTAssertFalse(moved.commits.contains { $0.subject == "skipped one" })
    }

    /// Review of #254: streams share one slot, so a stream for another repository stops this one's unfinished stream
    /// instead of waiting behind it (up to its 120 s timeout). Its waiting page falls back to `--skip`.
    func testAnotherRepositorysStreamDoesNotWaitBehindAnUnfinishedOne() async throws {
        let other = try await GitTestRepository.make()
        defer { other.remove() }
        for index in 0..<12 {
            try await other.git(["commit", "-q", "--allow-empty", "-m", "other \(index)"])
        }
        let otherModel = Repository(
            rootURL: other.root, commonGitDirectoryURL: other.root.appendingPathComponent(".git"), isBare: false)
        let release = markers.appendingPathComponent("release-stream")
        let held = try executables.gitHoldingStream(
            forwardingTo: repository.environment.executable, in: repository.root, release: release, markers: markers)
        defer { FileManager.default.createFile(atPath: release.path, contents: nil) }
        let service = RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: held, version: repository.environment.version)))
        let first = await service.refresh(model, trigger: .user)
        XCTAssertNotNil(first)
        let second = await service.refresh(otherModel, trigger: .user)
        XCTAssertNotNil(second)

        let repository = model
        let waiting = Task { try await service.graphPage(repository, skip: 0, limit: 10).get() }
        let isHeld = await eventually(timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: self.markers.appendingPathComponent("stream-held").path)
        }
        XCTAssertTrue(isHeld, "this repository's stream is running and holds the stream slot")

        let started = ContinuousClock.now
        let otherPage = try await service.graphPage(otherModel, skip: 0, limit: 10).get()
        XCTAssertEqual(otherPage.commits.count, 10)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "not stuck behind the other stream")

        let page = try await waiting.value
        XCTAssertEqual(page.commits.count, 10, "the stopped stream's page came from --skip")
    }
}
