import Foundation
import XCTest

@testable import Overgrove

/// `GitClient.fetch` (#76, git-command-catalog.md §4): per remote, progress, cancellation, timeout, one fetch per
/// repository, and fetch slots separate from query slots.
///
/// Nothing touches the network. Remotes are local bare repositories, either by path or as `ssh://<host>/x` served by
/// a fake trusted `core.sshCommand` that runs the real `git upload-pack` (see `TestExecutables.fakeSSHServer`).
/// A gated server holds the connection open until the test writes `<host>.release`, so "fetch in progress" is a
/// state the test controls instead of a race.
final class GitFetchTests: XCTestCase {
    private var executables: TestExecutables!
    private var source: GitTestRepository!
    private var local: GitTestRepository!
    private var remotes: URL!
    private var markers: URL!
    private var extraRepositories: [GitTestRepository] = []

    override func setUp() async throws {
        executables = try TestExecutables()
        remotes = executables.directory.appendingPathComponent("remotes", isDirectory: true)
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
        source = try await GitTestRepository.make()
        for index in 0..<40 {
            try source.write("file-\(index).txt", String(repeating: "line \(index)\n", count: 200))
        }
        try await source.git(["add", "-A"])
        try await source.git(["commit", "-q", "-m", "fixture"])
        local = try await GitTestRepository.make()
    }

    override func tearDown() {
        // Release any gate a failed test left closed, so no fake server outlives the test.
        if let markers {
            try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
            for host in ["alpha", "beta", "r0", "r1", "r2"] {
                FileManager.default.createFile(
                    atPath: markers.appendingPathComponent("\(host).release").path, contents: nil)
            }
        }
        for repository in extraRepositories { repository.remove() }
        local?.remove()
        source?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    private var origin: RemoteName { RemoteName("origin")! }

    /// `<remotes>/<host>.git` with `main` from the source repository.
    @discardableResult
    private func makeBareRemote(_ host: String) async throws -> URL {
        let bare = remotes.appendingPathComponent("\(host).git")
        try await source.git(["init", "-q", "--bare", bare.path])
        try await source.git(["push", "-q", bare.path, "HEAD:refs/heads/main"])
        return bare
    }

    private func repository(_ test: GitTestRepository) -> Repository {
        Repository(
            rootURL: test.root,
            commonGitDirectoryURL: test.root.appendingPathComponent(".git", isDirectory: true),
            isBare: false
        )
    }

    private func sshSafety(gated: Bool) throws -> RepoSafetyContext {
        let server = try executables.fakeSSHServer(
            git: local.environment.executable, remotes: remotes, markers: markers, gated: gated)
        return RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: server.path,
            fetchableRemotes: ["origin", "upstream"])
    }

    private func marker(_ host: String, _ state: String) -> URL {
        markers.appendingPathComponent("\(host).\(state)")
    }

    private func release(_ host: String) {
        FileManager.default.createFile(atPath: marker(host, "release").path, contents: nil)
    }

    /// Polls until `condition` holds; throws after `timeout`. Used for signals the code under test produces
    /// asynchronously (a marker the fake server writes once git connected, progress delivered on its own queue).
    private func waitUntil(
        _ what: String,
        timeout: Duration = .seconds(20),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(
                    domain: "GitFetchTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(what)"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitFor(_ url: URL) async throws {
        try await waitUntil(url.lastPathComponent) { FileManager.default.fileExists(atPath: url.path) }
    }

    private func remoteRefs(_ test: GitTestRepository) async throws -> [String] {
        let result = try await test.git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var isSet: Bool { lock.withLock { storage } }
        func set() { lock.withLock { storage = true } }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FetchProgress] = []
        var updates: [FetchProgress] { lock.withLock { storage } }
        func append(_ update: FetchProgress) { lock.withLock { storage.append(update) } }
    }

    // MARK: - Fetch

    func testFetchesALocalRemoteWithTheInspectedContextAndPrunes() async throws {
        let bare = try await makeBareRemote("plain")
        try await source.git(["push", "-q", bare.path, "HEAD:refs/heads/topic"])
        try await local.git(["remote", "add", "origin", bare.path])
        let client = GitClient(environment: local.environment)

        // The real flow: list the configuration, inspect it, then fetch with the resulting context.
        let listing = try await client.run(.configList, in: local.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        _ = try await client.fetch(.fetch(remote: origin), in: repository(local), safety: safety)
        let fetched = try await remoteRefs(local)
        XCTAssertTrue(fetched.contains("refs/remotes/origin/main"), "\(fetched)")
        XCTAssertTrue(fetched.contains("refs/remotes/origin/topic"), "\(fetched)")

        try await source.git(["push", "-q", bare.path, ":refs/heads/topic"])
        _ = try await client.fetch(.fetch(remote: origin), in: repository(local), safety: safety)
        let pruned = try await remoteRefs(local)
        XCTAssertFalse(pruned.contains("refs/remotes/origin/topic"), "--prune removes the deleted branch: \(pruned)")
    }

    func testProgressIsReportedWhileFetching() async throws {
        try await makeBareRemote("alpha")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        let log = ProgressLog()
        let client = GitClient(environment: local.environment)
        let output = try await client.fetch(
            .fetch(remote: origin), in: repository(local), safety: try sshSafety(gated: false),
            progress: { log.append($0) })

        // Which phases appear depends on pack size and speed (a small pack may skip "Receiving objects"), so check
        // what every fetch reports: the remote counts objects, and phases only move forward. Updates are delivered on
        // their own queue and may land just after fetch returns.
        try await waitUntil("counting to finish: \(output.stderr.text)") {
            log.updates.contains { $0.phase == .counting && $0.isDone }
        }
        let updates = log.updates
        let counted = updates.last { $0.phase == .counting }
        XCTAssertEqual(counted?.isDone, true, "\(updates)")
        XCTAssertEqual(counted?.completed, counted?.total)
        XCTAssertGreaterThan(counted?.total ?? 0, 0)
        XCTAssertEqual(updates.map(\.phase), updates.map(\.phase).sorted(), "phases arrive in git's order")
        let refs = try await remoteRefs(local)
        XCTAssertTrue(refs.contains("refs/remotes/origin/main"), "\(refs)")
    }

    // MARK: - Timeout and cancellation

    func testTimeoutStopsAStalledFetch() async throws {
        try await makeBareRemote("alpha")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        var limits = ProcessLimits.fetch
        limits.timeout = .seconds(1)
        let client = GitClient(environment: local.environment, fetchLimits: limits)
        let started = ContinuousClock.now
        do {
            _ = try await client.fetch(
                .fetch(remote: origin), in: repository(local), safety: try sshSafety(gated: true))
            XCTFail("a stalled fetch must time out")
        } catch let error as GitError {
            XCTAssertEqual(error, .timeout(seconds: 1))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "SIGTERM, then SIGKILL after the grace period")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker("alpha", "started").path))
    }

    func testCancellationStopsAFetchAndFreesTheRepository() async throws {
        try await makeBareRemote("alpha")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        let client = GitClient(environment: local.environment)
        let target = repository(local)
        let safety = try sshSafety(gated: true)
        let remote = origin
        let fetch = Task { try await client.fetch(.fetch(remote: remote), in: target, safety: safety) }
        try await waitFor(marker("alpha", "started"))

        fetch.cancel()
        do {
            _ = try await fetch.value
            XCTFail("a cancelled fetch must not succeed")
        } catch let error as GitError {
            XCTAssertEqual(error, .cancelled)
        }

        // The repository is not left locked: the next fetch runs and completes.
        try? FileManager.default.removeItem(at: marker("alpha", "started"))
        release("alpha")
        _ = try await client.fetch(.fetch(remote: origin), in: target, safety: safety)
        let refs = try await remoteRefs(local)
        XCTAssertTrue(refs.contains("refs/remotes/origin/main"), "\(refs)")
    }

    func testFetchesIntoABareRepository() async throws {
        let remote = try await makeBareRemote("plain")
        let bare = executables.directory.appendingPathComponent("mirror.git", isDirectory: true)
        try await source.git(["init", "-q", "--bare", bare.path])
        try await source.git(["-C", bare.path, "remote", "add", "origin", remote.path])
        let target = Repository(rootURL: nil, commonGitDirectoryURL: bare, isBare: true)
        let safety = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil, fetchableRemotes: ["origin"])

        _ = try await GitClient(environment: local.environment).fetch(
            .fetch(remote: origin), in: target, safety: safety)
        let refs = try await source.git(["-C", bare.path, "for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
        // git 2.48+ also creates refs/remotes/origin/HEAD, so check for the branch only.
        let names = String(decoding: refs.stdout, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(names.contains("refs/remotes/origin/main"), "runs in the git dir: \(names)")
    }

    // MARK: - Concurrency

    func testQueriesDoNotWaitForAFetch() async throws {
        try await makeBareRemote("alpha")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        // A single query slot: if fetch used it, the status below could not run until the fetch ended.
        let client = GitClient(environment: local.environment, maximumConcurrency: 1)
        let target = repository(local)
        let safety = try sshSafety(gated: true)
        let fetchEnded = Flag()
        let remote = origin
        let fetch = Task {
            defer { fetchEnded.set() }
            return try await client.fetch(.fetch(remote: remote), in: target, safety: safety)
        }
        try await waitFor(marker("alpha", "started"))

        _ = try await client.run(.status, in: local.root, safety: safety)
        _ = try await client.run(.status, in: local.root, safety: safety)
        XCTAssertFalse(fetchEnded.isSet, "the queries finished while the fetch was still held open")

        release("alpha")
        _ = try await fetch.value
        let peakQueries = await client.peakConcurrency
        XCTAssertEqual(peakQueries, 1)
    }

    func testOneFetchPerRepositoryAtATime() async throws {
        try await makeBareRemote("alpha")
        try await makeBareRemote("beta")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        try await local.git(["remote", "add", "upstream", "ssh://beta/x"])
        let client = GitClient(environment: local.environment)
        let target = repository(local)
        let safety = try sshSafety(gated: true)

        let remote = origin
        let first = Task { try await client.fetch(.fetch(remote: remote), in: target, safety: safety) }
        try await waitFor(marker("alpha", "started"))
        let second = Task {
            try await client.fetch(.fetch(remote: RemoteName("upstream")!), in: target, safety: safety)
        }
        // A missing file can only make this check pass too early, never fail spuriously.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker("beta", "started").path),
            "the second remote waits while the first fetch of the same repository runs"
        )

        release("alpha")
        _ = try await first.value
        try await waitFor(marker("beta", "started"))
        release("beta")
        _ = try await second.value
    }

    func testCancellingAQueuedFetchFreesItsPlace() async throws {
        // The cancel can race the hand-off in `release`; either way no slot or repository lock may leak.
        try await makeBareRemote("alpha")
        try await makeBareRemote("beta")
        try await local.git(["remote", "add", "origin", "ssh://alpha/x"])
        try await local.git(["remote", "add", "upstream", "ssh://beta/x"])
        let client = GitClient(environment: local.environment, maximumFetchConcurrency: 1)
        let target = repository(local)
        let safety = try sshSafety(gated: true)
        let remote = origin
        let upstream = RemoteName("upstream")!

        let running = Task { try await client.fetch(.fetch(remote: remote), in: target, safety: safety) }
        try await waitFor(marker("alpha", "started"))
        let queued = Task { try await client.fetch(.fetch(remote: upstream), in: target, safety: safety) }
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("a cancelled queued fetch must not run")
        } catch let error as GitError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker("beta", "started").path), "it never connected")

        let next = Task { try await client.fetch(.fetch(remote: upstream), in: target, safety: safety) }
        release("alpha")
        _ = try await running.value
        try await waitFor(marker("beta", "started"))
        release("beta")
        _ = try await next.value
    }

    func testFetchSlotsAreCappedAcrossRepositories() async throws {
        let client = GitClient(environment: local.environment, maximumFetchConcurrency: 2)
        let safety = try sshSafety(gated: true)
        var tasks: [Task<GitOutput, Error>] = []
        for index in 0..<3 {
            let host = "r\(index)"
            try await makeBareRemote(host)
            let repo = try await GitTestRepository.make()
            extraRepositories.append(repo)
            try await repo.git(["remote", "add", "origin", "ssh://\(host)/x"])
            let target = repository(repo)
            let remote = origin
            tasks.append(Task { try await client.fetch(.fetch(remote: remote), in: target, safety: safety) })
            if index < 2 { try await waitFor(marker(host, "started")) }
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker("r2", "started").path),
            "a third repository waits for a fetch slot"
        )

        release("r0")
        release("r1")
        try await waitFor(marker("r2", "started"))
        release("r2")
        for task in tasks { _ = try await task.value }
        let peak = await client.peakFetchConcurrency
        XCTAssertEqual(peak, 2)
    }
}
