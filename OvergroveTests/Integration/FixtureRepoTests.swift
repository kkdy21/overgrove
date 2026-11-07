import Foundation
import XCTest

@testable import Overgrove

/// Smoke tests for `FixtureRepo` (test-strategy.md §6, §8): the script builds both fixtures in an isolated temporary
/// directory and the result matches a few documented facts from docs/testing/fixtures.md.
final class FixtureRepoTests: XCTestCase {
    /// fixtures.md §1.1 / §3: linked worktree directories on disk (`wt-prunable` is deleted on purpose).
    private static let worktreeDirectories = [
        "wt-ahead", "wt-behind", "wt-conflict", "wt-detached", "wt-diverged", "wt-locked", "wt-no-upstream",
    ]

    func testNormalFixtureHasDocumentedWorktreesAndStashes() async throws {
        let fixture = try await makeFixture()
        let files = FileManager.default

        XCTAssertTrue(fixture.container.path.hasPrefix("/private/"), "symlinks resolved like git reports them")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: fixture.home.path), [], "HOME stays empty")
        XCTAssertEqual(try files.contentsOfDirectory(atPath: fixture.worktrees.path).sorted(), Self.worktreeDirectories)
        XCTAssertTrue(files.fileExists(atPath: fixture.remotes.appendingPathComponent("origin.git/HEAD").path))
        XCTAssertFalse(files.fileExists(atPath: fixture.canary.path), "canary/ exists only with --malicious")
        XCTAssertFalse(files.fileExists(atPath: fixture.payloads.path), "payloads/ exists only with --malicious")

        let client = GitClient(environment: try await GitEnvironment.discover(), parentEnvironment: fixture.environment)
        let config = try await client.run(.configList, in: fixture.repository, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout)).safetyContext)

        // fixtures.md §3: 9 records; main first; one each of locked, prunable and detached.
        let listing = try await client.run(.worktreeList, in: fixture.repository, safety: safety)
        let worktrees = try WorktreeParser.parse(listing.stdout).worktrees
        XCTAssertEqual(worktrees.count, 9)
        XCTAssertEqual(worktrees.first?.isMain, true)
        XCTAssertEqual(worktrees.first?.path.display, fixture.repository.path)
        XCTAssertEqual(worktrees.first?.branch, "refs/heads/main")
        XCTAssertEqual(worktrees.filter(\.isLocked).map(\.lock), [.locked(reason: "fixture: locked on purpose")])
        XCTAssertEqual(worktrees.filter(\.isPrunable).map(\.path.display), [fixture.worktree("wt-prunable").path])
        let detached = worktrees.filter(\.isDetached)
        XCTAssertEqual(detached.map(\.path.display), [fixture.worktree("wt-detached").path])
        XCTAssertEqual(detached.first?.head?.short, "c46c37d", "wt-detached is at main~2")

        // fixtures.md §2.4: two stashes, newest first.
        let stashOutput = try await client.run(.stashList, in: fixture.repository, safety: safety)
        let stashes = try StashParser.parse(stashOutput.stdout).stashes
        XCTAssertEqual(
            stashes.map(\.subject),
            ["On feat/ahead: fixture: with untracked", "On main: fixture: tracked change"]
        )
    }

    /// Builds `--malicious` and checks only the files on disk. No git command runs in the repository here, so no
    /// payload can fire; executing commands against it is the canary harness's job (SEC-Tn-xx).
    func testMaliciousFixtureIsCreatedWithPayloadsAndAnEmptyCanary() async throws {
        let fixture = try await FixtureRepo.make(malicious: true)
        defer { fixture.remove() }
        let files = FileManager.default

        XCTAssertTrue(fixture.isMalicious)
        XCTAssertEqual(fixture.canaries(), [], "creating the fixture must not run any payload")
        XCTAssertTrue(files.fileExists(atPath: fixture.canary.path))
        XCTAssertTrue(files.isExecutableFile(atPath: fixture.payloads.appendingPathComponent("t1-fsmonitor.sh").path))
        XCTAssertTrue(files.isExecutableFile(atPath: fixture.payloads.appendingPathComponent("hooks/pre-commit").path))

        // fixtures.md §8.1: payload configuration lives in the repository-local config file.
        let gitDirectory = fixture.repository.appendingPathComponent(".git")
        let config = try String(contentsOf: gitDirectory.appendingPathComponent("config"), encoding: .utf8)
        let payloads = fixture.payloads.path
        for entry in ["fsmonitor = \(payloads)/t1-fsmonitor.sh", "hooksPath = \(payloads)/hooks"] {
            XCTAssertTrue(config.contains(entry), "missing \(entry)")
        }
        XCTAssertTrue(config.contains("[remote \"extremote\"]"))
        XCTAssertTrue(files.fileExists(atPath: gitDirectory.appendingPathComponent("info/attributes").path))
        XCTAssertTrue(files.fileExists(atPath: gitDirectory.appendingPathComponent("objects/info/alternates").path))
    }

    func testRemoveDeletesFixtureAndHome() async throws {
        try XCTSkipIf(keepsFixtures, "OVERGROVE_KEEP_FIXTURES=1 keeps fixtures on purpose")
        let fixture = try await FixtureRepo.make()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository.path))

        fixture.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.container.path))
        fixture.remove()  // idempotent
    }

    /// #234: only a setup push or fetch that lost its local receiving process is retried.
    func testOnlyAHungUpLocalTransportIsRetried() {
        let container = URL(fileURLWithPath: "/nonexistent")
        func failure(_ stderr: String, timedOut: Bool = false) -> FixtureRepo.Failure {
            .scriptFailed(termination: .exited(code: 128), timedOut: timedOut, stderr: stderr, container: container)
        }
        XCTAssertTrue(failure("fatal: the remote end hung up unexpectedly\n").isTransientSetupFailure)
        XCTAssertFalse(failure("fatal: the remote end hung up unexpectedly\n", timedOut: true).isTransientSetupFailure)
        XCTAssertFalse(failure("fatal: not a git repository\n").isTransientSetupFailure)
        XCTAssertFalse(FixtureRepo.Failure.unexpectedOutput("x", container: container).isTransientSetupFailure)
    }

    func testFailedScriptThrowsAndLeavesNothingBehind() async throws {
        try XCTSkipIf(keepsFixtures, "OVERGROVE_KEEP_FIXTURES=1 keeps fixtures on purpose")
        let missing = FixtureRepo.script.deletingLastPathComponent().appendingPathComponent("no-such-script.sh")
        do {
            _ = try await FixtureRepo.make(script: missing)
            XCTFail("a failing script must throw")
        } catch let failure as FixtureRepo.Failure {
            guard case .scriptFailed(let termination, _, _, _) = failure else {
                return XCTFail("unexpected failure: \(failure)")
            }
            XCTAssertNotEqual(termination, .exited(code: 0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: failure.container.path))
        }
    }

    func testEnvironmentIsIsolatedFromTheRunner() {
        let fixture = FixtureRepo(
            container: URL(fileURLWithPath: "/private/tmp/c"),
            root: URL(fileURLWithPath: "/private/tmp/c/fixture"),
            home: URL(fileURLWithPath: "/private/tmp/c/home"),
            isMalicious: false
        )
        XCTAssertEqual(Set(fixture.environment.keys), ["HOME", "TMPDIR"])
        XCTAssertEqual(fixture.environment["HOME"], "/private/tmp/c/home")
        // What GitClient would hand to git: the runner's HOME, USER and SSH agent do not leak through.
        let gitEnvironment = GitEnvironment.environment(parent: fixture.environment)
        XCTAssertEqual(gitEnvironment["HOME"], "/private/tmp/c/home")
        XCTAssertNil(gitEnvironment["USER"])
        XCTAssertNil(gitEnvironment["SSH_AUTH_SOCK"])
    }

    private var keepsFixtures: Bool {
        ProcessInfo.processInfo.environment["OVERGROVE_KEEP_FIXTURES"] == "1"
    }
}
