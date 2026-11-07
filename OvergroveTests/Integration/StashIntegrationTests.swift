import Foundation
import XCTest

@testable import Overgrove

/// Stashes through the real path on the normal fixture (#71, fixtures.md §4: `stash@{0}` made with `-u`, `stash@{1}`
/// tracked files only): the overview lists them with parents; `LiveStashLoader` reads files and patches by OID.
final class StashIntegrationTests: XCTestCase {
    func testFixtureStashes() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let listing = try await LiveRepositoryLoader(services: { (client, service) }).load(context.repository)
        XCTAssertEqual(listing.stashes.map(\.refName), ["stash@{0}", "stash@{1}"])
        let (withUntracked, trackedOnly) = (listing.stashes[0], listing.stashes[1])
        XCTAssertTrue(withUntracked.includesUntracked)
        XCTAssertFalse(trackedOnly.includesUntracked)
        XCTAssertTrue(trackedOnly.includesIndex)
        XCTAssertNotNil(trackedOnly.baseCommit)

        let loader = LiveStashLoader(client: { client })
        guard case .files(let detail) = await loader.files(of: withUntracked, in: context.repository, worktree: nil)
        else { return XCTFail("no files") }
        XCTAssertTrue(detail.files.contains { $0.path.display == "stash-untracked.txt" && $0.isFromUntracked })
        XCTAssertTrue(detail.files.contains { !$0.isFromUntracked })

        for file in detail.files {
            let patch = await loader.patch(of: withUntracked, file: file, in: context.repository, worktree: nil)
            guard case .patch(let parsed) = patch else { return XCTFail("\(file.path.display): \(patch)") }
            XCTAssertEqual(parsed.files.count, 1, file.path.display)
        }

        guard case .files(let tracked) = await loader.files(of: trackedOnly, in: context.repository, worktree: nil)
        else { return XCTFail("no files") }
        XCTAssertEqual(tracked.files.map(\.path.display), ["src/stash-target.txt"])
        XCTAssertFalse(tracked.files[0].isFromUntracked)
    }

    /// SEC-T15-09: a hand-written `refs/stash` entry that is not a stash commit (a root commit, no parents) keeps the
    /// overview loading; that entry just has no base or includes (security review of #71).
    func testSECT15_09_NonStashReflogEntryKeepsTheOverviewLoading() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try repository.write("README", "x\n")
        try await repository.git(["add", "README"])
        try await repository.git(["commit", "-q", "-m", "root"])
        try await repository.git(["update-ref", "-m", "On main: fake", "--create-reflog", "refs/stash", "HEAD"])

        let root = try XCTUnwrap(PathValidator.canonical(repository.root))
        let target = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let client = GitClient(environment: repository.environment)
        let service = RepositoryService(client: client)
        let listing = try await LiveRepositoryLoader(services: { (client, service) }).load(target)
        XCTAssertEqual(listing.entries.count, 1, "the worktree list still loads")
        XCTAssertEqual(listing.stashes.count, 1)
        XCTAssertEqual(listing.stashes.first?.parents, [])
        XCTAssertNil(listing.stashes.first?.baseCommit)
    }
}
