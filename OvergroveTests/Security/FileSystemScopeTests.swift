import Foundation
import XCTest

@testable import Overgrove

/// T14 (security-review.md §2): the repository cannot widen what Overgrove reads. SEC-T14-01 (registration through a
/// symbolic link is flagged) is in `PathValidatorTests`; SEC-T14-02 has unit tests there (`containment`, `..`) and
/// the app-path test below.
final class FileSystemScopeTests: XCTestCase {
    private var executables: TestExecutables!
    private var scenario: SecurityScenario!

    override func setUp() async throws {
        executables = try TestExecutables()
        scenario = try await SecurityScenario.make(executables)
    }

    override func tearDown() {
        executables?.remove()
    }

    private func repository() async throws -> URL {
        let repo = scenario.directory("repo")
        try await scenario.plain(
            ["init", "-q", "-b", "main", repo.path], in: executables.directory, requireSuccess: true)
        try "x\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try await scenario.plain(["add", "x.txt"], in: repo, requireSuccess: true)
        try await scenario.plain(["commit", "-q", "-m", "initial"], in: repo, requireSuccess: true)
        return repo
    }

    /// SEC-T14-02 on the app's path: an untracked symbolic link pointing at a secret outside the worktree is
    /// previewed as its link text only, never the secret's content; a link inside a directory that itself escapes
    /// the worktree is refused before git runs.
    func testSECT14_02_PreviewShowsLinkTextNotTheTarget() async throws {
        let repo = try await repository()
        let outside = executables.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("id_ed25519")
        let secretContent = "SEC-T14-02-PRIVATE-\(UUID().uuidString)"
        try secretContent.write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("innocent.txt"), withDestinationURL: secret)

        let file = try XCTUnwrap(PathValidator.worktreeFile(GitPath("innocent.txt"), in: repo))
        let output = try await scenario.app(.untrackedPreview(file), in: repo)
        let patch = String(decoding: output.stdout, as: UTF8.self)
        XCTAssertFalse(patch.contains(secretContent), "the preview must not show the link target's content")
        XCTAssertTrue(patch.contains(secret.path), "the preview shows the link text")
        XCTAssertTrue(patch.contains("new file mode 120000"), "git reports it as a symbolic link")

        // A directory that is itself a link out of the worktree: the file under it is refused.
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertNil(PathValidator.worktreeFile(GitPath("escape/id_ed25519"), in: repo))
    }

    private func worktreeFindings(_ inspection: RepoConfigInspection) -> [RepoSecurityReport.Finding] {
        inspection.report.findings.filter { $0.entry.key == "core.worktree" }
    }

    /// SEC-T14-03: a repository-local `core.worktree` (here, pointing at the home directory, the scenario from
    /// security-review.md) is reported to the user as a T14 warning. It is a warning, not a block: git honors it,
    /// and the user decides.
    func testSECT14_03_LocalCoreWorktreeIsReported() async throws {
        let repo = try await repository()
        let clean = try await scenario.inspect(repo)
        XCTAssertEqual(worktreeFindings(clean), [], "no finding without core.worktree")

        try await scenario.config("core.worktree", scenario.home.path, in: repo)
        let inspection = try await scenario.inspect(repo)
        let findings = worktreeFindings(inspection)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.threat, "T14")
        XCTAssertEqual(findings.first?.handling, .warned)
        XCTAssertEqual(findings.first?.entry.scope, .local)
        XCTAssertEqual(findings.first?.entry.value, scenario.home.path)
        XCTAssertFalse(inspection.report.isBlocked, "a warning lets the user decide; it does not block queries")
        XCTAssertNotNil(inspection.safetyContext)
    }

    /// SEC-T14-03, `include.path` route: a `core.worktree` set in an included file is still reported, as a local
    /// entry (`config --list --includes`, fixtures.md §8.3).
    func testSECT14_03_IncludedCoreWorktreeIsReported() async throws {
        let repo = try await repository()
        let included = executables.directory.appendingPathComponent("included.config")
        try "[core]\n\tworktree = \(scenario.home.path)\n".write(to: included, atomically: true, encoding: .utf8)
        try await scenario.config("include.path", included.path, in: repo)

        let findings = worktreeFindings(try await scenario.inspect(repo))
        XCTAssertEqual(findings.map(\.threat), ["T14"])
        XCTAssertEqual(findings.map(\.handling), [.warned])
    }
}
