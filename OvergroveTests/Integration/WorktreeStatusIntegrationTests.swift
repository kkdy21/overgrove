import Foundation
import XCTest

@testable import Overgrove

/// Worktree list and per-worktree status on the normal fixture (docs/testing/fixtures.md §3–§4, §7; scope-mvp D1, D2).
///
/// Every command goes through `GitClient` with the `RepoSafetyContext` from `RepoConfigInspector`, exactly as the app
/// runs it, and the parsed models are compared with the documented fixture facts.
final class WorktreeStatusIntegrationTests: XCTestCase {
    private static let linkedWorktrees = [
        "wt-ahead", "wt-behind", "wt-conflict", "wt-detached", "wt-diverged", "wt-locked", "wt-no-upstream",
    ]

    /// INT-01, INT-14, INT-15, INT-16 (D1): all worktrees are listed with their kind.
    func testINT01_WorktreeListHasEveryKind() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let fixture = context.fixture
        let worktrees = try await context.worktrees()

        XCTAssertEqual(worktrees.count, 9)
        XCTAssertEqual(worktrees.filter(\.isMain).map(\.path.display), [fixture.repository.path])
        XCTAssertEqual(worktrees.first?.branch, "refs/heads/main", "the main worktree comes first")
        let expectedPaths =
            [fixture.repository.path]
            + (Self.linkedWorktrees + ["wt-prunable"]).map {
                fixture.worktree($0).path
            }
        XCTAssertEqual(Set(worktrees.map(\.path.display)), Set(expectedPaths))

        func worktree(_ name: String) throws -> Worktree {
            try XCTUnwrap(worktrees.first { $0.path.display == fixture.worktree(name).path }, name)
        }
        XCTAssertEqual(try worktree("wt-ahead").branchShortName, "feat/ahead")

        // INT-15: locked, with its reason.
        XCTAssertEqual(worktrees.filter(\.isLocked).count, 1)
        XCTAssertEqual(try worktree("wt-locked").lock, .locked(reason: "fixture: locked on purpose"))

        // INT-16: detached at main~2.
        XCTAssertEqual(worktrees.filter(\.isDetached).count, 1)
        let detached = try worktree("wt-detached")
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.head?.short, "c46c37d")

        // INT-14: prunable; its folder is gone, and querying it reports that instead of running in another folder.
        XCTAssertEqual(worktrees.filter(\.isPrunable).count, 1)
        let prunable = try worktree("wt-prunable")
        XCTAssertEqual(prunable.prunableReason, "gitdir file points to non-existent location")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prunable.path.display))
        do {
            _ = try await context.status(of: fixture.worktree("wt-prunable"))
            XCTFail("status of a missing worktree must fail")
        } catch GitError.worktreeMissing(let path) {
            XCTAssertEqual(path, fixture.worktree("wt-prunable").path)
        }

        // Same set of paths as stock git reports without -z.
        let plain = try await context.plainGit(["worktree", "list", "--porcelain"], in: fixture.repository)
        let plainPaths = plain.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map {
            String($0.dropFirst("worktree ".count))
        }
        XCTAssertEqual(Set(plainPaths), Set(worktrees.map(\.path.display)))
    }

    /// INT-02, INT-17, INT-18 (D2): the main worktree's status matches fixtures.md §4 file by file.
    func testINT02_MainWorktreeStatusMatchesTheFixtureTable() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let state = try await context.status(of: context.fixture.repository)

        XCTAssertEqual(StatusCounts(state), StatusCounts(staged: 6, unstaged: 8, untracked: 6, conflicted: 0))
        XCTAssertEqual(state.head, .branch("main"))
        XCTAssertEqual(state.headCommit?.short, "e4bd61e")
        XCTAssertEqual(state.upstream, .tracking(upstream: "origin/main", ahead: 1, behind: 0))
        XCTAssertEqual(state.stashCount, 2)

        func changes(_ list: [FileChange]) -> [String: FileChange.Status] {
            Dictionary(uniqueKeysWithValues: list.map { ($0.path.display, $0.status) })
        }
        XCTAssertEqual(
            changes(state.staged),
            [
                "src/staged-modified.txt": .modified, "src/staged-added.txt": .added,
                "src/staged-deleted.txt": .deleted, "src/new-name.txt": .renamed(score: 100),
                "src/staged-and-unstaged.txt": .modified, "line\nbreak.txt": .modified,
            ])
        XCTAssertEqual(
            state.staged.first { $0.path.display == "src/new-name.txt" }?.originalPath?.display, "src/old-name.txt")
        // INT-17: intent-to-add `.A`, type change `.T`, and a mode-only change `.M`.
        XCTAssertEqual(
            changes(state.unstaged),
            [
                "src/staged-and-unstaged.txt": .modified, "src/unstaged-modified.txt": .modified,
                "src/unstaged-deleted.txt": .deleted, "src/typechange": .typeChanged, "scripts/run.sh": .modified,
                "intent.txt": .added, "with space.txt": .modified, "-dash-leading.txt": .modified,
            ])
        XCTAssertEqual(
            Set(state.untracked.map(\.path.display)),
            [
                "untracked.txt", "untracked dir/nested.txt", "tab\there.txt", "\u{E9}t\u{E9}.txt", "한글 파일.txt",
                "--option-like.txt",
            ])
        // git prints the NFD file name as NFC (core.precomposeunicode, fixtures.md §5).
        XCTAssertTrue(state.untracked.contains { $0.path.raw == Data("\u{E9}t\u{E9}.txt".utf8) })
        XCTAssertTrue(state.untracked.allSatisfy { $0.status == .untracked })
        // INT-18: ignored files are not listed anywhere.
        let allPaths = (state.staged + state.unstaged + state.untracked + state.conflicted).map(\.path.display)
        XCTAssertFalse(allPaths.contains("debug.log"))
    }

    /// INT-03: the merge conflict in `wt-conflict`.
    func testINT03_ConflictWorktree() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let state = try await context.status(of: context.fixture.worktree("wt-conflict"))
        XCTAssertEqual(state.head, .branch("fix/conflict"))
        XCTAssertEqual(state.upstream, .none)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: state.conflicted.map { ($0.path.display, $0.status) }),
            [
                "conflict.txt": .conflicted(.bothModified), "both-added.txt": .conflicted(.bothAdded),
                "deleted-by-us.txt": .conflicted(.deletedByUs),
            ])
        XCTAssertEqual(StatusCounts(state), StatusCounts(conflicted: 3))
    }

    /// D2 and INT-04, INT-16: every worktree's status counts match both the fixture table and stock git, and
    /// ahead/behind matches the branch table (§2.2) and `rev-list --left-right --count`.
    func testD2_EveryWorktreeMatchesStockGitAndAheadBehind() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let fixture = context.fixture
        let expected: [(name: String, counts: StatusCounts, head: WorkingState.Head, upstream: UpstreamStatus)] = [
            ("repo", .init(staged: 6, unstaged: 8, untracked: 6), .branch("main"), tracking("main", 1, 0)),
            ("wt-ahead", .init(), .branch("feat/ahead"), tracking("feat/ahead", 2, 0)),
            ("wt-behind", .init(), .branch("feat/behind"), tracking("feat/behind", 0, 2)),
            ("wt-conflict", .init(conflicted: 3), .branch("fix/conflict"), .none),
            ("wt-detached", .init(), .detached, .none),
            ("wt-diverged", .init(untracked: 1), .branch("feat/diverged"), tracking("feat/diverged", 1, 1)),
            ("wt-locked", .init(), .branch("chore/locked"), .none),
            ("wt-no-upstream", .init(), .branch("feat/no-upstream"), .none),
        ]
        for row in expected {
            let directory = row.name == "repo" ? fixture.repository : fixture.worktree(row.name)
            let state = try await context.status(of: directory)
            XCTAssertEqual(StatusCounts(state), row.counts, row.name)
            XCTAssertEqual(state.head, row.head, row.name)
            XCTAssertEqual(state.upstream, row.upstream, row.name)

            let plain = try await context.plainGit(["status", "--porcelain", "--untracked-files=all"], in: directory)
            XCTAssertEqual(StatusCounts(state), StatusCounts(porcelainV1: plain), "\(row.name) vs stock git")

            guard case .branch(let branch) = row.head, case .tracking(let upstream, _, _) = row.upstream else {
                continue
            }
            let counts = try RevListParser.parse(
                try await context.run(
                    .aheadBehind(
                        local: try XCTUnwrap(FullRefName("refs/heads/\(branch)")),
                        upstream: try XCTUnwrap(FullRefName("refs/remotes/\(upstream)")))))
            XCTAssertEqual(counts.ahead, state.upstream.ahead, "\(row.name) rev-list ahead")
            XCTAssertEqual(counts.behind, state.upstream.behind, "\(row.name) rev-list behind")
        }
        let diverged = try await context.status(of: fixture.worktree("wt-diverged"))
        XCTAssertEqual(diverged.untracked.map(\.path.display), ["notes.txt"])
        let detached = try await context.status(of: fixture.worktree("wt-detached"))
        XCTAssertEqual(detached.headCommit?.short, "c46c37d")
    }

    private func tracking(_ branch: String, _ ahead: Int, _ behind: Int) -> UpstreamStatus {
        .tracking(upstream: "origin/\(branch)", ahead: ahead, behind: behind)
    }
}
