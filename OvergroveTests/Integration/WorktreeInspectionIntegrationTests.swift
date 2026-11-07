import Foundation
import XCTest

@testable import Overgrove

/// `LiveWorktreeInspector` (#67) on real fixtures. Since #240 it shows the inspection `RepositoryService` made when the
/// list loaded (the one the worktree's status ran with) and runs no git command itself.
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

    /// The main worktree's entry from a real load, with the inspection its status ran with.
    private func loadedEntry(
        _ fixture: FixtureRepo, environment: GitEnvironment
    ) async throws -> (WorktreeListing.Entry, RepositoryOverview.Entry) {
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let overview = try await RepositoryService(client: client).loadOverview(of: repository(fixture))
        let main = try XCTUnwrap(overview.entries.first { $0.worktree.isMain })
        let entry = try XCTUnwrap(WorktreeListing(overview: overview).entries.first { $0.worktree.isMain })
        return (entry, main)
    }

    private func repository(_ fixture: FixtureRepo) -> Repository {
        Repository(
            rootURL: fixture.repository, commonGitDirectoryURL: fixture.repository.appendingPathComponent(".git"),
            isBare: false)
    }

    /// SEC-T11-04 (S-05, QA-SEC-05): the normal fixture's only finding is the `mirror` remote with credentials in its
    /// URL (fixtures.md), shown masked. Every other row is applied.
    func testSECT11_04_NormalFixtureShowsOnlyTheMaskedRemote() async throws {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let (entry, loaded) = try await loadedEntry(fixture, environment: environment)
        let result = await inspector(environment: environment, parent: fixture.environment)
            .inspect(entry, of: repository(fixture))

        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.inspection)
        XCTAssertEqual(result.inspection, loaded.inspection, "S-05 shows the inspection the status ran with (#240)")
        XCTAssertEqual(result.gitVersion, environment.version)
        let model = WorktreeSecurityModel(result)
        XCTAssertNil(model.blockingReason)
        XCTAssertEqual(model.rows.count, 8)
        let flagged = model.rows.filter { $0.mark != .applied }
        XCTAssertEqual(flagged.map(\.title), ["Remote URL credentials masked"], "\(flagged)")
        let raw = try XCTUnwrap(result.inspection?.remotes.first { $0.name.value == "mirror" }?.url)
        // Host and path by default; the full masked URL with Settings › Show full remote URLs (#86).
        XCTAssertEqual(flagged.first?.details, ["mirror: example.invalid/overgrove-fixture"])
        let full = WorktreeSecurityModel(result, showsFullRemoteURLs: true)
        XCTAssertEqual(
            full.rows.first { $0.title == "Remote URL credentials masked" }?.details,
            ["mirror: https://***@example.invalid/overgrove-fixture.git"])
        XCTAssertFalse(full.rows.flatMap(\.details).contains(raw))
        XCTAssertNotEqual(raw, "https://***@example.invalid/overgrove-fixture.git", "the raw URL has the secret")
        XCTAssertFalse(model.rows.flatMap(\.details).contains(raw))
    }

    /// The malicious fixture's payload settings show as ⚠ with key names only, and nothing runs (canaries stay
    /// empty: the load ran with the neutralization, and the inspector runs no command).
    func testMaliciousFixtureShowsNeutralizedKeys() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let (entry, _) = try await loadedEntry(fixture, environment: environment)
        let result = await inspector(environment: environment, parent: fixture.environment)
            .inspect(entry, of: repository(fixture))

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
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: base), ["hooks/pre-commit"])
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: base.appendingPathComponent("none")), [])

        // A link inside counts (over-reporting is the safe side); a linked `hooks` folder is not followed.
        try FileManager.default.createSymbolicLink(
            at: hooks.appendingPathComponent("post-merge"),
            withDestinationURL: hooks.appendingPathComponent("notes.txt"))
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: base), ["hooks/post-merge", "hooks/pre-commit"])
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("hooks"), withDestinationURL: hooks)
        XCTAssertEqual(LiveWorktreeInspector.hookExecutables(in: linked), ["hooks (a link, not followed)"])
    }

    func testHookListIsCapped() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "overgrove-hooks-\(UUID().uuidString)", isDirectory: true)
        let hooks = base.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<(LiveWorktreeInspector.maximumHookNames + 3) {
            let file = hooks.appendingPathComponent(String(format: "hook-%02d", index))
            try "hook\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let listed = LiveWorktreeInspector.hookExecutables(in: base)
        XCTAssertEqual(listed.count, LiveWorktreeInspector.maximumHookNames + 1)
        XCTAssertEqual(listed.last, "+3 more")
    }

    /// A worktree the load did not inspect (foreign, prunable, a probe that failed) shows why, and the inspector does
    /// not inspect it on its own (#240).
    func testWorktreeTheLoadDidNotInspectIsNotInspectedAgain() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let entry = WorktreeListing.Entry(
            worktree: worktree(fixture.repository), state: .notQueried(.foreignRepository), inspection: nil)
        let result = await inspector(environment: environment, parent: fixture.environment)
            .inspect(entry, of: repository(fixture))
        XCTAssertNil(result.inspection)
        XCTAssertEqual(result.failure, LiveWorktreeInspector.notInspected)
        XCTAssertEqual(fixture.canaries(), [])
    }
}
