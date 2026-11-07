import Foundation
import XCTest

@testable import Overgrove

/// T9 argument injection on the app's real path (security-review.md §2 T9, #93): values that come from a repository
/// (file names, ref names) go through `GitClient` and the parsers, never as raw strings.
///
/// SEC-T9-01 (final argument snapshot) is `GitClientTests.testSECT9_01_FinalArgumentSnapshot`. SEC-T9-02/04 unit
/// checks of the validators are in `GitArgumentsTests`.
final class SECT9InjectionTests: XCTestCase {
    private let inspected = RepoSafetyContext(
        inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)

    private func diffHeaders(_ output: GitOutput) -> [Substring] {
        String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("diff --git ") }
    }

    // MARK: - SEC-T9-03

    /// File names that look like options, pathspec magic, or globs: history, commit patch, and working tree diff
    /// through `GitClient` each cover exactly that file, and nothing writes a stray file.
    func testSECT9_03_HostileFileNamesThroughGitClient() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        let hostile = ["-x", "--output=x", ":(exclude)x", "*", "--", "-n"]
        for name in hostile + ["a.txt"] {
            try repository.write(name, "v1 \(name)\n")
        }
        try await repository.git(["add", "--all"])
        try await repository.git(["commit", "-q", "-m", "one"])
        // Every commit also changes `a.txt`, so a name read as a glob or as `:(exclude)` magic would match a second
        // file and show up as a second diff header (security review of #204).
        for (index, name) in hostile.enumerated() {
            try repository.write(name, "v2 \(name)\n")
            try repository.write("a.txt", "a v\(index + 2)\n")
            try await repository.git(["add", "--", name, "a.txt"])
            try await repository.git(["commit", "-q", "-m", "change \(name)"])
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: repository.root.path).sorted()
        let client = GitClient(environment: repository.environment)

        for name in hostile {
            let path = GitPath(name)
            let history = try await client.run(
                .fileHistory(path: path, limit: 100), in: repository.root, safety: inspected)
            let commits = try LogParser.parseGraph(history.stdout).commits
            XCTAssertEqual(commits.map(\.subject), ["change \(name)", "one"], "history of \(name)")

            let change = try XCTUnwrap(commits.first)
            let patch = try await client.run(
                .commitPatch(change.oid, parent: change.parents.first, path: path), in: repository.root,
                safety: inspected)
            XCTAssertEqual(diffHeaders(patch), ["diff --git a/\(name) b/\(name)"], "commit patch of \(name)")

            try repository.write(name, "v3 \(name)\n")
            try repository.write("a.txt", "a dirty\n")
            let diff = try await client.run(
                .worktreeDiff(path: path, staged: false), in: repository.root, safety: inspected)
            XCTAssertEqual(diffHeaders(diff), ["diff --git a/\(name) b/\(name)"], "working tree diff of \(name)")
            XCTAssertTrue(String(decoding: diff.stdout, as: UTF8.self).contains("+v3 \(name)"), name)
            try await repository.git(["checkout", "-q", "--", name, "a.txt"])
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: repository.root.path).sorted()
        XCTAssertEqual(after, before, "--output=x and friends must not create files")
    }

    /// INT-10 (fixtures.md §5, §9.2): every special file name in the fixture works with diff and file history.
    func testINT10_FixtureSpecialFileNames() async throws {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discover()
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let repo = fixture.repository
        let listing = try await client.run(.configList, in: repo, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        let total = try LogParser.parseGraph(
            try await client.run(.graphPage(skip: 0, limit: 500), in: repo, safety: safety).stdout
        ).commits.count

        let committed = [
            "with space.txt", "dir with space/file.txt", "-dash-leading.txt", "quote\"double.txt",
            "it's.txt", "back\\slash.txt", "café.txt", "emoji-🌲.txt",
        ]
        for name in committed {
            let history = try await client.run(.fileHistory(path: GitPath(name), limit: 500), in: repo, safety: safety)
            let commits = try LogParser.parseGraph(history.stdout).commits
            XCTAssertFalse(commits.isEmpty, "history of \(name)")
            XCTAssertLessThan(commits.count, total, "\(name) must not match every file")

            let file = repo.appendingPathComponent(name)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("appended by INT-10\n".utf8))
            try handle.close()
            let diff = try await client.run(.worktreeDiff(path: GitPath(name), staged: false), in: repo, safety: safety)
            XCTAssertEqual(diffHeaders(diff).count, 1, "diff of \(name)")
        }

        // Untracked special names go through PathValidator and `untrackedPreview` (fixtures.md §4).
        for name in ["한글 파일.txt", "tab\there.txt", "été.txt", "--option-like.txt", "untracked dir/nested.txt"] {
            let file = try XCTUnwrap(PathValidator.worktreeFile(GitPath(name), in: repo), name)
            let preview = try await client.run(.untrackedPreview(file), in: repo, safety: safety)
            XCTAssertEqual(diffHeaders(preview).count, 1, "preview of \(name)")
        }

        // `line⏎break.txt` has a staged change in the fixture (§4).
        let staged = try await client.run(
            .worktreeDiff(path: GitPath("line\nbreak.txt"), staged: true), in: repo, safety: safety)
        XCTAssertEqual(diffHeaders(staged).count, 1, "staged diff of a name with a line feed")
    }

    // MARK: - SEC-T9-02

    /// git itself accepts ref names whose components start with `-`. They come back from `for-each-ref`, and the
    /// parser must drop them so no command can ever receive one.
    func testSECT9_02_OptionLikeRefsFromGitAreNeverUsed() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        let hostile = ["refs/heads/-x", "refs/heads/feat/-y", "refs/tags/--output=z"]
        for ref in hostile {
            try await repository.git(["update-ref", ref, "HEAD"])
        }

        let output = try await GitClient(environment: repository.environment)
            .run(.refs, in: repository.root, safety: inspected)
        let listing = try RefParser.parse(output.stdout)
        let names = listing.branches.map(\.fullName) + listing.tags.map(\.fullName)
        XCTAssertEqual(names.filter { $0.contains("/-") }, [], "\(names)")
        XCTAssertTrue(names.contains("refs/heads/main"), "valid refs are still listed: \(names)")
        XCTAssertEqual(listing.skippedRecords, hostile.count, "the UI warns that refs were skipped")
        for ref in hostile {
            XCTAssertNil(FullRefName(ref), ref)
        }
    }
}
