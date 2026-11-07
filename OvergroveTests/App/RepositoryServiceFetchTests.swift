import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryService.fetch` (#77) with real git and local remotes (no network): every remote is tried, failures
/// become `FetchFailureGuidance`, and a configuration that blocks queries fetches nothing.
final class RepositoryServiceFetchTests: XCTestCase {
    private var repository: GitTestRepository!
    private var origin: URL!

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        origin = repository.root.deletingLastPathComponent()
            .appendingPathComponent("overgrove-origin-\(UUID().uuidString).git", isDirectory: true)
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try await repository.git(["init", "-q", "--bare", "-b", "main", origin.path])
    }

    override func tearDown() {
        repository?.remove()
        if let origin { try? FileManager.default.removeItem(at: origin) }
    }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func service() -> RepositoryService {
        RepositoryService(client: GitClient(environment: repository.environment))
    }

    private func hasRef(_ name: String) async throws -> Bool {
        let result = try await repository.git(["rev-parse", "--verify", "-q", name], allowFailure: true)
        return result.termination == .exited(code: 0)
    }

    /// Thread-safe list for the `onStart` callback.
    private final class Remotes: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var value: [String] { lock.withLock { names } }
        func set(_ new: [String]) { lock.withLock { names = new } }
    }

    func testEveryRemoteIsTriedAndFailuresAreGuided() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        try await repository.git(["push", "-q", "origin", "main"])
        try await repository.git(["update-ref", "-d", "refs/remotes/origin/main"])
        let missing = origin.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).git")
        try await repository.git(["remote", "add", "broken", missing.path])
        XCTAssertNil(FetchRecordStore.estimatedLastFetch(commonDirectory: model.commonGitDirectoryURL))

        let remotes = Remotes()
        let run = await service().fetch(model) { remotes.set($0) }

        XCTAssertEqual(remotes.value, ["origin", "broken"])
        guard case .finished(let failures, _) = run else { return XCTFail("\(run)") }
        XCTAssertEqual(failures.map(\.remote?.value), ["broken"], "origin succeeded; broken failed")
        let refetched = try await hasRef("refs/remotes/origin/main")
        XCTAssertTrue(refetched, "origin's remote-tracking ref was written again")
        XCTAssertNotNil(
            FetchRecordStore.estimatedLastFetch(commonDirectory: model.commonGitDirectoryURL),
            "git wrote FETCH_HEAD, which later stands in for the time when there is no record")
    }

    /// SEC-T15-10 (#259): a repository listing more remotes than one Fetch takes fetches only the first
    /// `maximumFetchedRemotes`, in configuration order, and says how many it skipped. Counted as git processes
    /// through the logging stand-in.
    func testSECT15_10_FetchTakesAtMostTheRemoteLimit() async throws {
        try await repository.git(["push", "-q", origin.path, "main"])
        for index in 0..<5 {
            try await repository.git(["remote", "add", "r\(index)", origin.path])
        }
        let executables = try TestExecutables()
        defer { executables.remove() }
        let markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let service = RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version)),
            maximumFetchedRemotes: 2)

        let remotes = Remotes()
        let run = await service.fetch(model) { remotes.set($0) }

        XCTAssertEqual(run, .finished(failures: [], remoteLimit: FetchRemoteLimit(fetched: 2, total: 5)))
        XCTAssertEqual(remotes.value, ["r0", "r1"], "the first remotes, in configuration order")
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        XCTAssertEqual(log.split(separator: "\n").filter { $0 == "fetch" }.count, 2, "two git fetch processes")
        let skipped = try await hasRef("refs/remotes/r2/main")
        XCTAssertFalse(skipped, "r2 was not fetched")
        XCTAssertEqual(RepositoryService.defaultMaximumFetchedRemotes, 16)
    }

    func testUnderTheLimitReportsNoLimit() async throws {
        try await repository.git(["push", "-q", origin.path, "main"])
        try await repository.git(["remote", "add", "origin", origin.path])
        let run = await service().fetch(model)
        XCTAssertEqual(run, .finished(failures: []))
    }

    func testNoRemotes() async {
        let run = await service().fetch(model)
        XCTAssertEqual(run, .finished(failures: [.noRemotes]))
    }

    /// Fail closed: a configuration the inspector cannot neutralize stops the fetch of every remote before git runs.
    func testBlockedConfigurationFetchesNothing() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        try await repository.git(["push", "-q", "origin", "main"])
        try await repository.git(["update-ref", "-d", "refs/remotes/origin/main"])
        try await repository.git(["config", "filter.bad name.clean", "cat"])

        let run = await service().fetch(model)
        guard case .finished(let failures, _) = run else { return XCTFail("\(run)") }
        XCTAssertEqual(failures.map(\.reason), [.blockedByConfiguration])
        XCTAssertEqual(failures.first?.commands, [], "no git command for a repository with findings (#200)")
        let fetched = try await hasRef("refs/remotes/origin/main")
        XCTAssertFalse(fetched, "git fetch did not run")
    }

    /// Fail closed for fetch only: a repository-local TLS setting (`fetchBlockingReason`) stops git before it runs,
    /// and no command is offered (#200).
    func testFetchBlockingConfigurationFetchesNothing() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        try await repository.git(["push", "-q", "origin", "main"])
        try await repository.git(["update-ref", "-d", "refs/remotes/origin/main"])
        try await repository.git(["config", "http.sslCAInfo", "/tmp/overgrove-not-a-real-ca.pem"])

        let run = await service().fetch(model)
        guard case .finished(let failures, _) = run else { return XCTFail("\(run)") }
        XCTAssertEqual(failures.map(\.reason), [.blockedByConfiguration])
        XCTAssertEqual(failures.first?.commands, [])
        let fetched = try await hasRef("refs/remotes/origin/main")
        XCTAssertFalse(fetched, "git fetch did not run")
    }

    func testCancelledBeforeStartingIsCancelled() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        let service = service()
        let model = model
        let task = Task { await service.fetch(model) }
        task.cancel()
        let run = await task.value
        // Cancelled during inspection or before the first remote; either way nothing is reported as a failure.
        if case .finished(let failures, _) = run { XCTAssertEqual(failures, []) }
    }
}
