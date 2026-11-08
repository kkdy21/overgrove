import Foundation
import XCTest

@testable import Overgrove

/// SEC-T5-23: before `lazyFetchControlVersion`, fetch does not fetch a remote on this Mac (a local path or
/// `file://`): that runs git in the other repository with the other repository's own settings, which the app's
/// arguments do not reach (#361, security-review.md T5).
///
/// The canary: the other repository is set up so that serving the fetch runs one of its own settings on older git, and
/// that setting records that it ran.
final class OlderGitLocalRemoteTests: XCTestCase {
    private let older = GitVersion(major: 2, minor: 45, patch: 0)
    private var origin: RemoteName { RemoteName("origin")! }

    func testLocalTransportFollowsTheVersion() {
        XCTAssertFalse(GitClient.allowsLocalTransport(GitVersion(major: 2, minor: 36, patch: 6)))
        XCTAssertFalse(GitClient.allowsLocalTransport(GitVersion(major: 2, minor: 44, patch: 0)))
        XCTAssertFalse(GitClient.allowsLocalTransport(GitVersion(major: 2, minor: 45, patch: 0)))
        XCTAssertTrue(GitClient.allowsLocalTransport(GitEnvironment.lazyFetchControlVersion))
        XCTAssertTrue(GitClient.allowsLocalTransport(GitVersion(major: 2, minor: 54, patch: 0)))
    }

    private func repository(_ test: GitTestRepository) -> Repository {
        Repository(rootURL: test.root, commonGitDirectoryURL: test.root.appendingPathComponent(".git"), isBare: false)
    }

    private func inspectedSafety(_ test: GitTestRepository) async throws -> RepoSafetyContext {
        let listing = try await GitClient(environment: test.environment)
            .run(.configList, in: test.root, safety: .preInspection)
        return try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
    }

    /// The real git, reporting `version`: the gate reads only the version, so this checks it on any installed git.
    private func client(_ test: GitTestRepository, version: GitVersion) -> GitClient {
        GitClient(environment: GitEnvironment(executable: test.environment.executable, version: version))
    }

    /// SEC-T5-23: an older git refuses a local remote before anything runs (`transport 'file' not allowed`); from
    /// `lazyFetchControlVersion` the same fetch works.
    func testSECT5_23_OlderGitRefusesALocalRemote() async throws {
        let source = try await GitTestRepository.make()
        defer { source.remove() }
        try await source.git(["commit", "-q", "--allow-empty", "-m", "one"])
        let local = try await GitTestRepository.make()
        defer { local.remove() }
        try await local.git(["remote", "add", "origin", source.root.path])
        let safety = try await inspectedSafety(local)

        do {
            _ = try await client(local, version: older).fetch(
                .fetch(remote: origin), in: repository(local), safety: safety)
            XCTFail("an older git must not fetch a local remote")
        } catch let error as GitError {
            guard case .transportNotAllowed("file", _) = error else { return XCTFail("got \(error)") }
        }
        let none = try await local.git(["for-each-ref", "refs/remotes"])
        XCTAssertTrue(none.stdout.isEmpty, "nothing was fetched")

        _ = try await client(local, version: GitEnvironment.lazyFetchControlVersion)
            .fetch(.fetch(remote: origin), in: repository(local), safety: safety)
        let fetched = try await local.git(["for-each-ref", "--format=%(refname)", "refs/remotes"])
        XCTAssertEqual(String(decoding: fetched.stdout, as: UTF8.self), "refs/remotes/origin/main\n")
    }

    /// SEC-T5-23 with the hostile other side: the app's fetch runs nothing of the other repository's settings on
    /// whatever git runs the tests (`OVERGROVE_TEST_GIT` picks 2.36, 2.44.0, 2.45.0, …). On a git older than
    /// `lazyFetchControlVersion`, the control (the same fetch with `file` allowed) runs the canary.
    func testSECT5_23_PartialCloneOnTheOtherSideRunsNothing() async throws {
        let upstream = try await GitTestRepository.make()
        defer { upstream.remove() }
        try upstream.write("a.txt", "blob-a\n")
        try upstream.write("b.txt", "blob-b\n")
        try await upstream.git(["add", "."])
        try await upstream.git(["commit", "-q", "-m", "one"])
        try await upstream.git(["config", "uploadpack.allowfilter", "true"])
        try await upstream.git(["config", "uploadpack.allowanysha1inwant", "true"])

        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-other-\(UUID().uuidString)", isDirectory: true)
        let canary = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: canary)
        }
        try await upstream.git([
            "clone", "-q", "--no-local", "--filter=blob:none", "--no-checkout", "file://\(upstream.root.path)",
            other.path,
        ])
        try await upstream.git([
            "-C", other.path, "config", "remote.origin.uploadpack",
            "touch '\(canary.path)/ran'; git-upload-pack",
        ])

        let local = try await GitTestRepository.make()
        defer { local.remove() }
        try await local.git(["remote", "add", "origin", other.path])
        let safety = try await inspectedSafety(local)
        let target = repository(local)

        _ = try? await GitClient(environment: local.environment).fetch(
            .fetch(remote: origin), in: target, safety: safety)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: canary.path), [], "the app's fetch")

        guard local.environment.version < GitEnvironment.lazyFetchControlVersion else { return }
        _ = try? await client(local, version: GitEnvironment.lazyFetchControlVersion)
            .fetch(.fetch(remote: origin), in: target, safety: safety)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: canary.path), ["ran"],
            "control: git \(local.environment.version) with `file` allowed runs the other side's setting")
    }

    /// `RepositoryService` reports the refusal with its own text and offers no command.
    func testRepositoryServiceExplainsTheRefusal() async throws {
        let source = try await GitTestRepository.make()
        defer { source.remove() }
        try await source.git(["commit", "-q", "--allow-empty", "-m", "one"])
        let local = try await GitTestRepository.make()
        defer { local.remove() }
        try await local.git(["remote", "add", "origin", source.root.path])

        let service = RepositoryService(client: client(local, version: older))
        let run = await service.fetch(repository(local), untrusted: false)
        guard case .finished(let failures, _) = run else { return XCTFail("got \(run)") }
        XCTAssertEqual(failures.map(\.remote), [origin])
        XCTAssertEqual(failures.first?.guidance, RepositoryService.olderGitLocalReason)
        // #383: the summary names the git, not the repository, as the cause.
        XCTAssertEqual(failures.first?.summary, "Overgrove does not fetch origin with this git")
        XCTAssertEqual(failures.first?.commands, [])

        let untrusted = await service.fetch(repository(local), untrusted: true)
        guard case .finished(let marked, _) = untrusted else { return XCTFail("got \(untrusted)") }
        XCTAssertEqual(marked.first?.guidance, RepositoryService.untrustedLocalReason, "untrusted says so first")
    }
}
