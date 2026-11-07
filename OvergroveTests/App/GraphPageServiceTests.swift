import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryService.graphPage` (#68, ADR-0010 §3): `--skip`/`-n` pages line up, pages are cached by ref set, and
/// ⌘R or a moved ref set reads again.
final class GraphPageServiceTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        for index in 0..<7 {
            try repository.write("f.txt", "\(index)\n")
            try await repository.git(["add", "f.txt"])
            try await repository.git(["commit", "-q", "-m", "c\(index)"])
        }
        try await repository.git(["branch", "side", "HEAD~3"])
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

    private func makeService() throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        return RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version)))
    }

    private func logCalls() -> Int {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0 == "log" }.count
    }

    private func page(_ service: RepositoryService, skip: Int, limit: Int) async throws -> GraphPageSnapshot {
        try await service.graphPage(model, skip: skip, limit: limit).get()
    }

    func testPagesLineUpWithOneRead() async throws {
        let service = try makeService()
        let whole = try await page(service, skip: 0, limit: 100)
        var paged: [CommitNode] = []
        for skip in stride(from: 0, to: 9, by: 3) {
            paged += try await page(service, skip: skip, limit: 3).commits
        }

        XCTAssertEqual(whole.commits.map(\.subject), (0..<7).reversed().map { "c\($0)" })
        XCTAssertEqual(paged, whole.commits)
        XCTAssertEqual(
            GraphEngine.layout(paged).rows, GraphEngine.layout(whole.commits).rows, "same layout as one read")
        XCTAssertTrue(whole.refs.branches.contains { $0.fullName == "refs/heads/side" })
    }

    func testPagesAreCachedByRefSetUntilRefreshOrAMove() async throws {
        let service = try makeService()
        let first = try await page(service, skip: 0, limit: 3)
        let reads = logCalls()
        _ = try await page(service, skip: 0, limit: 3)
        XCTAssertEqual(logCalls(), reads, "the same page comes from the cache")

        _ = await service.refresh(model, trigger: .user)
        // Counted after the refresh: its `stash list` runs `git log` internally.
        let afterRefresh = logCalls()
        _ = try await page(service, skip: 0, limit: 3)
        XCTAssertEqual(logCalls(), afterRefresh + 1, "⌘R reads the graph again")

        try repository.write("g.txt", "g\n")
        try await repository.git(["add", "g.txt"])
        try await repository.git(["commit", "-q", "-m", "c7"])
        _ = await service.refresh(model, trigger: .automatic)
        let moved = try await page(service, skip: 0, limit: 3)
        XCTAssertNotEqual(moved.refSet, first.refSet)
        XCTAssertEqual(moved.commits.first?.subject, "c7")

        await service.forget(model)
        _ = await service.refresh(model, trigger: .user)
        let before = logCalls()
        _ = try await page(service, skip: 0, limit: 3)
        XCTAssertEqual(logCalls(), before + 1, "forget drops the pages")
    }

    func testRefSetCountsWorktreeHeads() {
        let oid = ObjectID(String(repeating: "a", count: 40))!
        let refs = RefParser.Listing(branches: [], tags: [], isPartial: false, skippedRecords: 0)
        let detached = Worktree(
            path: GitPath("/tmp/dev/wt"), head: oid, branch: nil, isMain: false, isDetached: true, isBare: false,
            lock: .unlocked, isPrunable: false, prunableReason: nil)
        XCTAssertNotEqual(GraphRefSet(refs: refs, worktrees: [detached]), GraphRefSet(refs: refs, worktrees: []))
    }
}
