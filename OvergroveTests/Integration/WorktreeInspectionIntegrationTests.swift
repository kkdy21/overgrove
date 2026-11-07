import Foundation
import XCTest

@testable import Overgrove

/// `LiveWorktreeInspector` (#67) on real fixtures: only `configList` runs, and S-05 reflects what it found.
final class WorktreeInspectionIntegrationTests: XCTestCase {
    private func inspector(environment: GitEnvironment, parent: [String: String]) -> LiveWorktreeInspector {
        let client = GitClient(environment: environment, parentEnvironment: parent)
        return LiveWorktreeInspector(client: { client })
    }

    private func worktree(_ path: URL) -> Worktree {
        Worktree(
            path: GitPath(path.path), head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
            isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)
    }

    private func repository(_ fixture: FixtureRepo) -> Repository {
        Repository(
            rootURL: fixture.repository, commonGitDirectoryURL: fixture.repository.appendingPathComponent(".git"),
            isBare: false)
    }

    /// The normal fixture's only finding is the `mirror` remote with credentials in its URL (fixtures.md): shown
    /// masked (T11). Every other row is applied.
    func testNormalFixtureShowsOnlyTheMaskedRemote() async throws {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let result = await inspector(environment: environment, parent: fixture.environment)
            .inspect(worktree(fixture.repository), of: repository(fixture))

        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.inspection)
        XCTAssertEqual(result.gitVersion, environment.version)
        let model = WorktreeSecurityModel(result)
        XCTAssertNil(model.blockingReason)
        XCTAssertEqual(model.rows.count, 8)
        let flagged = model.rows.filter { $0.mark != .applied }
        XCTAssertEqual(flagged.map(\.title), ["Remote URL credentials masked"], "\(flagged)")
        XCTAssertEqual(flagged.first?.details, ["mirror: https://***@example.invalid/overgrove-fixture.git"])
        let raw = try XCTUnwrap(result.inspection?.remotes.first { $0.name.value == "mirror" }?.url)
        XCTAssertNotEqual(raw, "https://***@example.invalid/overgrove-fixture.git", "the raw URL has the secret")
        XCTAssertFalse(model.rows.flatMap(\.details).contains(raw))
    }

    /// The malicious fixture's payload settings show as ⚠ with key names only, and nothing runs (canaries stay
    /// empty: `configList` is the only command).
    func testMaliciousFixtureShowsNeutralizedKeys() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let result = await inspector(environment: environment, parent: fixture.environment)
            .inspect(worktree(fixture.repository), of: repository(fixture))

        let model = WorktreeSecurityModel(result)
        XCTAssertTrue(model.rows.contains { $0.mark == .neutralized }, "\(model.rows)")
        let shown = model.rows.flatMap(\.details) + model.others.map(\.key)
        XCTAssertFalse(shown.isEmpty)
        // Payload paths live in the values; none may be shown.
        XCTAssertFalse(shown.contains { $0.contains(fixture.canary.path) }, "\(shown)")
        XCTAssertEqual(fixture.canaries(), [], "inspection ran nothing")
    }

    func testHookExecutablesAreListedByName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "overgrove-hooks-\(UUID().uuidString)", isDirectory: true)
        let hooks = base.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for (name, mode) in [("pre-commit", 0o755), ("pre-push.sample", 0o755), ("notes.txt", 0o644)] {
            let file = hooks.appendingPathComponent(name)
            try "hook\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: base), ["pre-commit"])
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: base.appendingPathComponent("none")), [])
    }
}
