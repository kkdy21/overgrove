import Foundation
import XCTest

@testable import Overgrove

/// T13 (security-review.md §2): Overgrove's queries do not write to the repository. SEC-T13-01 (only read-only
/// subcommands exist) is `GitCommandTests.testSECT13_01_OnlyReadOnlySubcommandsExist`.
final class WriteProtectionTests: XCTestCase {
    /// Content and modification date of an index file.
    private struct IndexState: Equatable {
        let bytes: Data
        let modified: Date

        init(_ url: URL) throws {
            bytes = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        }
    }

    private static let linkedWorktrees = [
        "wt-ahead", "wt-behind", "wt-conflict", "wt-detached", "wt-diverged", "wt-locked", "wt-no-upstream",
    ]

    /// The index of the main worktree and of every linked worktree (`.git/worktrees/<name>/index`).
    private func indexes(_ fixture: FixtureRepo) -> [String: URL] {
        var indexes = ["repo": fixture.repository.appendingPathComponent(".git/index")]
        for name in Self.linkedWorktrees {
            indexes[name] = fixture.repository.appendingPathComponent(".git/worktrees/\(name)/index")
        }
        return indexes
    }

    /// A normal fixture where status would like to refresh stat data: `docs/manual.md` keeps its content but gets a
    /// new mtime in the main worktree and in `wt-behind`.
    private func staleStatFixture() async throws -> (IntegrationContext, [String: URL], [String: IndexState]) {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        for directory in [context.fixture.repository, context.fixture.worktree("wt-behind")] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_767_225_600)],
                ofItemAtPath: directory.appendingPathComponent("docs/manual.md").path)
        }
        let indexes = indexes(context.fixture)
        return (context, indexes, try indexes.mapValues(IndexState.init))
    }

    private func assertUnchanged(
        _ indexes: [String: URL],
        since before: [String: IndexState],
        after action: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (name, index) in indexes {
            let state = try IndexState(index)
            XCTAssertEqual(
                state.bytes, before[name]?.bytes, "\(action): \(name) index content changed", file: file, line: line)
            XCTAssertEqual(
                state.modified, before[name]?.modified, "\(action): \(name) index rewritten", file: file, line: line)
            let lock = index.deletingLastPathComponent().appendingPathComponent("index.lock")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: lock.path), "\(action): \(name) index.lock left", file: file,
                line: line)
        }
    }

    /// SEC-T13-02: status of every worktree leaves its index byte-for-byte and mtime-for-mtime unchanged, even when
    /// status would like to store refreshed stat data. Plain `git status` rewrites the index in the same state.
    func testSECT13_02_StatusNeverWritesTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        let fixture = context.fixture
        for directory in [fixture.repository] + Self.linkedWorktrees.map(fixture.worktree) {
            _ = try await context.status(of: directory)
        }
        try assertUnchanged(indexes, since: before, after: "app status")

        _ = try await context.plainGit(["status", "--porcelain"], in: fixture.repository)
        let rewritten = try IndexState(try XCTUnwrap(indexes["repo"]))
        XCTAssertNotEqual(rewritten, before["repo"], "control: plain status should rewrite the index")
    }

    /// T13 beyond status: the other queries that read a worktree or history leave every index unchanged too.
    func testOtherQueriesNeverWriteTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        let repo = context.fixture.repository
        let untracked = try XCTUnwrap(PathValidator.worktreeFile(GitPath("untracked.txt"), in: repo))
        let queries: [ReadOnlyGitCommand] = [
            .worktreeList, .refs, .stashList, .graphPage(skip: 0, limit: 500),
            .worktreeDiff(path: GitPath("src/staged-modified.txt"), staged: true),
            .worktreeDiff(path: GitPath("src/unstaged-modified.txt"), staged: false), .untrackedPreview(untracked),
            .fileHistory(path: GitPath("docs/manual.md"), limit: 100),
        ]
        for command in queries {
            _ = try await context.run(command, in: repo)
            try assertUnchanged(indexes, since: before, after: "\(command)")
        }
    }

    /// Known gap (reported in #94, design decision pending): `git diff` on a path whose content is unchanged but whose
    /// stat data is stale refreshes and rewrites the index, ignoring `--no-optional-locks` and `GIT_OPTIONAL_LOCKS=0`
    /// (Apple Git 2.50.1). Plumbing `git diff-files -p` gives the same patch without writing. This test flags the day
    /// the gap is closed, so the expectation can be removed.
    func testWorktreeDiffOfAStatDirtyFileDoesNotWriteTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        _ = try await context.run(.worktreeDiff(path: GitPath("docs/manual.md"), staged: false))
        XCTExpectFailure("git diff refreshes and writes the index despite --no-optional-locks (#94)") {
            try? assertUnchanged(indexes, since: before, after: "worktreeDiff of a stat-dirty file")
        }
    }

    // MARK: SEC-T13-03

    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables?.remove()
    }

    private func check(_ content: String, as path: String) async throws -> ProcessResult {
        try await RepositoryScript.run(
            "scripts/lint/check-forbidden-apis.sh", ["--stdin", path], stdin: content, executables: executables)
    }

    /// Forbidden calls, assembled at runtime so this file does not trip the check it tests.
    private static let forbidden: [String] = [
        "let child = " + "Pro" + "cess()",
        "let task = NS" + "Task()",
        "posix" + "_spawn(&pid, path, nil, nil, argv, envp)",
        "let pipe = po" + "pen(command, \"r\")",
        "sys" + "tem(command)",
        "let shell = \"/bin/" + "sh\"",
        "let shell = \"/bin/" + "zsh\"",
    ]

    /// SEC-T13-03: the forbidden-API check passes on the repository, rejects process creation and shells outside
    /// `Overgrove/Execution/` (and test support), and accepts the same code in the allowed places.
    func testSECT13_03_ForbiddenAPICheckGuardsProcessCreation() async throws {
        let tree = try await RepositoryScript.run("scripts/lint/check-forbidden-apis.sh", executables: executables)
        XCTAssertEqual(tree.termination, .exited(code: 0), String(decoding: tree.stderr, as: UTF8.self))

        for snippet in Self.forbidden {
            let outside = try await check(snippet, as: "Overgrove/Features/Example.swift")
            XCTAssertEqual(outside.termination, .exited(code: 1), "not rejected: \(snippet)")
            XCTAssertTrue(
                String(decoding: outside.stderr, as: UTF8.self).contains("Overgrove/Features/Example.swift"), snippet)
            for allowed in ["Overgrove/Execution/Example.swift", "OvergroveTests/Support/Example.swift"] {
                let result = try await check(snippet, as: allowed)
                XCTAssertEqual(result.termination, .exited(code: 0), "\(allowed) should allow: \(snippet)")
            }
        }

        // Not over-blocking: SwiftUI's `Font.system(...)` and a `processIdentifier` are fine anywhere.
        let harmless = try await check(
            "let font = Font.system(size: 12)\nlet id = ProcessInfo.processInfo.processIdentifier",
            as: "Overgrove/Features/Example.swift")
        XCTAssertEqual(harmless.termination, .exited(code: 0), String(decoding: harmless.stderr, as: UTF8.self))
    }
}
