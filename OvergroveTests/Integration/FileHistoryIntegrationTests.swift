import Foundation
import XCTest

@testable import Overgrove

/// S-09's real path (#70): verified worktree → its inspection → `fileHistory` → `LogParser.parseFileHistory`.
final class FileHistoryIntegrationTests: XCTestCase {
    private func loader(_ fixture: FixtureRepo) async throws -> (LiveFileHistoryLoader, FileHistoryTarget) {
        let environment = try await GitEnvironment.discover(parentEnvironment: fixture.environment)
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let root = try XCTUnwrap(PathValidator.canonical(fixture.repository))
        let target = FileHistoryTarget(
            repository: Repository(
                rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
            worktree: Worktree(
                path: GitPath(root.path), head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
                isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil),
            head: nil, path: GitPath("docs/manual.md"))
        return (LiveFileHistoryLoader(client: { client }), target)
    }

    /// INT-09 through the loader: the rename is followed, and pages join without gaps or repeats (git's `--skip` with
    /// `--follow` repeated the rename commit, which is why the loader does not use it).
    func testFollowsTheRenameAndPages() async throws {
        let fixture = try await makeFixture()
        let (loader, target) = try await loader(fixture)
        guard case .page(let all) = await loader.page(target, skip: 0, limit: 500) else {
            return XCTFail("no history")
        }
        XCTAssertEqual(all.entries.map(\.commit.oid.short), ["0893a1a", "c46c37d", "4202323", "0c53f8b"])
        XCTAssertEqual(all.entries.compactMap(\.originalPath?.display), ["docs/guide.md"])
        XCTAssertTrue(all.entries.allSatisfy(\.hasStat))

        guard case .page(let first) = await loader.page(target, skip: 0, limit: 2) else {
            return XCTFail("no first page")
        }
        guard case .page(let second) = await loader.page(target, skip: 2, limit: 2) else {
            return XCTFail("no second page")
        }
        XCTAssertEqual(first.entries + second.entries, all.entries)

        // Follow off: only the commits under the current name.
        var plain = target
        plain.follow = false
        guard case .page(let unfollowed) = await loader.page(plain, skip: 0, limit: 500)
        else { return XCTFail("no history") }
        XCTAssertLessThan(unfollowed.entries.count, all.entries.count)
    }

    /// On the malicious fixture the history path (verified inspection, then `log --numstat` with that worktree's
    /// safety) runs none of the repository's payloads.
    func testMaliciousFixtureRunsNoPayloads() async throws {
        let fixture = try await makeFixture(malicious: true)
        let (loader, target) = try await loader(fixture)
        try fixture.clearCanaries()
        for path in ["src/unstaged-modified.txt", "README.md"] {
            let file = FileHistoryTarget(
                repository: target.repository, worktree: target.worktree, head: nil, path: GitPath(path))
            _ = await loader.page(file, skip: 0, limit: 50)
        }
        XCTAssertEqual(fixture.canaries(), [])
    }
}
