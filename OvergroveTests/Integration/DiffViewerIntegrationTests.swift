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

    private func load(
        _ context: Context, _ group: WorkingChangeGroup, _ path: String, originalPath: String? = nil
    ) async -> DiffLoadResult {
        await context.loader.load(
            FileSelection(
                worktree: context.main.path, group: group, path: GitPath(path),
                originalPath: originalPath.map(GitPath.init)),
            worktree: context.main,
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
        // Both names reach git, so it pairs them as a rename instead of a new file (#309).
        guard
            case .patch(let renamed) = await load(
                context, .staged, "src/new-name.txt", originalPath: "src/old-name.txt")
        else { return XCTFail() }
        XCTAssertEqual(renamed.files.count, 1)
        XCTAssertEqual(renamed.files.first?.renameFrom, GitPath("src/old-name.txt"))
        XCTAssertEqual(renamed.files.first?.renameTo, GitPath("src/new-name.txt"))
        XCTAssertFalse(renamed.files.first?.isNewFile == true)
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

    /// A relative path leaving the worktree is not previewed (T14).
    func testUntrackedPathLeavingTheWorktreeIsRefused() async throws {
        let context = try await context()
        let result = await load(context, .untracked, "../outside.txt")
        XCTAssertEqual(
            result, .unavailable("This file cannot be previewed: it is not a regular file inside the worktree."))
    }

    /// SEC-T4-08: on the malicious fixture the diff viewer's whole path (verified inspection, then the diff with that
    /// worktree's safety) runs none of the repository's payloads, for staged, unstaged, and untracked files.
    func testSECT4_08_DiffViewerRunsNoPayloads() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let root = try XCTUnwrap(PathValidator.canonical(fixture.repository))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let main = Worktree(
            path: GitPath(root.path), head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
            isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)
        let loader = LiveDiffLoader(client: { client })
        try fixture.clearCanaries()
        for (group, path) in [
            (WorkingChangeGroup.unstaged, "src/unstaged-modified.txt"), (.staged, "src/staged-modified.txt"),
            (.untracked, "untracked.txt"),
        ] {
            _ = await loader.load(
                FileSelection(worktree: main.path, group: group, path: GitPath(path)), worktree: main, of: repository,
                isSubmodule: false)
        }
        XCTAssertEqual(fixture.canaries(), [], "no payload ran")
    }

    /// SEC-T14-06: an untracked FIFO (which would stall git) and a symbolic link to a folder outside the worktree are
    /// not previewed.
    func testSECT14_06_UntrackedFIFOAndEscapingLinkAreNotPreviewed() async throws {
        let context = try await context()
        let root = URL(fileURLWithPath: context.main.path.display)
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "overgrove-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret\n".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let refusal = DiffLoadResult.unavailable(
            "This file cannot be previewed: it is not a regular file inside the worktree.")
        let fifoResult = await load(context, .untracked, "pipe")
        let escaped = await load(context, .untracked, "escape/secret.txt")
        XCTAssertEqual(fifoResult, refusal)
        XCTAssertEqual(escaped, refusal)
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
