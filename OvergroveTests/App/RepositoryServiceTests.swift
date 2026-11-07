import Foundation
import XCTest

@testable import Overgrove

/// RepositoryService (#87, overview.md §3–§4): parallel per-worktree queries under the concurrency cap, refresh
/// generations, cancellation of superseded refreshes, and debounce.
///
/// Concurrency is observed, not timed: a gated git stand-in (`TestExecutables.gatedGit`) holds every `status` call until
/// the test releases it, and debounce sleeps go through a gate the test opens.
final class RepositoryServiceTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!
    private let safety = RepoSafetyContext(inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        for index in 0..<5 {
            let path = executables.directory.appendingPathComponent("wt-\(index)").path
            try await repository.git(["worktree", "add", "-q", "-b", "lane/\(index)", path])
        }
        try repository.write("a.txt", "changed\n")
    }

    override func tearDown() {
        if let markers {
            FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        }
        repository?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    /// A client whose git holds `status` calls until `release()`.
    private func gatedClient(maximumConcurrency: Int) throws -> GitClient {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        let environment = GitEnvironment(executable: gated, version: repository.environment.version)
        return GitClient(environment: environment, maximumConcurrency: maximumConcurrency)
    }

    private func release() {
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
    }

    private func startedStatusCalls() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []).filter { $0.hasPrefix("started-") }
            .count
    }

    private func invocations() -> [String] {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    /// Polls a condition the code under test produces. Throws after `timeout` instead of hanging.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(20), _ condition: () async -> Bool)
        async throws
    {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw NSError(
                    domain: "RepositoryServiceTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(what)"])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Overview

    func testOverviewQueriesEveryWorktree() async throws {
        let client = GitClient(environment: repository.environment)
        let overview = try await RepositoryService(client: client).loadOverview(of: model)

        XCTAssertEqual(overview.entries.count, 6, "main + 5 linked worktrees, in worktree-list order")
        XCTAssertTrue(overview.entries.first?.worktree.isMain ?? false)
        for entry in overview.entries {
            guard case .loaded(let state) = entry.status else { return XCTFail("\(entry.worktree.path.display)") }
            XCTAssertEqual(state.changedPathCount, entry.worktree.isMain ? 1 : 0, entry.worktree.path.display)
            // #168: each status records how long it took.
            XCTAssertNotNil(entry.statusDuration, entry.worktree.path.display)
        }
        XCTAssertEqual(
            overview.refs.branches.map(\.fullName).sorted(),
            (["refs/heads/main"] + (0..<5).map { "refs/heads/lane/\($0)" }).sorted())
        XCTAssertEqual(overview.stashes.stashes, [])
    }

    func testPrunableWorktreesAreNotQueriedAndOneFailureDoesNotFailTheRest() async throws {
        try FileManager.default.removeItem(at: executables.directory.appendingPathComponent("wt-0"))
        let client = GitClient(environment: repository.environment)
        let overview = try await RepositoryService(client: client).loadOverview(of: model)

        let pruned = try XCTUnwrap(overview.entries.first { $0.worktree.isPrunable })
        XCTAssertEqual(pruned.status, .notQueried(.prunable), "a missing worktree is listed, not queried (INT-14)")
        XCTAssertEqual(overview.entries.filter { if case .loaded = $0.status { true } else { false } }.count, 5)
    }

    func testSnapshotForTheShell() async throws {
        try FileManager.default.removeItem(at: executables.directory.appendingPathComponent("wt-1"))
        let client = GitClient(environment: repository.environment)
        let overview = try await RepositoryService(client: client).loadOverview(of: model)

        let snapshot = overview.snapshot(focusing: nil)
        XCTAssertEqual(snapshot.worktreeCount, 6)
        XCTAssertEqual(snapshot.prunableCount, 1)
        XCTAssertEqual(snapshot.focusedWorktree?.branch, "main", "the main worktree when nothing is focused")
        XCTAssertNotNil(snapshot.focusedWorktree?.headShortSHA)
        XCTAssertEqual(snapshot.focusedWorktree?.hasUpstream, false)

        let lane = try XCTUnwrap(overview.entries.first { $0.worktree.branch == "refs/heads/lane/2" })
        XCTAssertEqual(overview.snapshot(focusing: lane.worktree.path).focusedWorktree?.branch, "lane/2")
    }

    // MARK: - Untrusted worktree paths (security review of #221)

    /// A repository with a clean filter that writes a canary, and a tracked file whose stat changed, so `status` would
    /// run the filter (security-review.md E4).
    private func makeFilterRepository(_ canary: URL, name: String) async throws -> GitTestRepository {
        let other = try await GitTestRepository.make()
        try other.write("tracked.txt", "content\n")
        try await other.git(["add", "tracked.txt"])
        try await other.git(["commit", "-q", "-m", "one"])
        let filter = try executables.canaryProgram(named: name, canary: canary)
        try other.write(".gitattributes", "* filter=evil\n")
        try await other.git(["config", "filter.evil.clean", filter.path])
        try await Task.sleep(for: .seconds(1.1))  // a later mtime than the index: status must re-read the file
        try other.write("tracked.txt", "content\n")
        return other
    }

    private func canaries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    /// `worktree list` reads paths from `.git/worktrees/<id>/gitdir`, which the repository controls. A forged entry can
    /// point at another repository whose configuration was never inspected; its status must not run.
    func testForgedWorktreeEntryPointingAtAnotherRepositoryIsNotQueried() async throws {
        let canary = executables.directory.appendingPathComponent("canary-forged", isDirectory: true)
        let other = try await makeFilterRepository(canary, name: "foreign-filter")
        defer { other.remove() }
        let forged = repository.root.appendingPathComponent(".git/worktrees/forged", isDirectory: true)
        try FileManager.default.createDirectory(at: forged, withIntermediateDirectories: true)
        try (other.root.appendingPathComponent(".git").path + "\n").write(
            to: forged.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: forged.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: forged.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        // Control: status in that directory with this repository's safety context runs the other repository's filter.
        _ = try? await GitClient(environment: repository.environment).run(.status, in: other.root, safety: safety)
        XCTAssertEqual(canaries(canary), ["foreign-filter"], "control: the filter must be reachable")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("foreign-filter"))

        let overview = try await RepositoryService(client: GitClient(environment: repository.environment))
            .loadOverview(of: model)
        let entry = try XCTUnwrap(
            overview.entries.first {
                URL(fileURLWithPath: $0.worktree.path.display).resolvingSymlinksInPath().path
                    == other.root.resolvingSymlinksInPath().path
            })
        XCTAssertEqual(entry.status, .notQueried(.foreignRepository))
        XCTAssertEqual(canaries(canary), [], "nothing from the other repository may run")
    }

    /// With `extensions.worktreeConfig`, a linked worktree has its own `config.worktree`, which the main worktree's
    /// inspection does not see. Each worktree is inspected before its status runs.
    func testLinkedWorktreeOwnConfigurationIsInspected() async throws {
        let canary = executables.directory.appendingPathComponent("canary-worktree", isDirectory: true)
        let filter = try executables.canaryProgram(named: "worktree-filter", canary: canary)
        let linked = executables.directory.appendingPathComponent("wt-3")
        try await repository.git(["config", "extensions.worktreeConfig", "true"])
        try await repository.git(["-C", linked.path, "config", "--worktree", "filter.wt.clean", filter.path])
        try "* filter=wt\n".write(
            to: linked.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(1.1))
        try "a\n".write(to: linked.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // Control: the main worktree's safety context does not neutralize the linked worktree's own driver.
        let listing = try await GitClient(environment: repository.environment)
            .run(.configList, in: repository.root, safety: .preInspection)
        let mainSafety = try XCTUnwrap(
            RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        _ = try? await GitClient(environment: repository.environment).run(.status, in: linked, safety: mainSafety)
        XCTAssertEqual(canaries(canary), ["worktree-filter"], "control: the driver must be reachable")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("worktree-filter"))

        let overview = try await RepositoryService(client: GitClient(environment: repository.environment))
            .loadOverview(of: model)
        let entry = try XCTUnwrap(overview.entries.first { $0.worktree.branch == "refs/heads/lane/3" })
        guard case .loaded = entry.status else { return XCTFail("\(entry.status)") }
        XCTAssertEqual(canaries(canary), [], "the linked worktree's driver is neutralized")
    }

    // MARK: - Concurrency cap

    func testStatusQueriesNeverExceedTheConcurrencyCap() async throws {
        let client = try gatedClient(maximumConcurrency: 3)
        let service = RepositoryService(client: client)
        let target = model
        let load = Task { try await service.loadOverview(of: target) }

        try await waitUntil("three status calls to start") { self.startedStatusCalls() == 3 }
        // A fourth would have to start while the first three are held. A missing marker can only make this pass early.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(startedStatusCalls(), 3, "the cap holds the other status calls back")

        release()
        let overview = try await load.value
        XCTAssertEqual(overview.entries.count, 6)
        XCTAssertEqual(startedStatusCalls(), 6, "every worktree was queried once")
        let peak = await client.peakConcurrency
        XCTAssertEqual(peak, 3)
    }

    func testDefaultCapIsCoresUpToEight() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        XCTAssertEqual(GitClient.defaultConcurrency, max(2, min(cores, 8)))
    }

    // MARK: - Refresh: generations and cancellation

    func testUserRefreshSupersedesARunningRefresh() async throws {
        let client = try gatedClient(maximumConcurrency: 8)
        let service = RepositoryService(client: client)
        let target = model

        let first = Task { await service.refresh(target, trigger: .user) }
        try await waitUntil("the first refresh to reach status") { self.startedStatusCalls() > 0 }

        let second = Task { await service.refresh(target, trigger: .user) }
        let superseded = await first.value
        XCTAssertNil(superseded, "a superseded refresh delivers nothing, and its git processes are stopped")

        release()
        let delivered = await second.value
        let latest = try XCTUnwrap(delivered)
        XCTAssertEqual(latest.generation, 2)
        guard case .success(let overview) = latest.result else { return XCTFail("\(latest.result)") }
        XCTAssertEqual(overview.entries.count, 6)
    }

    func testCancellingTheCallerStopsItsRefresh() async throws {
        let client = try gatedClient(maximumConcurrency: 8)
        let service = RepositoryService(client: client)
        let target = model

        let refresh = Task { await service.refresh(target, trigger: .user) }
        try await waitUntil("the refresh to reach status") { self.startedStatusCalls() > 0 }
        refresh.cancel()
        let result = await refresh.value
        XCTAssertNil(result, "a cancelled refresh delivers nothing")

        // The service is not left busy: the next refresh runs normally.
        release()
        let next = await service.refresh(target, trigger: .user)
        XCTAssertEqual(next?.generation, 2)
    }

    func testGenerationsAreIndependentPerRepository() async throws {
        let other = try await GitTestRepository.make()
        defer { other.remove() }
        try other.write("b.txt", "b\n")
        try await other.git(["add", "b.txt"])
        try await other.git(["commit", "-q", "-m", "b"])
        let otherModel = Repository(
            rootURL: other.root, commonGitDirectoryURL: other.root.appendingPathComponent(".git"), isBare: false)
        let service = RepositoryService(client: GitClient(environment: repository.environment))

        let first = await service.refresh(model, trigger: .user)
        let unrelated = await service.refresh(otherModel, trigger: .user)
        let second = await service.refresh(model, trigger: .user)
        XCTAssertEqual(first?.generation, 1)
        XCTAssertEqual(unrelated?.generation, 1, "another repository does not supersede this one")
        XCTAssertEqual(second?.generation, 2)
    }

    // MARK: - Debounce

    /// Records debounce sleeps and resumes them only when the test says so.
    private actor DebounceGate {
        private var sleepers: [CheckedContinuation<Void, Error>] = []
        private(set) var requested: [Duration] = []

        var waiting: Int { sleepers.count }

        func sleep(_ duration: Duration) async throws {
            requested.append(duration)
            try await withCheckedThrowingContinuation { sleepers.append($0) }
        }

        func releaseAll() {
            for sleeper in sleepers { sleeper.resume() }
            sleepers.removeAll()
        }
    }

    func testRapidAutomaticRefreshesRunOnce() async throws {
        let gate = DebounceGate()
        let client = try gatedClient(maximumConcurrency: 8)
        release()  // status calls pass straight through here
        let service = RepositoryService(client: client, sleep: { try await gate.sleep($0) })
        let target = model

        let requests = (0..<3).map { _ in
            Task { await service.refresh(target, trigger: .automatic) }
        }
        try await waitUntil("three debounced requests") { await gate.waiting == 3 }
        let sleeps = await gate.requested
        XCTAssertEqual(sleeps, Array(repeating: RepositoryService.debounceInterval, count: 3))
        XCTAssertEqual(invocations(), [], "nothing runs while requests keep arriving")

        await gate.releaseAll()
        var results: [RepositoryService.Refresh?] = []
        for request in requests { results.append(await request.value) }
        XCTAssertEqual(results.compactMap { $0 }.map(\.generation), [3], "only the last request runs")
        XCTAssertEqual(invocations().filter { $0 == "worktree" }.count, 1, "one worktree list for three requests")
    }

    func testUserRefreshSkipsTheDebounceAndSupersedesWaitingOnes() async throws {
        let gate = DebounceGate()
        let service = RepositoryService(
            client: GitClient(environment: repository.environment), sleep: { try await gate.sleep($0) })
        let target = model

        let automatic = Task { await service.refresh(target, trigger: .automatic) }
        try await waitUntil("the automatic request to wait") { await gate.waiting == 1 }

        let user = await service.refresh(target, trigger: .user)
        XCTAssertEqual(user?.generation, 2, "⌘R runs immediately (interaction.md: not debounced)")
        let waitingCount = await gate.waiting
        XCTAssertEqual(waitingCount, 1, "the user refresh did not sleep")

        await gate.releaseAll()
        let stale = await automatic.value
        XCTAssertNil(stale, "the older automatic request is superseded")
    }
}
