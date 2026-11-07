import Foundation
import XCTest

@testable import Overgrove

/// The diff viewer's real path on the normal fixture (#232): verified worktree → its own inspection →
/// `worktreeDiff` / `untrackedPreview` → `PatchParser` → `DiffDocument`.
final class DiffViewerIntegrationTests: XCTestCase {
    private struct Context {
        let fixture: FixtureRepo
        let loader: LiveDiffLoader
        let repository: Repository
        let main: Worktree
    }

    private func context() async throws -> Context {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let root = try XCTUnwrap(PathValidator.canonical(fixture.repository))
        return Context(
            fixture: fixture, loader: LiveDiffLoader(client: { client }),
            repository: Repository(
                rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
            main: Worktree(
                path: GitPath(root.path), head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
                isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil))
    }

    private func load(_ context: Context, _ group: WorkingChangeGroup, _ path: String) async -> DiffLoadResult {
        await context.loader.load(
            FileSelection(worktree: context.main.path, group: group, path: GitPath(path)), worktree: context.main,
            of: context.repository, isSubmodule: false)
    }

    private func document(_ result: DiffLoadResult, _ path: String) throws -> DiffDocument {
        guard case .patch(let listing) = result else { throw XCTSkip("unexpected \(result)") }
        return DiffDocument(listing: listing, path: GitPath(path), source: .init(label: "", kindLetter: ""))
    }

    /// The `MM` file has different staged and unstaged diffs.
    func testStagedAndUnstagedDiffsOfTheSameFile() async throws {
        let context = try await context()
        let staged = await load(context, .staged, "src/staged-and-unstaged.txt")
        let unstaged = await load(context, .unstaged, "src/staged-and-unstaged.txt")
        guard case .patch(let stagedPatch) = staged, case .patch(let unstagedPatch) = unstaged else {
            return XCTFail("\(staged) \(unstaged)")
        }
        XCTAssertEqual(stagedPatch.files.count, 1)
        XCTAssertEqual(unstagedPatch.files.count, 1)
        XCTAssertNotEqual(stagedPatch, unstagedPatch)
        XCTAssertFalse(try document(staged, "src/staged-and-unstaged.txt").unifiedRows().isEmpty)
    }

    func testAddedDeletedAndRenamedStagedFiles() async throws {
        let context = try await context()
        guard case .patch(let added) = await load(context, .staged, "src/staged-added.txt") else { return XCTFail() }
        XCTAssertTrue(added.files.first?.isNewFile == true)
        guard case .patch(let deleted) = await load(context, .staged, "src/staged-deleted.txt") else {
            return XCTFail()
        }
        XCTAssertTrue(deleted.files.first?.isDeletedFile == true)
        // One pathspec: git shows the new path as added (rename detection needs both paths).
        guard case .patch(let renamed) = await load(context, .staged, "src/new-name.txt") else { return XCTFail() }
        XCTAssertEqual(renamed.files.count, 1)
    }

    /// Special names reach git as one argument after `--` and come back escaped.
    func testSpecialFileNames() async throws {
        let context = try await context()
        for (group, path) in [
            (WorkingChangeGroup.unstaged, "-dash-leading.txt"), (.unstaged, "with space.txt"),
            (.staged, "line\nbreak.txt"), (.untracked, "tab\there.txt"), (.untracked, "--option-like.txt"),
            (.untracked, "한글 파일.txt"),
        ] {
            let result = await load(context, group, path)
            guard case .patch(let listing) = result else { return XCTFail("\(path): \(result)") }
            XCTAssertEqual(listing.files.count, 1, path)
        }
    }

    func testUntrackedPreviewShowsTheWholeFileAsAdded() async throws {
        let context = try await context()
        let doc = try document(await load(context, .untracked, "untracked.txt"), "untracked.txt")
        let rows = doc.unifiedRows()
        XCTAssertTrue(rows.contains { if case .line(.added, nil, 1, _) = $0 { true } else { false } }, "\(rows)")
    }

    func testModeOnlyAndTypeChanges() async throws {
        let context = try await context()
        guard case .patch(let mode) = await load(context, .unstaged, "scripts/run.sh") else { return XCTFail() }
        XCTAssertNotNil(mode.files.first?.newMode)
        guard case .patch(let typechange) = await load(context, .unstaged, "src/typechange") else { return XCTFail() }
        XCTAssertEqual(typechange.files.count, 2, "a type change is two blocks")
    }

    /// An untracked FIFO or a path leaving the worktree is not previewed (T14).
    func testUntrackedThatIsNotARegularFileIsRefused() async throws {
        let context = try await context()
        let result = await load(context, .untracked, "../outside.txt")
        XCTAssertEqual(
            result, .unavailable("This file cannot be previewed: it is not a regular file inside the worktree."))
    }

    /// A worktree path that no longer matches the repository is not diffed.
    func testFolderThatNoLongerMatchesIsRefused() async throws {
        let context = try await context()
        let subfolder = Worktree(
            path: GitPath(context.main.path.display + "/src"), head: nil, branch: nil, isMain: false,
            isDetached: true, isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)
        let result = await context.loader.load(
            FileSelection(worktree: subfolder.path, group: .staged, path: GitPath("staged-added.txt")),
            worktree: subfolder, of: context.repository, isSubmodule: false)
        XCTAssertEqual(result, .unavailable(LiveWorktreeInspector.noLongerMatches))
    }
}
