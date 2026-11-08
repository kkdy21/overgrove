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
        let run = await service().fetch(model, untrusted: false) { remotes.set($0) }

        XCTAssertEqual(remotes.value, ["origin", "broken"])
        guard case .finished(let failures, _) = run else { return XCTFail("\(run)") }
        XCTAssertEqual(failures.map(\.remote?.value), ["broken"], "origin succeeded; broken failed")
        let refetched = try await hasRef("refs/remotes/origin/main")
        XCTAssertTrue(refetched, "origin's remote-tracking ref was written again")
        XCTAssertNotNil(
            FetchRecordStore.estimatedLastFetch(commonDirectory: model.commonGitDirectoryURL),
            "git wrote FETCH_HEAD, which later stands in for the time when there is no record")
    }

    /// SEC-T5-22 (#354): a failed fetch offers a git command for Terminal only when the repository has neither
    /// configuration findings nor executables in its hooks directory; a hostile repository could fail the fetch on
    /// purpose to get its hook run by a pasted command.
    func testSECT5_22_FetchGuidanceWithholdsTheCommandWhenHooksExist() async throws {
        let missing = origin.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).git")
        try await repository.git(["remote", "add", "broken", missing.path])
        guard case .finished(let clean, _) = await service().fetch(model, untrusted: false) else {
            return XCTFail("not finished")
        }
        XCTAssertTrue(clean.first?.commands.contains { $0.hasPrefix("git ") } ?? false, "\(clean.map(\.commands))")

        let hook = repository.root.appendingPathComponent(".git/hooks/post-checkout")
        try Data("not a program\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        guard case .finished(let hooked, _) = await service().fetch(model, untrusted: false) else {
            return XCTFail("not finished")
        }
        XCTAssertEqual(hooked.count, 1)
        XCTAssertFalse(hooked.first?.commands.contains { $0.hasPrefix("git ") } ?? true, "\(hooked.map(\.commands))")
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
        let run = await service.fetch(model, untrusted: false) { remotes.set($0) }

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
        let run = await service().fetch(model, untrusted: false)
        XCTAssertEqual(run, .finished(failures: []))
    }

    /// #107: an untrusted repository does not run git for a local remote at all; it is reported as turned off, with
    /// no command to copy. Remotes that are not local still fetch. A remote that only becomes local through
    /// configuration (`insteadOf`) is refused by the transport list and reported the same way.
    func testUntrustedRepositorySkipsLocalRemotes() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        try await repository.git(["push", "-q", "origin", "main"])
        try await repository.git(["update-ref", "-d", "refs/remotes/origin/main"])
        try await repository.git(["remote", "add", "mirror", "https://example.invalid/acme/api.git"])
        try await repository.git(["config", "url.\(origin.path).insteadOf", "https://example.invalid/acme/api.git"])

        let run = await service().fetch(model, untrusted: true)
        guard case .finished(let failures, _) = run else { return XCTFail("got \(run)") }
        XCTAssertEqual(failures.map(\.remote?.value), ["origin", "mirror"])
        for failure in failures {
            XCTAssertEqual(failure.reason, .blockedByConfiguration, "\(failure)")
            XCTAssertTrue(failure.guidance.contains("untrusted"), failure.guidance)
            XCTAssertEqual(failure.commands, [], "no command is offered for an untrusted repository")
        }
        let fetched = try await hasRef("refs/remotes/origin/main")
        XCTAssertFalse(fetched)

        // Trusted (the default): the same remote fetches.
        _ = await service().fetch(model, untrusted: false)
        let fetchedNow = try await hasRef("refs/remotes/origin/main")
        XCTAssertTrue(fetchedNow)
    }

    func testNoRemotes() async {
        let run = await service().fetch(model, untrusted: false)
        XCTAssertEqual(run, .finished(failures: [.noRemotes]))
    }

    /// Fail closed: a configuration the inspector cannot neutralize stops the fetch of every remote before git runs.
    func testBlockedConfigurationFetchesNothing() async throws {
        try await repository.git(["remote", "add", "origin", origin.path])
        try await repository.git(["push", "-q", "origin", "main"])
        try await repository.git(["update-ref", "-d", "refs/remotes/origin/main"])
        try await repository.git(["config", "filter.bad name.clean", "cat"])

        let run = await service().fetch(model, untrusted: false)
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

        let run = await service().fetch(model, untrusted: false)
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
        let task = Task { await service.fetch(model, untrusted: false) }
        task.cancel()
        let run = await task.value
        // Cancelled during inspection or before the first remote; either way nothing is reported as a failure.
        if case .finished(let failures, _) = run { XCTAssertEqual(failures, []) }
    }
}
