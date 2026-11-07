import Foundation
import XCTest

@testable import Overgrove

/// S-11 through the real path on the normal fixture (#158): `RepositoryService` loads the overview, then compares a
/// worktree with its base, and one file's patch goes through `PatchParser` into `DiffDocument`.
final class ComparisonIntegrationTests: XCTestCase {
    func testAheadWorktreeAgainstMain() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let services: @Sendable () async throws -> (GitClient, RepositoryService) = { (client, service) }
        _ = try await LiveRepositoryLoader(services: services).load(context.repository)

        let loader = LiveComparisonLoader(services: services)
        let bases = await loader.bases(of: context.repository)
        XCTAssertNotNil(bases.preferred)
        XCTAssertTrue(bases.all.contains(FullRefName("refs/heads/main")!))

        let worktree = GitPath(context.fixture.worktree("wt-ahead").path)
        let result = await loader.compare(
            context.repository, worktree: worktree, base: FullRefName("refs/heads/main"), includeUncommitted: true)
        guard case .success(let comparison) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(comparison.commits.isEmpty, "the ahead worktree has commits main does not")
        XCTAssertFalse(comparison.files.isEmpty)

        var session = ComparisonSession(worktree: worktree, base: comparison.base)
        session.result = .loaded(comparison)
        let model = ComparisonModel(session: session, workingState: nil)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.baseName, "main")
        XCTAssertEqual(model.commits.count, comparison.commits.count)

        let file = try XCTUnwrap(model.files.first)
        let patch = await loader.patch(
            context.repository, worktree: worktree, base: comparison.base, file: file.path,
            originalPath: file.originalPath,
            includeUncommitted: true)
        guard case .patch(let listing) = patch else { return XCTFail("\(patch)") }
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertFalse(
            DiffDocument(listing: listing, path: file.path, source: .init(label: "Committed", kindLetter: "M"))
                .unifiedRows().isEmpty)
    }

    func testUnknownBaseFails() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let services: @Sendable () async throws -> (GitClient, RepositoryService) = { (client, service) }
        _ = try await LiveRepositoryLoader(services: services).load(context.repository)
        let missing = FullRefName("refs/heads/no-such-branch")!
        let result = await LiveComparisonLoader(services: services).compare(
            context.repository, worktree: GitPath(context.fixture.repository.path), base: missing,
            includeUncommitted: false)
        XCTAssertEqual(result, .failure(.baseNotFound(missing)))
    }
}
