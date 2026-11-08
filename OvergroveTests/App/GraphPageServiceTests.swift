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

    /// #308: the graph walks branches, remote-tracking refs, tags, and every worktree's HEAD, and nothing else. Notes,
    /// background prefetch (`git maintenance`), and `filter-branch` backups had commits in the graph with no ref pill,
    /// and moving them did not change the page cache key.
    /// Without a commit-graph file the page comes from the streamed graph (#254); review of #346.
    func testGraphWalksOnlyBranchesRemotesTagsAndWorktreeHeads() async throws {
        XCTAssertFalse(RepositoryService.hasCommitGraph(model), "the stream path")
        try await assertGraphWalksOnlyBranchesRemotesTagsAndWorktreeHeads(writingCommitGraph: false)
    }

    /// With a commit-graph file each page is its own `--skip` read.
    func testGraphWalksOnlyBranchesRemotesTagsAndWorktreeHeadsWithACommitGraph() async throws {
        try await assertGraphWalksOnlyBranchesRemotesTagsAndWorktreeHeads(writingCommitGraph: true)
    }

    private func assertGraphWalksOnlyBranchesRemotesTagsAndWorktreeHeads(writingCommitGraph: Bool) async throws {
        func commit(_ message: String) async throws -> String {
            func output(_ arguments: [String]) async throws -> String {
                String(decoding: try await repository.git(arguments).stdout, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return try await output([
                "commit-tree", "-p", "HEAD", "-m", message, try await output(["rev-parse", "HEAD^{tree}"]),
            ])
        }
        try await repository.git(["notes", "add", "-m", "a note", "HEAD"])
        try await repository.git(["update-ref", "refs/prefetch/remotes/origin/main", try await commit("prefetched")])
        try await repository.git([
            "update-ref", "refs/original/refs/heads/main", try await commit("filter-branch backup"),
        ])
        try await repository.git(["update-ref", "refs/pull/1/head", try await commit("pull request ref")])
        try await repository.git(["tag", "only-tag", try await commit("tag only")])
        try await repository.git(["update-ref", "refs/remotes/origin/feature", try await commit("remote only")])
        let linked = repository.root.deletingLastPathComponent()
            .appendingPathComponent("graph-308-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repository.git(["worktree", "add", "-q", "--detach", "--", linked.path, try await commit("detached")])

        if writingCommitGraph {
            try await repository.git(["commit-graph", "write", "--reachable"])
            XCTAssertTrue(RepositoryService.hasCommitGraph(model), "the --skip path")
        }
        let subjects = Set(try await page(try makeService(), skip: 0, limit: 100).commits.map(\.subject))
        for shown in ["c6", "c0", "tag only", "remote only", "detached"] {
            XCTAssertTrue(subjects.contains(shown), "\(shown) missing from \(subjects)")
        }
        for hidden in ["Notes added by 'git notes add'", "prefetched", "filter-branch backup", "pull request ref"] {
            XCTAssertFalse(subjects.contains(hidden), "\(hidden) in the graph")
        }
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

    /// #333: a ref the parser skips (here a non-UTF-8 branch name) is still walked by `log --branches` but is not in
    /// `GraphRefSet`. Moving only that ref must not serve the old page from the cache.
    func testMovingOnlyASkippedRefReadsThePageAgain() async throws {
        func output(_ arguments: [String]) async throws -> String {
            String(decoding: try await repository.git(arguments).stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func commit(_ message: String) async throws -> String {
            try await output([
                "commit-tree", "-p", "HEAD", "-m", message, try await output(["rev-parse", "HEAD^{tree}"]),
            ])
        }
        // `main` as the only packed ref: the appended line must not depend on another ref steering git's lookup (#372).
        try await repository.git(["branch", "-D", "side"])
        try await repository.git(["pack-refs", "--all"])
        let packed = repository.root.appendingPathComponent(".git/packed-refs")
        // The header promises `sorted`, so git binary-searches the file. The ref below is appended out of order, so the
        // promise is dropped and git reads the file line by line (#372).
        let header = try String(contentsOf: packed, encoding: .utf8)
        XCTAssertTrue(header.hasPrefix("# pack-refs with:"), header)
        let original = Data(header.replacingOccurrences(of: " sorted", with: "").utf8)
        // APFS names must be UTF-8, so the ref lives only in packed-refs.
        func pointSkippedRef(at oid: String) throws {
            try (original + Data("\(oid) refs/heads/bad-".utf8) + Data([0xFF]) + Data("\n".utf8)).write(to: packed)
        }
        try pointSkippedRef(at: try await commit("skipped one"))

        let service = try makeService()
        let first = try await page(service, skip: 0, limit: 100)
        XCTAssertGreaterThan(first.refs.skippedRecords, 0, "the non-UTF-8 name is skipped")
        XCTAssertTrue(first.commits.contains { $0.subject == "skipped one" }, "log still walks it")

        try pointSkippedRef(at: try await commit("skipped two"))
        _ = await service.refresh(model, trigger: .automatic)
        let moved = try await page(service, skip: 0, limit: 100)
        XCTAssertEqual(moved.refSet, first.refSet, "the key cannot see the skipped ref")
        XCTAssertTrue(moved.commits.contains { $0.subject == "skipped two" }, "the page was read again, not cached")
        XCTAssertFalse(moved.commits.contains { $0.subject == "skipped one" })
    }

    func testOnlyACompleteRefSetIsCacheable() {
        func refs(partial: Bool = false, skipped: Int = 0) -> RefParser.Listing {
            RefParser.Listing(branches: [], tags: [], isPartial: partial, skippedRecords: skipped)
        }
        XCTAssertTrue(GraphRefSet.isComplete(refs: refs(), isWorktreeListPartial: false))
        XCTAssertFalse(GraphRefSet.isComplete(refs: refs(skipped: 1), isWorktreeListPartial: false))
        XCTAssertFalse(GraphRefSet.isComplete(refs: refs(partial: true), isWorktreeListPartial: false))
        XCTAssertFalse(GraphRefSet.isComplete(refs: refs(), isWorktreeListPartial: true))
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
