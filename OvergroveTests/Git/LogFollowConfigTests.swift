import Foundation
import XCTest

@testable import Overgrove

/// #310: a repository's own `log.follow=true` made git follow renames even when S-09's "Follow renames" was off,
/// because `fileHistory(follow: false)` only leaves `--follow` out. The common argument `-c log.follow=false` pins it;
/// an explicit `--follow` still follows.
///
/// History: `a.txt` is added, renamed to `b.txt`, then edited. Following `b.txt` reaches all three commits; not
/// following it stops at the rename.
final class LogFollowConfigTests: XCTestCase {
    private var repository: GitTestRepository!

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "one\ntwo\nthree\nfour\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "add a"])
        try await repository.git(["mv", "a.txt", "b.txt"])
        try await repository.git(["commit", "-q", "-m", "rename to b"])
        try repository.write("b.txt", "one\ntwo\nthree\nfour\nfive\n")
        try await repository.git(["commit", "-q", "-am", "edit b"])
        try await repository.git(["config", "log.follow", "true"])
    }

    override func tearDown() {
        repository?.remove()
    }

    private func history(follow: Bool) async throws -> [String] {
        let client = GitClient(environment: repository.environment)
        let config = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout)).safetyContext)
        let output = try await client.run(
            .fileHistory(path: GitPath("b.txt"), follow: follow, limit: 10), in: repository.root, safety: safety)
        return try LogParser.parseFileHistory(output.stdout, path: GitPath("b.txt")).entries.map(\.commit.subject)
    }

    /// Control: plain git (none of the app's arguments) honours the repository's `log.follow` with one pathspec.
    func testControlPlainGitFollowsBecauseOfTheRepositorySetting() async throws {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable,
                arguments: ["log", "--format=%s", "--", "b.txt"],
                environment: GitEnvironment.environment(parent: ProcessInfo.processInfo.environment),
                currentDirectory: repository.root, limits: .query))
        let subjects = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(subjects, ["edit b", "rename to b", "add a"], "git followed the rename on its own")
    }

    func testFollowRenamesOffStopsAtTheRenameDespiteTheRepositorySetting() async throws {
        let subjects = try await history(follow: false)
        XCTAssertEqual(subjects, ["edit b", "rename to b"])
    }

    func testFollowRenamesOnStillFollows() async throws {
        let subjects = try await history(follow: true)
        XCTAssertEqual(subjects, ["edit b", "rename to b", "add a"])
    }
}
