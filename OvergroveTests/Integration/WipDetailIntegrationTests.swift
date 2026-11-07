import Foundation
import XCTest

@testable import Overgrove

/// The WIP detail (#66) through the app's real path on the normal fixture (fixtures.md §4): inspection →
/// `RepositoryService` → `WorktreeListing` → `WipDetailModel`.
final class WipDetailIntegrationTests: XCTestCase {
    private func listing() async throws -> (IntegrationContext, WorktreeListing) {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let listing = try await LiveRepositoryLoader(services: { (client, service) }).load(context.repository)
        return (context, listing)
    }

    private func model(_ path: String, in listing: WorktreeListing) throws -> WipDetailModel {
        let entry = try XCTUnwrap(listing.entries.first { $0.worktree.path.display == path }, path)
        return WipDetailModel(entry: entry)
    }

    /// INT-02 through the detail: 6 staged, 8 unstaged, 6 untracked; the `MM` file in both groups.
    func testMainWorktreeGroups() async throws {
        let (context, listing) = try await listing()
        let model = try model(context.fixture.repository.path, in: listing)
        XCTAssertEqual(model.title, "main")
        XCTAssertEqual(model.groups.map(\.group), [.staged, .unstaged, .untracked])
        XCTAssertEqual(model.groups.map(\.totalCount), [6, 8, 6])
        XCTAssertNil(model.warning)

        let staged = model.groups[0].rows
        let unstaged = model.groups[1].rows
        let both = "src/staged-and-unstaged.txt"
        XCTAssertTrue(staged.contains { $0.path.display == both })
        XCTAssertTrue(unstaged.contains { $0.path.display == both })
        XCTAssertEqual(model.changedFileCount, 6 + 8 + 6 - 1, "the MM file counts once")

        let rename = try XCTUnwrap(staged.first { $0.kindLetter == "R" })
        XCTAssertEqual(rename.directory, "src/")
        XCTAssertEqual(rename.fileName, "{old-name.txt → new-name.txt}")

        // Paths with control characters are escaped; leading dashes are ordinary names.
        XCTAssertTrue(staged.contains { $0.fileName == "line\\u{A}break.txt" })
        XCTAssertTrue(model.groups[2].rows.contains { $0.fileName == "tab\\u{9}here.txt" })
        XCTAssertTrue(model.groups[2].rows.contains { $0.fileName == "--option-like.txt" })
        XCTAssertTrue(model.groups.flatMap(\.rows).allSatisfy(\.isSelectable))
    }

    /// INT-03 through the detail: the conflict worktree shows CONFLICTED first, with the kind named.
    func testConflictWorktree() async throws {
        let (context, listing) = try await listing()
        let model = try model(context.fixture.worktree("wt-conflict").path, in: listing)
        XCTAssertEqual(model.groups.map(\.group), [.conflicted])
        let rows = try XCTUnwrap(model.groups.first?.rows)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: rows.map { ($0.fileName, $0.kindName) }),
            ["conflict.txt": "both modified", "both-added.txt": "both added", "deleted-by-us.txt": "deleted by us"])
        XCTAssertTrue(rows.allSatisfy { $0.kindLetter == "U" })
    }

    func testPrunableWorktreeShowsMissing() async throws {
        let (context, listing) = try await listing()
        XCTAssertEqual(try model(context.fixture.worktree("wt-prunable").path, in: listing).content, .missing)
    }
}
