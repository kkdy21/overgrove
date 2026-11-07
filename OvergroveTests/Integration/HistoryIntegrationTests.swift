import Foundation
import XCTest

@testable import Overgrove

/// Stashes, commit graph, commit details, file history, refs and fetch on the normal fixture
/// (docs/testing/fixtures.md §2, §6, §7; scope-mvp D3, D4).
final class HistoryIntegrationTests: XCTestCase {
    /// INT-05, INT-06 (D3): both stashes in order, with branch, message, and file summary including untracked files.
    func testINT05_StashesWithFileSummaries() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let stashes = try StashParser.parse(try await context.run(.stashList)).stashes

        XCTAssertEqual(stashes.map(\.index), [0, 1])
        XCTAssertEqual(stashes.map(\.branch), ["feat/ahead", "main"])
        XCTAssertEqual(stashes.map(\.message), ["fixture: with untracked", "fixture: tracked change"])
        XCTAssertEqual(stashes.map(\.refName), ["stash@{0}", "stash@{1}"])

        // stash@{0} was made with -u: its untracked files are the tree of its third parent (parsing-spec §8.2).
        let withUntracked = stashes[0]
        let meta = try LogParser.parseCommitMeta(try await context.run(.commitMeta(withUntracked.oid)))
        XCTAssertEqual(meta.parents.count, 3, "stash commit, index commit, untracked commit")
        let untrackedTree = try NumstatParser.parseCommitFiles(
            try await context.run(.commitFiles(meta.parents[2], firstParent: nil)))
        let files = try NumstatParser.parseStashFiles(
            try await context.run(.stashFiles(withUntracked.oid)),
            untrackedPaths: Set(untrackedTree.files.map(\.path))
        ).files
        XCTAssertEqual(
            files.map { Summary($0) },
            [
                Summary(path: "branches/feat-ahead.txt", added: 1, deleted: 0, isFromUntracked: false),
                Summary(path: "stash-untracked.txt", added: 1, deleted: 0, isFromUntracked: true),
            ])

        // INT-06: stash@{1} changes one tracked file.
        let tracked = try NumstatParser.parseStashFiles(try await context.run(.stashFiles(stashes[1].oid))).files
        XCTAssertEqual(
            tracked.map { Summary($0) },
            [Summary(path: "src/stash-target.txt", added: 1, deleted: 0, isFromUntracked: false)])
    }

    /// INT-07, INT-08, INT-09: the first graph page excludes stash commits; commit details show binary and renamed
    /// files; the history of a renamed file follows the rename.
    func testINT07_GraphCommitDetailsAndFileHistory() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let graph = try await context.graph()
        let stashes = try StashParser.parse(try await context.run(.stashList)).stashes

        // INT-07
        XCTAssertEqual(graph.count, 21, "branches, remotes, tags, worktree HEADs; no stash")
        XCTAssertTrue(Set(graph.map(\.oid)).isDisjoint(with: stashes.map(\.oid)), "no stash commits in the graph")
        XCTAssertEqual(graph.filter(\.isMerge).map(\.oid.short), ["0cbcd45"])
        let merge = try context.commit("0cbcd45", in: graph)
        XCTAssertEqual(merge.parents.map(\.short), ["337f477", "b134225"])
        XCTAssertEqual(try context.commit("0c53f8b", in: graph).parents, [], "root commit")
        XCTAssertEqual(try context.commit("e4bd61e", in: graph).subject, "feat: local-only change on main")
        XCTAssertEqual(Set(graph.map(\.oid)).count, graph.count, "no duplicates")

        // INT-08: binary and rename in commit details.
        let binaryCommit = try context.commit("4202323", in: graph)
        let binaryFiles = try NumstatParser.parseCommitFiles(
            try await context.run(.commitFiles(binaryCommit.oid, firstParent: nil))
        ).files
        let binary = try XCTUnwrap(binaryFiles.first { $0.path.display == "assets/binary.bin" })
        XCTAssertTrue(binary.isBinary)
        let renameCommit = try context.commit("c46c37d", in: graph)
        let renameFiles = try NumstatParser.parseCommitFiles(
            try await context.run(.commitFiles(renameCommit.oid, firstParent: nil))
        ).files
        let renamed = try XCTUnwrap(renameFiles.first { $0.path.display == "docs/manual.md" })
        XCTAssertEqual(renamed.originalPath?.display, "docs/guide.md")
        guard case .renamed = renamed.status else {
            return XCTFail("expected a rename, got \(String(describing: renamed.status))")
        }

        // INT-09: history of docs/manual.md follows the rename back to the root commit.
        let history = try LogParser.parseFileHistory(
            try await context.run(
                .fileHistory(path: GitPath("docs/manual.md"), limit: 100), in: context.fixture.repository),
            path: GitPath("docs/manual.md")
        ).entries
        XCTAssertEqual(history.map(\.commit.oid.short), ["0893a1a", "c46c37d", "4202323", "0c53f8b"])
        // The rename shows both names, and older commits carry the old path (#70).
        let renameStep = try XCTUnwrap(history.first { $0.originalPath != nil })
        XCTAssertEqual(renameStep.originalPath?.display, "docs/guide.md")
        XCTAssertEqual(history.last?.path.display, "docs/guide.md")
    }

    /// INT-11: local branches, remote-tracking refs, both tags (annotated one peeled) and the `upstream/HEAD` symref.
    func testINT11_Refs() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let refs = try await context.refs()
        XCTAssertEqual(refs.skippedRecords, 0)

        let locals = refs.branches.filter { $0.kind == .local }
        XCTAssertEqual(
            Set(locals.map(\.shortName)),
            [
                "main", "feat/ahead", "feat/behind", "feat/diverged", "feat/no-upstream", "fix/conflict",
                "chore/locked", "spike/prunable", "feat/merged", "topic/conflict-other",
            ])
        XCTAssertEqual(locals.filter(\.isHead).map(\.shortName), ["main"])
        let main = try XCTUnwrap(locals.first { $0.shortName == "main" })
        // for-each-ref reports the full upstream ref name; status reports `origin/main` (UpstreamStatus docs).
        XCTAssertEqual(main.upstreamStatus, .tracking(upstream: "refs/remotes/origin/main", ahead: 1, behind: 0))
        XCTAssertEqual(locals.first { $0.shortName == "feat/no-upstream" }?.upstreamStatus, UpstreamStatus.none)

        let remotes = refs.branches.filter { $0.kind != .local }
        let upstreamMain = try XCTUnwrap(remotes.first { $0.fullName == "refs/remotes/upstream/main" })
        XCTAssertEqual(upstreamMain.target.short, "5606cda")
        XCTAssertEqual(
            remotes.first { $0.fullName == "refs/remotes/upstream/HEAD" }?.symbolicTarget,
            "refs/remotes/upstream/main")
        XCTAssertFalse(remotes.contains { $0.fullName == "refs/remotes/origin/HEAD" })
        XCTAssertFalse(remotes.contains { $0.fullName == "refs/remotes/origin/feat/remote-only" }, "only after fetch")

        XCTAssertEqual(Set(refs.tags.map(\.shortName)), ["v0.0.1", "light-tag"])
        let annotated = try XCTUnwrap(refs.tags.first { $0.shortName == "v0.0.1" })
        XCTAssertEqual(annotated.peeledTarget?.short, "337f477")
        XCTAssertEqual(annotated.commit.short, "337f477")
        let lightweight = try XCTUnwrap(refs.tags.first { $0.shortName == "light-tag" })
        XCTAssertNil(lightweight.peeledTarget)
        XCTAssertEqual(lightweight.commit.short, "4202323")
    }

    /// INT-12, D4: fetch adds `origin/feat/remote-only`, and afterwards ahead/behind agrees across status
    /// (`branch.ab`), `for-each-ref` (`upstream:track`) and `rev-list`. Each source names the upstream in its own
    /// documented form: `origin/main` from status, `refs/remotes/origin/main` from for-each-ref.
    func testINT12_FetchThenAheadBehindAgrees() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let fixture = context.fixture
        let origin = try XCTUnwrap(RemoteName("origin"))
        let output = try await context.client.fetch(
            .fetch(remote: origin), in: context.repository, safety: context.safety)
        XCTAssertFalse(output.isTruncated)

        let refs = try await context.refs()
        XCTAssertTrue(refs.branches.contains { $0.fullName == "refs/remotes/origin/feat/remote-only" })

        let worktrees: [(directory: URL, branch: String, ahead: Int, behind: Int)] = [
            (fixture.repository, "main", 1, 0),
            (fixture.worktree("wt-ahead"), "feat/ahead", 2, 0),
            (fixture.worktree("wt-behind"), "feat/behind", 0, 2),
            (fixture.worktree("wt-diverged"), "feat/diverged", 1, 1),
        ]
        for row in worktrees {
            let state = try await context.status(of: row.directory)
            XCTAssertEqual(
                state.upstream,
                .tracking(upstream: "origin/\(row.branch)", ahead: row.ahead, behind: row.behind),
                "\(row.branch) branch.ab")
            let branch = try XCTUnwrap(refs.branches.first { $0.fullName == "refs/heads/\(row.branch)" })
            XCTAssertEqual(
                branch.upstreamStatus,
                .tracking(upstream: "refs/remotes/origin/\(row.branch)", ahead: row.ahead, behind: row.behind),
                "\(row.branch) upstream:track")
            let counts = try RevListParser.parse(
                try await context.run(
                    .aheadBehind(
                        local: try XCTUnwrap(FullRefName("refs/heads/\(row.branch)")),
                        upstream: try XCTUnwrap(FullRefName("refs/remotes/origin/\(row.branch)")))))
            XCTAssertEqual(counts, RevListParser.Counts(behind: row.behind, ahead: row.ahead), "\(row.branch) rev-list")
        }
    }

    /// INT-20: the git the app runs parses as a supported version.
    func testINT20_InstalledGitVersionIsSupported() async throws {
        let environment = try await GitEnvironment.discover()
        let client = GitClient(environment: environment)
        let output = try await client.run(.version, in: nil, safety: .preInspection)
        let version = try VersionParser.parse(output.stdout)
        XCTAssertTrue(version.isSupported, "\(version)")
        XCTAssertEqual(version, environment.version)
    }
}

/// The parts of a `FileStat` the fixture documents, in a form that prints readably on failure.
private struct Summary: Equatable {
    let path: String
    let added: Int?
    let deleted: Int?
    let isFromUntracked: Bool

    init(path: String, added: Int?, deleted: Int?, isFromUntracked: Bool) {
        self.path = path
        self.added = added
        self.deleted = deleted
        self.isFromUntracked = isFromUntracked
    }

    init(_ stat: FileStat) {
        self.init(
            path: stat.path.display, added: stat.added, deleted: stat.deleted, isFromUntracked: stat.isFromUntracked)
    }
}
