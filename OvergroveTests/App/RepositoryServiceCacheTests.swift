import Foundation
import XCTest

@testable import Overgrove

/// RepositoryService result cache (#88, overview.md §5): what each trigger re-queries, derived invalidation from fresh
/// statuses, configuration inspections that are never served stale, and memory bounds.
///
/// Queries are counted, not timed: a pass-through git stand-in (`TestExecutables.gatedGit`) logs every subcommand.
final class RepositoryServiceCacheTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!
    private let clock = ManualClock()

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        for index in 0..<3 {
            try await repository.git(["worktree", "add", "-q", "-b", "lane/\(index)", worktree(index).path])
        }
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    /// A monotonic clock the test moves by hand (status freshness, overview.md §5).
    private final class ManualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = ContinuousClock.now

        func now() -> ContinuousClock.Instant { lock.withLock { current } }
        func advance(by duration: Duration) { lock.withLock { current += duration } }
    }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func worktree(_ index: Int) -> URL {
        executables.directory.appendingPathComponent("wt-\(index)", isDirectory: true)
    }

    private func makeService(cachedRepositories: Int = RepositoryService.defaultCachedRepositories) throws
        -> RepositoryService
    {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let client = GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version))
        let clock = clock
        return RepositoryService(
            client: client, cachedRepositories: cachedRepositories, sleep: { _ in }, now: { clock.now() })
    }

    /// Subcommands run since the last `resetCalls()`, counted.
    private func calls() -> [String: Int] {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").reduce(into: [:]) { $0[String($1), default: 0] += 1 }
    }

    private func resetCalls() {
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("invocations.log"))
    }

    private func overview(_ refresh: RepositoryService.Refresh?, file: StaticString = #filePath, line: UInt = #line)
        throws -> RepositoryOverview
    {
        let refresh = try XCTUnwrap(refresh, "superseded", file: file, line: line)
        switch refresh.result {
        case .success(let overview): return overview
        case .failure(let error): throw error
        }
    }

    private func entry(_ overview: RepositoryOverview, lane index: Int) throws -> RepositoryOverview.Entry {
        try XCTUnwrap(overview.entries.first { $0.worktree.branch == "refs/heads/lane/\(index)" })
    }

    private func state(_ entry: RepositoryOverview.Entry) throws -> WorkingState {
        guard case .loaded(let state) = entry.status else { throw GitError.parseFailed(parser: "test", offset: 0) }
        return state
    }

    // MARK: - Cached overview

    func testCachedOverviewIsEmptyUntilALoadAndThenServedWithoutGit() async throws {
        let service = try makeService()
        let empty = await service.cachedOverview(of: model)
        XCTAssertNil(empty)

        let loaded = try overview(await service.refresh(model, trigger: .user))
        resetCalls()
        let cached = await service.cachedOverview(of: model)

        XCTAssertEqual(cached, loaded)
        XCTAssertEqual(calls(), [:], "a cached overview runs no git")
        XCTAssertFalse(loaded.isWorktreeListPartial)
        XCTAssertFalse(loaded.inspection.report.isBlocked)
    }

    // MARK: - What each trigger re-queries

    func testWorktreeSelectionQueriesOnlyThatWorktreeAndReusesItsInspection() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        let lane1 = try entry(first, lane: 1).worktree.path
        try "changed\n".write(to: worktree(1).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        resetCalls()

        let selected = try overview(await service.refresh(model, trigger: .worktreeSelected(lane1)))

        XCTAssertEqual(
            calls(), ["rev-parse": 1, "status": 1], "probe and status of that worktree; no config, list, refs")
        XCTAssertEqual(try state(try entry(selected, lane: 1)).changedPathCount, 1)
        XCTAssertEqual(try entry(selected, lane: 0), try entry(first, lane: 0), "other worktrees come from the cache")
        XCTAssertEqual(selected.refs, first.refs)
    }

    func testWindowActivationRequeriesOnlyStatusesAtLeastFiveSecondsOld() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        clock.advance(by: .seconds(3))
        _ = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 1).worktree.path)))
        clock.advance(by: .seconds(3))
        resetCalls()

        _ = try overview(await service.refresh(model, trigger: .automatic))

        let counted = calls()
        XCTAssertEqual(counted["worktree"], 1, "window activation re-reads the worktree list")
        XCTAssertEqual(counted["status"], 3, "main, lane/0 and lane/2 are 6 s old; lane/1 is 3 s old")
        XCTAssertNil(counted["for-each-ref"])
        XCTAssertNil(counted["stash"])
        XCTAssertNil(counted["config"], "no configuration file changed")
    }

    func testFetchCompletionRequeriesListStatusesAndRefs() async throws {
        let service = try makeService()
        _ = try overview(await service.refresh(model, trigger: .user))
        resetCalls()

        _ = try overview(await service.refresh(model, trigger: .fetchCompleted))

        let counted = calls()
        XCTAssertEqual(counted["worktree"], 1)
        XCTAssertEqual(counted["status"], 4, "ahead/behind of every worktree may have moved")
        XCTAssertEqual(counted["for-each-ref"], 1)
        XCTAssertNil(counted["stash"], "the stash count did not change")
    }

    func testUserRefreshRequeriesEverythingIncludingInspections() async throws {
        let service = try makeService()
        _ = try overview(await service.refresh(model, trigger: .user))
        let cold = calls()
        resetCalls()

        _ = try overview(await service.refresh(model, trigger: .user))

        XCTAssertEqual(calls(), cold, "⌘R runs the same queries as the first load")
        XCTAssertGreaterThan(cold["config", default: 0], 0)
    }

    // MARK: - Derived invalidation

    func testStashListIsRequeriedWhenTheStashCountChanges() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        try "stash me\n".write(to: worktree(0).appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", worktree(0).path, "stash", "push", "-q"])
        resetCalls()

        let selected = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 0).worktree.path)))

        XCTAssertEqual(calls()["stash"], 1, "# stash 1 differs from the cached list (overview.md §5)")
        XCTAssertEqual(selected.stashes.stashes.count, 1)
    }

    func testRefsAreRequeriedWhenABranchTipMoves() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        try "next\n".write(to: worktree(2).appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", worktree(2).path, "add", "b.txt"])
        try await repository.git(["-C", worktree(2).path, "commit", "-q", "-m", "two"])
        resetCalls()

        let selected = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 2).worktree.path)))

        XCTAssertEqual(calls()["for-each-ref"], 1, "lane/2's tip in status differs from the cached refs")
        let tip = try XCTUnwrap(selected.refs.branches.first { $0.fullName == "refs/heads/lane/2" })
        XCTAssertEqual(tip.target, try state(try entry(selected, lane: 2)).headCommit)
    }

    // MARK: - Inspections are never served stale (security)

    private func canaries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// Makes `status` in `folder` read `a.txt` again: a later modification time than the index.
    private func touchTrackedFile(in folder: URL) async throws {
        try await Task.sleep(for: .seconds(1.1))
        try "a\n".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    /// The inspection a stale cache would serve: taken before the configuration changed.
    private func currentSafety(in folder: URL) async throws -> RepoSafetyContext {
        let listing = try await GitClient(environment: repository.environment)
            .run(.configList, in: folder, safety: .preInspection)
        return try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
    }

    /// Runs `status` with a stale safety context and checks that the planted driver fires (the control).
    private func assertStaleSafetyRunsTheDriver(
        _ stale: RepoSafetyContext, in folder: URL, canary: URL, name: String
    ) async throws {
        _ = try? await GitClient(environment: repository.environment).run(.status, in: folder, safety: stale)
        XCTAssertEqual(canaries(canary), [name], "control: a stale inspection would let the driver run")
        try FileManager.default.removeItem(at: canary.appendingPathComponent(name))
    }

    func testChangedWorktreeConfigurationIsInspectedAgain() async throws {
        try await repository.git(["config", "extensions.worktreeConfig", "true"])
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        let stale = try await currentSafety(in: worktree(1))

        let canary = executables.directory.appendingPathComponent("canary-wt", isDirectory: true)
        let filter = try executables.canaryProgram(named: "wt-filter", canary: canary)
        try await repository.git(["-C", worktree(1).path, "config", "--worktree", "filter.wt.clean", filter.path])
        try "* filter=wt\n".write(
            to: worktree(1).appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try await touchTrackedFile(in: worktree(1))
        try await assertStaleSafetyRunsTheDriver(stale, in: worktree(1), canary: canary, name: "wt-filter")
        try await touchTrackedFile(in: worktree(1))
        resetCalls()

        let selected = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 1).worktree.path)))

        XCTAssertEqual(calls()["config"], 1, "config.worktree changed: that worktree is inspected again")
        _ = try state(try entry(selected, lane: 1))
        XCTAssertEqual(canaries(canary), [], "the new driver is neutralized")
    }

    func testChangedSharedConfigurationIsInspectedAgain() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        let stale = try await currentSafety(in: worktree(0))

        let canary = executables.directory.appendingPathComponent("canary-shared", isDirectory: true)
        let filter = try executables.canaryProgram(named: "shared-filter", canary: canary)
        try await repository.git(["config", "filter.shared.clean", filter.path])
        try "* filter=shared\n".write(
            to: worktree(0).appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try await touchTrackedFile(in: worktree(0))
        try await assertStaleSafetyRunsTheDriver(stale, in: worktree(0), canary: canary, name: "shared-filter")
        try await touchTrackedFile(in: worktree(0))
        resetCalls()

        let selected = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 0).worktree.path)))

        XCTAssertEqual(calls()["config"], 2, ".git/config changed: the repository and the worktree are inspected again")
        _ = try state(try entry(selected, lane: 0))
        XCTAssertEqual(canaries(canary), [], "the new driver is neutralized")
    }

    /// An included file is not stamped, so with a repository-controlled include every query inspects again.
    func testRepositoryLocalIncludeIsNeverServedFromTheCache() async throws {
        let included = repository.root.appendingPathComponent("extra.cfg")
        try "".write(to: included, atomically: true, encoding: .utf8)
        try await repository.git(["config", "include.path", included.path])
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        let stale = try await currentSafety(in: worktree(0))

        let canary = executables.directory.appendingPathComponent("canary-include", isDirectory: true)
        let filter = try executables.canaryProgram(named: "include-filter", canary: canary)
        try "[filter \"inc\"]\n\tclean = \(filter.path)\n".write(to: included, atomically: true, encoding: .utf8)
        try "* filter=inc\n".write(
            to: worktree(0).appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try await touchTrackedFile(in: worktree(0))
        try await assertStaleSafetyRunsTheDriver(stale, in: worktree(0), canary: canary, name: "include-filter")
        try await touchTrackedFile(in: worktree(0))
        resetCalls()

        let selected = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 0).worktree.path)))

        XCTAssertEqual(calls()["config"], 2, "no configuration file changed, yet both inspections ran again")
        _ = try state(try entry(selected, lane: 0))
        XCTAssertEqual(canaries(canary), [], "the included driver is neutralized")
    }

    func testFailedRefreshStopsServingTheOldResult() async throws {
        let service = try makeService()
        _ = try overview(await service.refresh(model, trigger: .user))
        try await repository.git(["config", "filter.a=b.clean", "x"])  // blocks queries (review of #150)

        let delivered = await service.refresh(model, trigger: .automatic)
        let refresh = try XCTUnwrap(delivered)

        guard case .failure(.configInspectionFailed) = refresh.result else { return XCTFail("\(refresh.result)") }
        let cached = await service.cachedOverview(of: model)
        XCTAssertNil(cached, "an overview from before the block is not served")
    }

    // MARK: - Worktrees that vanish

    func testVanishedWorktreeReportsWorktreeMissing() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        let lane2 = try entry(first, lane: 2).worktree.path
        try FileManager.default.removeItem(at: worktree(2))

        // The cached list still names it, so the selection queries a folder that is gone.
        let selected = try overview(await service.refresh(model, trigger: .worktreeSelected(lane2)))

        guard case .failed(.worktreeMissing) = try entry(selected, lane: 2).status else {
            return XCTFail("\(try entry(selected, lane: 2).status)")
        }
    }

    // MARK: - Memory bounds

    func testForgetDropsCachedResultsAndInspections() async throws {
        let service = try makeService()
        let first = try overview(await service.refresh(model, trigger: .user))
        await service.forget(model)
        let forgotten = await service.cachedOverview(of: model)
        XCTAssertNil(forgotten)
        resetCalls()

        _ = try overview(
            await service.refresh(model, trigger: .worktreeSelected(try entry(first, lane: 0).worktree.path)))

        let counted = calls()
        XCTAssertEqual(counted["worktree"], 1, "without a cache, a selection loads everything")
        XCTAssertEqual(counted["status"], 4)
        XCTAssertGreaterThan(counted["config", default: 0], 0, "inspections were dropped too")
    }

    func testCacheKeepsAtMostTheConfiguredNumberOfRepositories() async throws {
        let other = try await GitTestRepository.make()
        defer { other.remove() }
        try other.write("b.txt", "b\n")
        try await other.git(["add", "b.txt"])
        try await other.git(["commit", "-q", "-m", "b"])
        let otherModel = Repository(
            rootURL: other.root, commonGitDirectoryURL: other.root.appendingPathComponent(".git"), isBare: false)
        let service = try makeService(cachedRepositories: 1)

        _ = try overview(await service.refresh(model, trigger: .user))
        _ = try overview(await service.refresh(otherModel, trigger: .user))

        let evicted = await service.cachedOverview(of: model)
        let kept = await service.cachedOverview(of: otherModel)
        XCTAssertNil(evicted, "the least recently used repository is dropped")
        XCTAssertNotNil(kept)
    }
}
