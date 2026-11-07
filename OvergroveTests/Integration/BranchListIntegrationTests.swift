import Foundation
import XCTest

@testable import Overgrove

/// LOCAL and REMOTE through the real path on the normal fixture (#72): the overview's refs and configured remotes
/// reach `BranchListModel`.
final class BranchListIntegrationTests: XCTestCase {
    func testFixtureBranches() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let client = context.client
        let service = RepositoryService(client: client)
        let listing = try await LiveRepositoryLoader(services: { (client, service) }).load(context.repository)
        let refs = try XCTUnwrap(listing.refs)
        XCTAssertTrue(listing.remoteNames.contains("origin"))

        let model = BranchListModel(
            refs: refs, checkedOut: Set(listing.entries.compactMap(\.worktree.branch)),
            remoteNames: listing.remoteNames)
        XCTAssertGreaterThan(model.localCount, 1)
        guard case .branch(let first) = model.local.first else { return XCTFail("\(model.local)") }
        XCTAssertEqual(first.id, "refs/heads/main", "the default branch is pinned first")
        XCTAssertTrue(first.isDefault)
        XCTAssertTrue(first.isCheckedOut, "main is checked out in the main worktree")

        func allRows(_ nodes: [BranchNode]) -> [BranchRow] {
            nodes.flatMap { node -> [BranchRow] in
                switch node {
                case .branch(let row): [row]
                case .folder(_, _, _, let children): allRows(children)
                }
            }
        }
        // INT: `feat/ahead` is ahead of its upstream; the fixture's tracked branches show their counts.
        let ahead = try XCTUnwrap(allRows(model.local).first { $0.id == "refs/heads/feat/ahead" })
        XCTAssertGreaterThan(ahead.ahead, 0)
        XCTAssertTrue(ahead.isCheckedOut, "checked out in wt-ahead")
        XCTAssertTrue(model.remote.contains { $0.id == "remote:origin" })
        XCTAssertFalse(allRows(model.remote).contains { $0.id.hasSuffix("/HEAD") })
    }
}
