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

    func testRefreshStartsANewStream() async throws {
        let service = try makeService()
        try await loadOverviewThenResetCalls(service)
        _ = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertEqual(logCalls(), 1)

        try await loadOverviewThenResetCalls(service)  // ⌘R drops cached pages and the stream
        _ = try await service.graphPage(model, skip: 0, limit: 10).get()
        XCTAssertEqual(logCalls(), 1, "a new stream after ⌘R")
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
