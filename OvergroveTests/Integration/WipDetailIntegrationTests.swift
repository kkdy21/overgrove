import Foundation
import XCTest

@testable import Overgrove

/// The WIP detail (#66) through the app's real path on the normal fixture (fixtures.md §4): inspection →
/// `RepositoryService` → `WorktreeListing` → `WipDetailModel`.
final class WipDetailIntegrationTests: XCTestCase {
    private func listing() async throws -> (IntegrationContext, WorktreeListing) {
        let (context, listing, _) = try await loaded()
        return (context, listing)
    }

    private func loaded() async throws -> (IntegrationContext, WorktreeListing, LiveRepositoryLoader) {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let loader = LiveRepositoryLoader(services: { (client, service) })
        let listing = try await loader.load(context.repository)
        return (context, listing, loader)
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

    // MARK: Line counts (#230)

    /// The main worktree's real numstat (git output captured in parsing-spec.md §8.3's tests): every staged and
    /// unstaged row has its count, the `MM` file has one on each side, and untracked rows have none.
    func testMainWorktreeLineCounts() async throws {
        let (context, listing, loader) = try await loaded()
        let path = GitPath(context.fixture.repository.path)
        let queried = try await loader.lineCounts(context.repository, worktree: path)
        let counts = try XCTUnwrap(queried)
        let entry = try XCTUnwrap(listing.entries.first { $0.worktree.path == path })
        let model = WipDetailModel(entry: entry, lineCounts: .loaded(counts))

        func row(_ group: WorkingChangeGroup, _ path: String) throws -> WipFileRow {
            let rows = try XCTUnwrap(model.groups.first { $0.group == group }).rows
            return try XCTUnwrap(rows.first { $0.path.display == path }, "\(group) \(path)")
        }
        let both = "src/staged-and-unstaged.txt"
        XCTAssertEqual(try row(.staged, both).lineCount, .lines(added: 1, deleted: 0))
        XCTAssertEqual(try row(.unstaged, both).lineCount, .lines(added: 1, deleted: 0))
        XCTAssertEqual(try row(.staged, "src/staged-deleted.txt").lineCount, .lines(added: 0, deleted: 2))
        XCTAssertEqual(try row(.staged, "src/new-name.txt").lineCount, .lines(added: 0, deleted: 0), "pure rename")
        XCTAssertEqual(try row(.staged, "line\nbreak.txt").lineCount, .lines(added: 1, deleted: 0))
        XCTAssertEqual(try row(.unstaged, "src/typechange").lineCount, .lines(added: 1, deleted: 1))
        XCTAssertEqual(try row(.unstaged, "-dash-leading.txt").lineCount, .lines(added: 1, deleted: 0))
        XCTAssertEqual(try row(.unstaged, "scripts/run.sh").lineCount, .lines(added: 0, deleted: 0), "mode only")

        let groups = Dictionary(uniqueKeysWithValues: model.groups.map { ($0.group, $0) })
        XCTAssertEqual(groups[.staged]?.lineTotals, WipLineTotals(added: 4, deleted: 2))
        XCTAssertEqual(groups[.unstaged]?.lineTotals, WipLineTotals(added: 6, deleted: 3))
        XCTAssertEqual(model.lineTotals, WipLineTotals(added: 10, deleted: 5))
        XCTAssertTrue(groups[.untracked]?.rows.allSatisfy { $0.lineCount == nil } ?? false)
        XCTAssertNil(groups[.untracked]?.lineTotals)
    }

    /// Unmerged paths print twice in `git diff --numstat`; they are dropped, so the query does not fail.
    func testConflictWorktreeHasNoCounts() async throws {
        let (context, _, loader) = try await loaded()
        let path = GitPath(context.fixture.worktree("wt-conflict").path)
        let queried = try await loader.lineCounts(context.repository, worktree: path)
        let counts = try XCTUnwrap(queried)
        XCTAssertEqual(counts, WorkingLineCounts(staged: [], unstaged: [], isPartial: false))
    }

    /// A binary file has no line counts in numstat (`-\t-`) and shows as `binary`.
    func testBinaryFile() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00]).write(
            to: repository.root.appendingPathComponent("logo.png"))
        try await repository.git(["add", "logo.png"])

        let client = GitClient(environment: repository.environment)
        let service = RepositoryService(client: client)
        let loader = LiveRepositoryLoader(services: { (client, service) })
        let model = Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
        let listing = try await loader.load(model)
        let entry = try XCTUnwrap(listing.entries.first)
        let queried = try await loader.lineCounts(model, worktree: entry.worktree.path)
        let counts = try XCTUnwrap(queried)
        XCTAssertEqual(counts.staged[GitPath("logo.png")]?.isBinary, true)

        let detail = WipDetailModel(entry: entry, lineCounts: .loaded(counts))
        XCTAssertEqual(detail.groups.first?.rows.map(\.lineCount), [.binary])
        XCTAssertEqual(detail.lineTotals, WipLineTotals(added: 0, deleted: 0))
    }
}
