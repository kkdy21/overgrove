import Foundation
import XCTest

@testable import Overgrove

/// Answers pull request loads with queued results and records the repositories asked for.
final class StubPullRequestLoader: PullRequestLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [PullRequestLoadResult]
    private var calls: [String] = []

    init(_ results: [PullRequestLoadResult]) {
        self.results = results
    }

    var requests: [String] { lock.withLock { calls } }

    func pullRequests(in repository: GitHubRepository) async -> PullRequestLoadResult {
        lock.withLock {
            calls.append(repository.slug)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// `AppState` pull request flows (ADR-0023, #115): loaded with the issues, linked by upstream, hidden on failure.
@MainActor
final class AppStatePullRequestTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let worktree = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let branchRef = "refs/heads/feat/42-rate-limit"

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var listing: WorktreeListing {
        var listing = WorktreeListing.mockup
        listing.setGitHubRemote(IssueModelsTests.repository)
        listing.refs = RefParser.Listing(
            branches: [PullRequestLinksTests.branch("feat/42-rate-limit"), PullRequestLinksTests.branch("main")],
            tags: [], isPartial: false, skippedRecords: 0)
        return listing
    }

    private func pullRequest(_ number: Int, owner: String = "team") -> PullRequest {
        PullRequestLinksTests.pullRequest(number, owner: owner, branch: "feat/42-rate-limit")
    }

    private func loadedState(
        _ pullRequests: StubPullRequestLoader, listing: WorktreeListing? = nil,
        issues: StubIssueLoader = StubIssueLoader([.issues([])])
    ) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing ?? self.listing)), issueLoader: issues,
            pullRequestLoader: pullRequests, ghChecker: QueuedGHAuthChecker([.loggedIn(login: "octocat")]))
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        await state.pullRequestStore.task?.value
        await state.ghCheckTask?.value
        return state
    }

    func testLoadsWithTheIssuesAndLinksByUpstream() async {
        let loader = StubPullRequestLoader([.pullRequests([pullRequest(7), pullRequest(8, owner: "attacker")])])
        let state = await loadedState(loader)
        XCTAssertEqual(loader.requests, ["team/app"])
        XCTAssertEqual(state.pullRequestStore.links.pullRequest(forBranch: branchRef)?.number, 7)
        XCTAssertNil(state.pullRequestStore.links.pullRequest(forBranch: "refs/heads/main"))

        state.selection = .worktreeInfo(worktree)
        XCTAssertEqual(state.worktreeDetailModel?.pullRequest?.badge.text, "#7")
        XCTAssertEqual(
            state.worktreeDetailModel?.pullRequest?.browserURL?.absoluteString, "https://github.com/team/app/pull/7")
        state.selection = .worktreeInfo(GitPath("/tmp/dev/api"))
        XCTAssertNil(state.worktreeDetailModel?.pullRequest, "main has no PR")
    }

    /// ADR-0023 §6–§7: a failure hides PR status and leaves the issue panel alone.
    func testFailureHidesPullRequestsOnly() async {
        let issue = IssueModelsTests.issue(12, "Worktree list", updated: 10)
        let state = await loadedState(
            StubPullRequestLoader([.unavailable]), issues: StubIssueLoader([.issues([issue])]))
        XCTAssertTrue(state.pullRequestStore.links.isEmpty)
        XCTAssertEqual(state.issueListModel.rows.map(\.id), [12])
        state.selection = .worktreeInfo(worktree)
        XCTAssertNotNil(state.worktreeDetailModel)
        XCTAssertNil(state.worktreeDetailModel?.pullRequest)
    }

    func testWithoutAGitHubRemoteGhIsNotRun() async {
        var noRemote = listing
        noRemote.setGitHubRemote(nil)
        let loader = StubPullRequestLoader([.pullRequests([pullRequest(7)])])
        let state = await loadedState(loader, listing: noRemote)
        XCTAssertEqual(loader.requests, [])
        XCTAssertTrue(state.pullRequestStore.links.isEmpty)
    }

    /// ⌘R and Check Again read the pull requests again, like the issues; a later failure clears the old ones.
    func testReloadAndCheckAgainReadAgain() async {
        let loader = StubPullRequestLoader([
            .pullRequests([pullRequest(7)]), .unavailable, .pullRequests([pullRequest(9)]),
        ])
        let state = await loadedState(loader)
        XCTAssertEqual(state.pullRequestStore.links.pullRequest(forBranch: branchRef)?.number, 7)
        state.reload()
        await state.loadTask?.value
        await state.pullRequestStore.task?.value
        XCTAssertTrue(state.pullRequestStore.links.isEmpty)
        await state.ghCheckTask?.value
        await state.issuePanel.task?.value
        state.checkIssuesAgain()
        await state.pullRequestStore.task?.value
        XCTAssertEqual(state.pullRequestStore.links.pullRequest(forBranch: branchRef)?.number, 9)
        XCTAssertEqual(loader.requests.count, 3)
    }

    func testAnotherRepositoryClearsPullRequests() async {
        let state = await loadedState(StubPullRequestLoader([.pullRequests([pullRequest(7)])]))
        XCTAssertFalse(state.pullRequestStore.links.isEmpty)
        state.clearRepositoryData()
        XCTAssertTrue(state.pullRequestStore.links.isEmpty)
        XCTAssertNil(state.pullRequestStore.repository)
    }
}
