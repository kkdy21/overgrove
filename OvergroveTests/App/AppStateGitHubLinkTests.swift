import Foundation
import XCTest

@testable import Overgrove

/// Open on GitHub in the row menus (#398): only with a github.com remote, for its own remote-tracking branches.
@MainActor
final class AppStateGitHubLinkTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "overgrove-github-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func state(github: GitHubRepository?, remote: String?) async -> AppState {
        let mock = WorktreeListing.entry(
            "/tmp/dev/api", branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        var listing = WorktreeListing(entries: [mock], isPartial: false)
        if let github, let remote {
            listing.remotes = [.init(name: remote, url: "https://github.com/\(github.owner)/\(github.name).git")]
        }
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), graphLoader: SampleGraphLoader(),
            commitLoader: StubCommitLoader())
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                    commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false), owner: nil))
        state.reload()
        await state.loadTask?.value
        return state
    }

    func testLinksNeedAGitHubRemote() async throws {
        let oid = ObjectID(String(repeating: "b", count: 40))!
        let with = await state(github: GitHubRepository(owner: "acme", name: "api"), remote: "upstream")
        let actions = with.rowMenuActions
        XCTAssertEqual(actions.gitHubCommitURL(oid)?.absoluteString, "https://github.com/acme/api/commit/" + oid.hex)
        XCTAssertEqual(
            actions.gitHubBranchURL("refs/remotes/upstream/main")?.absoluteString,
            "https://github.com/acme/api/tree/main")
        XCTAssertNil(actions.gitHubBranchURL("refs/remotes/origin/main"), "a branch of another remote")
        XCTAssertEqual(
            actions.gitHubFileURL(oid, GitPath("src/a.swift"))?.absoluteString,
            "https://github.com/acme/api/blob/\(oid.hex)/src/a.swift")

        let without = await state(github: nil, remote: nil)
        XCTAssertNil(without.rowMenuActions.gitHubCommitURL(oid))
    }
}
