import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryService.lineCounts` (#230, overview.md §5): queried only for a worktree with a loaded status, served
/// from memory until that worktree's status is queried again, dropped with the repository.
///
/// Queries are counted with the pass-through git stand-in (`TestExecutables.gatedGit`), as in
/// `RepositoryServiceCacheTests`.
final class RepositoryServiceLineCountTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "one\ntwo\n")
        try repository.write("b.txt", "b\n")
        try await repository.git(["add", "a.txt", "b.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try await repository.git(["worktree", "add", "-q", "-b", "lane", lane.path])
        // Main worktree: a.txt staged (+1 −1) and then changed again (+1); b.txt unstaged (−1, +2).
        try repository.write("a.txt", "one\nTWO\n")
        try await repository.git(["add", "a.txt"])
        try repository.write("a.txt", "one\nTWO\nthree\n")
        try repository.write("b.txt", "x\ny\n")
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    private var lane: URL { executables.directory.appendingPathComponent("wt-lane", isDirectory: true) }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func makeService() throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let client = GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version))
        return RepositoryService(client: client, sleep: { _ in })
    }

    private func calls() -> [String: Int] {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").reduce(into: [:]) { $0[String($1), default: 0] += 1 }
    }

    private func resetCalls() {
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("invocations.log"))
    }

    /// The main worktree's path as the worktree list reports it.
    private func mainPath(_ service: RepositoryService) async throws -> GitPath {
        let cached = await service.cachedOverview(of: model)
        let overview = try XCTUnwrap(cached)
        return try XCTUnwrap(overview.entries.first { $0.worktree.isMain }).worktree.path
    }

    func testNothingIsQueriedWithoutALoadedStatus() async throws {
        let service = try makeService()
        let counts = try await service.lineCounts(of: model, worktree: GitPath(repository.root.path))
        XCTAssertNil(counts)
        XCTAssertEqual(calls(), [:])
    }

    func testCountsAreQueriedOnceAndServedUntilTheStatusIsQueriedAgain() async throws {
        let service = try makeService()
        _ = await service.refresh(model, trigger: .user)
        let main = try await mainPath(service)
        resetCalls()

        let queriedcounts = try await service.lineCounts(of: model, worktree: main)
        let counts = try XCTUnwrap(queriedcounts)
        XCTAssertEqual(calls(), ["rev-parse": 1, "diff": 2], "probe, then staged and unstaged; inspection cached")
        XCTAssertEqual(counts.staged[GitPath("a.txt")], FileStat(path: GitPath("a.txt"), added: 1, deleted: 1))
        XCTAssertEqual(counts.unstaged[GitPath("a.txt")], FileStat(path: GitPath("a.txt"), added: 1, deleted: 0))
        XCTAssertEqual(counts.unstaged[GitPath("b.txt")], FileStat(path: GitPath("b.txt"), added: 2, deleted: 1))
        XCTAssertNil(counts.staged[GitPath("b.txt")])
        XCTAssertFalse(counts.isPartial)

        resetCalls()
        let again = try await service.lineCounts(of: model, worktree: main)
        XCTAssertEqual(again, counts)
        XCTAssertEqual(calls(), [:], "same status: served from memory")

        // Selecting the worktree re-queries its status, which invalidates its counts (same rule as status).
        try repository.write("b.txt", "x\ny\nz\n")
        _ = await service.refresh(model, trigger: .worktreeSelected(main))
        resetCalls()
        let queriedfresh = try await service.lineCounts(of: model, worktree: main)
        let fresh = try XCTUnwrap(queriedfresh)
        XCTAssertEqual(calls()["diff"], 2)
        XCTAssertEqual(fresh.unstaged[GitPath("b.txt")]?.added, 3)
    }

    func testAnotherWorktreesStatusDoesNotInvalidate() async throws {
        let service = try makeService()
        _ = await service.refresh(model, trigger: .user)
        let main = try await mainPath(service)
        let cached = await service.cachedOverview(of: model)
        let overview = try XCTUnwrap(cached)
        let lanePath = try XCTUnwrap(overview.entries.first { !$0.worktree.isMain }).worktree.path
        _ = try await service.lineCounts(of: model, worktree: main)

        _ = await service.refresh(model, trigger: .worktreeSelected(lanePath))
        resetCalls()
        _ = try await service.lineCounts(of: model, worktree: main)
        XCTAssertEqual(calls(), [:])
    }

    func testForgetDropsTheCounts() async throws {
        let service = try makeService()
        _ = await service.refresh(model, trigger: .user)
        let main = try await mainPath(service)
        _ = try await service.lineCounts(of: model, worktree: main)

        await service.forget(model)
        resetCalls()
        let counts = try await service.lineCounts(of: model, worktree: main)
        XCTAssertNil(counts, "no cached status after forget")
        XCTAssertEqual(calls(), [:])
    }

    /// The same belonging check as status (#226): a worktree whose `.git` stops leading here is not queried.
    func testWorktreeThatStopsBelongingIsNotQueried() async throws {
        let service = try makeService()
        _ = await service.refresh(model, trigger: .user)
        let cached = await service.cachedOverview(of: model)
        let overview = try XCTUnwrap(cached)
        let lanePath = try XCTUnwrap(overview.entries.first { !$0.worktree.isMain }).worktree.path
        try "gitdir: /nonexistent/elsewhere\n".write(
            to: lane.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        resetCalls()

        let counts = try await service.lineCounts(of: model, worktree: lanePath)
        XCTAssertNil(counts)
        XCTAssertNil(calls()["diff"], "no numstat in a folder that does not belong")
    }
}
