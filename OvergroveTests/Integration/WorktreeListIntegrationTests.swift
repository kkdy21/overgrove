import Foundation
import XCTest

@testable import Overgrove

/// The worktree list (#65) through the app's real path on the normal fixture (fixtures.md): `configList` →
/// `RepoConfigInspector` → `worktree list` → per-worktree probe, inspection, and `status` → `WorktreeListModel`.
final class WorktreeListIntegrationTests: XCTestCase {
    private func loader(_ context: IntegrationContext) -> LiveRepositoryLoader {
        let client = context.client
        let service = RepositoryService(client: client)
        return LiveRepositoryLoader(services: { (client, service) })
    }

    private func load() async throws -> (IntegrationContext, WorktreeListing) {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let listing = try await loader(context).load(context.repository)
        return (context, listing)
    }

    func testFixtureLoadsEveryWorktreeWithItsState() async throws {
        let (context, listing) = try await load()
        let fixture = context.fixture
        XCTAssertEqual(listing.entries.count, 9)
        XCTAssertFalse(listing.isPartial)

        func entry(_ name: String) throws -> WorktreeListing.Entry {
            let path = name == "main" ? fixture.repository.path : fixture.worktree(name).path
            return try XCTUnwrap(listing.entries.first { $0.worktree.path.display == path }, name)
        }
        XCTAssertEqual(try entry("wt-prunable").state, .missing, "INT-14: never queried")
        for name in ["main", "wt-ahead", "wt-behind", "wt-conflict", "wt-detached", "wt-locked", "wt-no-upstream"] {
            guard case .loaded = try entry(name).state else { return XCTFail("\(name): \(try entry(name).state)") }
        }
    }

    func testRowsMatchTheFixture() async throws {
        let (context, listing) = try await load()
        let model = WorktreeListModel(listing: listing, focused: nil)
        let rows = model.rows
        XCTAssertNil(model.warning)
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.first?.title, "main")
        XCTAssertEqual(rows.first?.isFocused, true)
        XCTAssertEqual(rows.last?.subtitle, "path missing", "prunable sorts last")
        XCTAssertEqual(rows.last?.badges, [.prunable])

        func row(_ name: String) throws -> WorktreeRow {
            try XCTUnwrap(rows.first { $0.id.display == context.fixture.worktree(name).path }, name)
        }
        XCTAssertEqual(try row("wt-detached").title, "detached @ c46c37d")
        XCTAssertEqual(try row("wt-locked").badges.last, .locked)
        XCTAssertTrue(try row("wt-locked").help.contains("Locked: fixture: locked on purpose"))
        XCTAssertTrue(try row("wt-conflict").badges.contains { if case .conflicts = $0 { true } else { false } })
        XCTAssertTrue(try row("wt-ahead").badges.contains { if case .ahead = $0 { true } else { false } })
        XCTAssertTrue(try row("wt-behind").badges.contains { if case .behind = $0 { true } else { false } })

        let snapshot = WorktreeListModel.snapshot(listing: listing, focused: nil)
        XCTAssertEqual(snapshot.worktreeCount, 9)
        XCTAssertEqual(snapshot.prunableCount, 1)
        XCTAssertEqual(snapshot.focusedWorktree?.branch, "main")
    }

    /// A forged `.git/worktrees/<id>/gitdir` naming another repository is listed but never queried (T14).
    func testForgedEntryPointingAtAnotherRepositoryIsNotQueried() async throws {
        let main = try await GitTestRepository.make()
        let other = try await GitTestRepository.make()
        defer {
            main.remove()
            other.remove()
        }
        for repository in [main, other] {
            try repository.write("README", "x\n")
            try await repository.git(["add", "README"])
            try await repository.git(["commit", "-q", "-m", "first"])
        }
        let admin = main.root.appendingPathComponent(".git/worktrees/forged", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "\(other.root.path)/.git\n".write(
            to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        let root = try XCTUnwrap(PathValidator.canonical(main.root))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let client = GitClient(environment: main.environment)
        let service = RepositoryService(client: client)
        let listing = try await LiveRepositoryLoader(services: { (client, service) }).load(repository)

        let forged = try XCTUnwrap(
            listing.entries.first { !$0.worktree.isMain }, "git lists the forged entry")
        XCTAssertEqual(forged.state, .notQueried(.foreignRepository))
        XCTAssertEqual(
            WorktreeListModel(listing: listing, focused: nil).rows.last?.subtitle, "Not part of this repository")
    }
}
