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

    private func state(
        github: GitHubRepository?, remote: String?, remotes: [String: GitHubRepository] = [:], branches: [Branch] = []
    ) async -> AppState {
        let mock = WorktreeListing.entry(
            "/tmp/dev/api", branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        var listing = WorktreeListing(entries: [mock], isPartial: false)
        var all = remotes
        if let github, let remote { all[remote] = github }
        listing.remotes = all.sorted { $0.key < $1.key }.map {
            WorktreeListing.Remote(
                name: $0.key, url: "https://\($0.value.host.name)/\($0.value.owner)/\($0.value.name).git")
        }
        listing.refs = RefParser.Listing(branches: branches, tags: [], isPartial: false, skippedRecords: 0)
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
            actions.gitHubFileURL(oid, GitPath("src/a.swift"))?.absoluteString,
            "https://github.com/acme/api/blob/\(oid.hex)/src/a.swift")

        let without = await state(github: nil, remote: nil)
        XCTAssertNil(without.rowMenuActions.gitHubCommitURL(oid))
    }

    /// SEC-T14-470-1: commit and file links come only from remotes this load inspected for this repository, like
    /// branch links (#406): with the listing still on screen but no verified source (a cached paint), or a source of
    /// another repository, there is no link.
    func testSECT14_470_1_CommitAndFileLinksNeedThisLoadsVerifiedRemotes() async throws {
        let oid = ObjectID(String(repeating: "c", count: 40))!
        let state = await state(github: GitHubRepository(owner: "acme", name: "api"), remote: "origin")
        XCTAssertNotNil(state.rowMenuActions.gitHubCommitURL(oid))
        let verified = try XCTUnwrap(state.verifiedGitHubSource)

        state.verifiedGitHubSource = nil
        guard case .loaded = state.worktreeList else { return XCTFail("the listing stays on screen") }
        XCTAssertNil(state.rowMenuActions.gitHubCommitURL(oid))
        XCTAssertNil(state.rowMenuActions.gitHubFileURL(oid, GitPath("src/a.swift")))

        let other = Repository(
            rootURL: URL(fileURLWithPath: "/tmp/dev/other"),
            commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/other/.git"), isBare: false)
        state.verifiedGitHubSource = VerifiedGitHubSource(
            repository: other, remotes: verified.remotes, branches: verified.branches)
        XCTAssertNil(state.rowMenuActions.gitHubCommitURL(oid), "another repository's remotes")

        state.verifiedGitHubSource = verified
        XCTAssertNotNil(state.rowMenuActions.gitHubCommitURL(oid))
    }

    /// SEC-T14-470-1: a failed load drops the remotes the repository was last inspected with.
    func testSECT14_470_1_AFailedLoadDropsTheVerifiedRemotes() async throws {
        let mock = WorktreeListing.entry(
            "/tmp/dev/api", branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        var listing = WorktreeListing(entries: [mock], isPartial: false)
        listing.remotes = [WorktreeListing.Remote(name: "origin", url: "https://github.com/acme/api.git")]
        let loader = FailingRepositoryLoader([listing, nil], failures: [.blocked(reason: "test")])
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader())
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                    commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false), owner: nil))
        state.reload()
        await state.loadTask?.value
        XCTAssertNotNil(state.verifiedGitHubSource)
        state.reload()
        await state.loadTask?.value
        XCTAssertNil(state.verifiedGitHubSource)
    }

    private func rows(_ nodes: [BranchNode]) -> [BranchRow] {
        nodes.flatMap { node -> [BranchRow] in
            switch node {
            case .branch(let row): [row]
            case .folder(_, _, _, let children): rows(children)
            }
        }
    }

    /// #406, the fork flow: `origin` is my fork and the issue panel uses `upstream`. A local branch tracking `origin`
    /// and `origin`'s remote-tracking rows open the fork; `upstream`'s rows open the original; a remote on another
    /// host has no link.
    func testBranchesOpenInTheirTrackedRemotesRepository() async throws {
        let fork = GitHubRepository(owner: "me", name: "api")!
        let original = GitHubRepository(owner: "acme", name: "api")!
        let oid = ObjectID(String(repeating: "c", count: 40))!
        func branch(_ name: String, kind: Branch.Kind, remote: String? = nil, merge: String? = nil) -> Branch {
            Branch(
                fullName: name, kind: kind, target: oid,
                upstreamStatus: remote == nil ? .none : .tracking(upstream: "refs/remotes/x", ahead: 0, behind: 0),
                isHead: false, committerDate: nil, symbolicTarget: nil, upstreamRemote: remote,
                upstreamRemoteRef: merge)
        }
        let state = await state(
            github: original, remote: "upstream", remotes: ["origin": fork, "upstream": original],
            branches: [
                branch("refs/heads/feat/x", kind: .local, remote: "origin", merge: "refs/heads/feat/x"),
                branch("refs/heads/main", kind: .local, remote: "upstream", merge: "refs/heads/main"),
                branch("refs/heads/lab", kind: .local, remote: "gitlab", merge: "refs/heads/lab"),
                branch("refs/remotes/origin/feat/x", kind: .remote(remote: "origin")),
                branch("refs/remotes/upstream/main", kind: .remote(remote: "upstream")),
            ])
        let model = try XCTUnwrap(state.branchListModel)
        let all = rows(model.local) + rows(model.remote)
        let actions = state.rowMenuActions
        func url(_ id: String) -> String? {
            all.first { $0.id == id }?.gitHubTarget.flatMap(actions.gitHubBranchURL)?.absoluteString
        }
        XCTAssertEqual(url("refs/heads/feat/x"), "https://github.com/me/api/tree/feat/x", "tracks the fork")
        XCTAssertEqual(url("refs/heads/main"), "https://github.com/acme/api/tree/main")
        XCTAssertNil(url("refs/heads/lab"), "a remote that is not on github.com")
        XCTAssertEqual(url("refs/remotes/origin/feat/x"), "https://github.com/me/api/tree/feat/x")
        XCTAssertEqual(url("refs/remotes/upstream/main"), "https://github.com/acme/api/tree/main")

        // A cached paint (not this load's inspection) gives no links.
        let cached = try XCTUnwrap(
            AppState.branchModel(
                {
                    var listing = WorktreeListing(entries: [], isPartial: false)
                    listing.remotes = [.init(name: "origin", url: "https://github.com/me/api.git")]
                    listing.refs = RefParser.Listing(
                        branches: [branch("refs/remotes/origin/feat/x", kind: .remote(remote: "origin"))], tags: [],
                        isPartial: false, skippedRecords: 0)
                    return listing
                }(), isVerified: false))
        XCTAssertTrue(rows(cached.remote).allSatisfy { $0.gitHubTarget == nil })
    }
}
